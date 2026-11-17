import SwiftUI
import PhotosUI
import Photos
import QuickLook
import QuickLookThumbnailing
import UniformTypeIdentifiers

@main
struct SideDropApp: App {
    var body: some Scene { WindowGroup { ContentView() } } // every orientation, iPhone and iPad (Info.plist)
}

struct ContentView: View {
    @StateObject var client = DropClient()
    @StateObject var library = RecentPhotos()
    @AppStorage("macSide") var macSide = "left"
    @Environment(\.scenePhase) var scenePhase
    @State var photos: [PhotosPickerItem] = []
    @State var importing = false
    @State var preview: URL?
    @State var showSettings = false
    @State var showDeck = false
    @State var dropTargeted = false
    @State var sending: SendBatch?
    @State var selecting = false
    @State var waves: [(Date, Bool, Double)] = []
    @State var selected: Set<String> = [] // multi-select in the Recent grid

    var connected: Bool { client.macName != nil }
    let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    recent
                    fromMac
                }
                .padding(.horizontal)
            }
            .navigationTitle("SideDrop")
            .toolbar {
                Button { showDeck = true } label: { SwiftUI.Label("Deck", systemImage: "dial.medium").labelStyle(.titleAndIcon) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
            }
            .fullScreenCover(isPresented: $showDeck) { DeckView(client: client) }
            .sheet(isPresented: $showSettings) { SettingsSheet(client: client) }
            .quickLookPreview($preview)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                client.send(urls.compactMap(copyToTemp))
            }
            .onChange(of: photos) { _, items in
                guard !items.isEmpty else { return }
                photos = []
                Task {
                    var urls: [URL] = []
                    for item in items {
                        if let f = try? await item.loadTransferable(type: PickedFile.self) { urls.append(f.url) }
                    }
                    client.send(urls)
                }
            }
            // drag files in from another app (e.g. Files or Photos) and drop them anywhere here
            .onDrop(of: [.item], isTargeted: $dropTargeted) { providers in
                guard connected else { return false }
                for p in providers {
                    _ = p.loadFileRepresentation(for: .item, openInPlace: false) { url, _, _ in
                        guard let url, let tmp = copyToTemp(url) else { return }
                        DispatchQueue.main.async { client.send([tmp]) }
                    }
                }
                return true
            }
        }
        .overlay {
            ZStack {
                EdgeStrip(right: macSide == "right", strength: dropTargeted ? 0.9 : 0)
                WaveLayer(starts: waves)
            }
            .ignoresSafeArea()
            .animation(.easeOut(duration: 0.25), value: dropTargeted)
        }
        .overlay { IncomingOverlay(state: client.incoming) { url in sending = SendBatch(files: [url]) } }
        .fullScreenCover(item: $sending) { batch in
            SendView(client: client, batch: batch, onSend: { side in
                burst()
                Task {
                    var urls: [URL] = batch.files
                    for a in batch.assets { if let u = await library.export(a) { urls.append(u) } }
                    client.send(urls, side: side)
                }
            }, onClose: { sending = nil })
            .presentationBackground(.black)
        }
        .onAppear { client.start(); library.load() }
        .onChange(of: connected) { _, now in if now { burst() } }
        .onChange(of: client.received.count) { old, new in if new > old { burst() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { library.load() }
        }
    }

    @ViewBuilder var header: some View {
        if connected {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "laptopcomputer").font(.title2).foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(client.status).font(.headline)
                        Text("Tap a photo, then drag it toward your Mac").font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Disconnect", role: .destructive) { client.disconnect() }.font(.footnote)
                }
                HStack(spacing: 10) {
                    PhotosPicker(selection: $photos, maxSelectionCount: nil, selectionBehavior: .ordered, matching: .any(of: [.images, .videos])) {
                        SwiftUI.Label("All Photos", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button { importing = true } label: {
                        SwiftUI.Label("Files", systemImage: "folder").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                ForEach(client.transfers) { t in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(t.incoming ? "↓" : "↑") \(t.name)").font(.footnote).lineLimit(1)
                        ProgressView(value: t.fraction)
                    }
                }
            }
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        } else {
            VStack(spacing: 14) {
                Radar(closeness: client.closeness, connected: false).frame(height: 180)
                Text(client.status).font(.headline).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical)
        }
    }

    /// One light wave from the Mac's side (same effect as on the Mac); removed when done so the clock stops.
    func burst(strength: Double = 1.0) {
        let w = (Date(), macSide == "right", strength)
        waves.append(w)
        DispatchQueue.main.asyncAfter(deadline: .now() + WaveLayer.duration + 0.1) { waves.removeAll { $0.0 == w.0 } }
    }

    var recent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent").font(.headline)
                Spacer()
                if selecting && !selected.isEmpty {
                    Button("Send \(selected.count)") {
                        sending = SendBatch(assets: library.assets.filter { selected.contains($0.localIdentifier) })
                        selected = []
                        selecting = false
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                }
                Button(selecting ? "Cancel" : "Select") { selecting.toggle(); selected = [] }.font(.subheadline)
            }
            Text(selecting ? "Tap the photos you want, then Send" : "Tap a photo, then drag it toward your Mac")
                .font(.footnote).foregroundStyle(.secondary)
            if library.denied {
                Text("Allow photo access in Settings to send photos to your Mac.").font(.footnote).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(library.assets, id: \.localIdentifier) { asset in
                    let id = asset.localIdentifier
                    GridThumb(asset: asset, selected: selected.contains(id))
                        .onTapGesture {
                            if selecting {
                                if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
                            } else {
                                sending = SendBatch(assets: [asset])
                            }
                        }
                }
            }
        }
    }

    var fromMac: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("From your Mac").font(.headline)
            if client.received.isEmpty {
                Text("Drag files to the glowing edge of your Mac’s screen and they appear here.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(client.received, id: \.self) { url in
                HStack(spacing: 12) {
                    Thumb(url: url)
                    Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                }
                .contentShape(Rectangle())
                .onTapGesture { preview = url }
                .contextMenu {
                    Button("Send back to Mac", systemImage: "laptopcomputer") { sending = SendBatch(files: [url]) }
                    Button("Delete", role: .destructive) {
                        if let i = client.received.firstIndex(of: url) { client.delete(at: [i]) }
                    }
                }
            }
        }
        .padding(.bottom, 30)
    }
}

struct GridThumb: View {
    let asset: PHAsset
    let selected: Bool
    @State var image: UIImage?
    var body: some View {
        AssetThumb(asset: asset, image: $image)
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3).symbolRenderingMode(.palette).foregroundStyle(.white, .blue).padding(5)
                }
            }
            .overlay {
                if selected { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.blue, lineWidth: 3) }
            }
            .contentShape(Rectangle())
    }
}

/// Files from the Files app are security-scoped; copy them to temp so they can be sent in the background.
func copyToTemp(_ url: URL) -> URL? {
    let ok = url.startAccessingSecurityScopedResource()
    defer { if ok { url.stopAccessingSecurityScopedResource() } }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let dst = dir.appendingPathComponent(url.lastPathComponent)
    return (try? FileManager.default.copyItem(at: url, to: dst)) != nil ? dst : nil
}

/// A photo/video from PhotosPicker, as a file with its original name (e.g. IMG_1234.HEIC).
struct PickedFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .data) { received in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dst = dir.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: dst)
            return PickedFile(url: dst)
        }
    }
}

struct Radar: View {
    let closeness: Double // 0…1
    let connected: Bool
    @State var pulse = false
    var color: Color { connected ? .green : .accentColor }

    var body: some View {
        ZStack {
            ForEach(0..<3) { i in
                Circle().stroke(color.opacity(0.4), lineWidth: 2)
                    .scaleEffect(pulse ? 1 : 0.35)
                    .opacity(pulse ? 0 : 1)
                    .animation(.easeOut(duration: 2.4).repeatForever(autoreverses: false).delay(Double(i) * 0.8), value: pulse)
            }
            Circle().fill(color.opacity(0.15))
                .frame(width: 90 + 70 * closeness, height: 90 + 70 * closeness)
                .animation(.spring, value: closeness)
            Image(systemName: connected ? "checkmark" : "laptopcomputer")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(color)
                .contentTransition(.symbolEffect(.replace))
        }
        .onAppear { pulse = true }
    }
}

struct Thumb: View {
    let url: URL
    @State var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() } else { Image(systemName: "doc").foregroundStyle(.secondary) }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task {
            let r = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 40, height: 40), scale: 3, representationTypes: .thumbnail)
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: r).uiImage
        }
    }
}

struct SettingsSheet: View {
    @ObservedObject var client: DropClient
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Current signal", value: client.signal.map { "\(Int($0)) dBm" } ?? "No Mac found")
                    VStack(alignment: .leading) {
                        Text("Connect when stronger than \(Int(client.threshold)) dBm")
                        Slider(value: $client.threshold, in: -85 ... -25, step: 1)
                    }
                } header: {
                    Text("Closeness")
                } footer: {
                    Text("Hold the iPhone where you want it to connect, then set the slider a little below the current signal. Higher = must be closer.")
                }
                Section {
                    Button("Forget paired Macs", role: .destructive) { client.forgetMacs() }
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
