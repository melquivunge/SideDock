// Recent photos/videos for the "flick toward the Mac" grid, plus the connected glow.
import SwiftUI
import Photos
import QuickLookThumbnailing

final class RecentPhotos: ObservableObject {
    @Published var assets: [PHAsset] = []
    @Published var denied = false

    func load() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            DispatchQueue.main.async {
                guard status == .authorized || status == .limited else { self.denied = true; return }
                self.denied = false
                let o = PHFetchOptions()
                o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                o.fetchLimit = 90 // ponytail: newest 90; older ones via the Photos button
                let r = PHAsset.fetchAssets(with: o)
                self.assets = (0..<r.count).map { r.object(at: $0) }
            }
        }
    }

    /// The original file (e.g. IMG_1234.HEIC / .MOV), edited version if there is one, written to temp for sending.
    func export(_ asset: PHAsset) async -> URL? {
        let resources = PHAssetResource.assetResources(for: asset)
        let preferred: [PHAssetResourceType] = [.fullSizePhoto, .fullSizeVideo, .photo, .video]
        guard let res = preferred.lazy.compactMap({ t in resources.first { $0.type == t } }).first ?? resources.first else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent(res.originalFilename)
        let o = PHAssetResourceRequestOptions()
        o.isNetworkAccessAllowed = true // iCloud photos get downloaded first
        do {
            try await PHAssetResourceManager.default().writeData(for: res, toFile: dst, options: o)
            return dst
        } catch {
            return nil
        }
    }
}

struct AssetThumb: View {
    let asset: PHAsset
    @Binding var image: UIImage?

    var body: some View {
        Color.secondary.opacity(0.15)
            .aspectRatio(1, contentMode: .fit)
            .overlay { if let image { Image(uiImage: image).resizable().scaledToFill() } }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if asset.mediaType == .video {
                    Image(systemName: "video.fill").font(.caption2).foregroundStyle(.white).padding(6)
                }
            }
            .task(id: asset.localIdentifier) {
                let o = PHImageRequestOptions()
                o.deliveryMode = .highQualityFormat // exactly one callback
                o.resizeMode = .fast
                o.isNetworkAccessAllowed = true
                image = await withCheckedContinuation { c in
                    PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 300, height: 300),
                                                          contentMode: .aspectFill, options: o) { img, _ in c.resume(returning: img) }
                }
            }
    }
}

// MARK: - Hand-off view (modelled on the reference video): the photo opens full screen; drag it toward the
// Mac and both screens light up near the shared edge, live; past the edge it flies over and lands on the Mac.

struct SendBatch: Identifiable {
    let id = UUID()
    var assets: [PHAsset] = []
    var files: [URL] = []       // files already on the phone (e.g. one that just came from the Mac)
    var count: Int { assets.count + files.count }
}

/// A picture of a file on disk: the image itself, else a Quick Look thumbnail.
func fileImage(_ url: URL, size: CGFloat) async -> UIImage? {
    if let img = UIImage(contentsOfFile: url.path) { return img }
    let r = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size), scale: 1, representationTypes: .all)
    return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: r).uiImage
}

struct SendView: View {
    @ObservedObject var client: DropClient
    let batch: SendBatch
    let onSend: (String) -> Void   // side the card left through
    let onClose: () -> Void
    @AppStorage("macSide") var macSide = "left"
    @State var images: [UIImage] = []
    @State var offset: CGSize = .zero
    @State var sentSide: String?
    @State var lastLive = Date.distantPast

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            // the side being approached: where the card is heading, else where the Mac was last time
            let side = offset.width < -8 ? "left" : offset.width > 8 ? "right" : macSide
            let progress = min(1, max(0, abs(offset.width) / (w * 0.42)))
            let y = min(1, max(0, 0.5 + offset.height / h))
            ZStack {
                Color.black
                // warm light pooled at the edge facing the Mac, growing as the card gets closer
                RadialGradient(stops: [
                    .init(color: Color(red: 1, green: 0.95, blue: 0.88).opacity(0.22 + 0.6 * progress), location: 0),
                    .init(color: Color(red: 1, green: 0.78, blue: 0.62).opacity(0.16 + 0.34 * progress), location: 0.35),
                    .init(color: Color(red: 0.62, green: 0.52, blue: 1).opacity(0.08 + 0.14 * progress), location: 0.68),
                    .init(color: .clear, location: 1),
                ], center: UnitPoint(x: side == "left" ? 0 : 1, y: y), startRadius: 0, endRadius: h * (0.45 + 0.35 * progress))
                cards
                    .frame(width: w * 0.64, height: h * 0.5)
                    .rotationEffect(.degrees(Double(offset.width) / 45))
                    .offset(sentSide == nil ? offset : CGSize(width: sentSide == "left" ? -w : w, height: offset.height))
                    .gesture(
                        DragGesture()
                            .onChanged { v in
                                offset = v.translation
                                live(progress: min(1, abs(v.translation.width) / (w * 0.42)),
                                     y: min(1, max(0, 0.5 + v.translation.height / h)), size: geo.size)
                            }
                            .onEnded { v in
                                let p = abs(v.translation.width) / (w * 0.42)
                                let fling = abs(v.predictedEndTranslation.width) > w * 0.7
                                guard client.macName != nil, p > 0.7 || fling else {
                                    if client.macName == nil, p > 0.7 || fling {
                                        UINotificationFeedbackGenerator().notificationOccurred(.warning)
                                    }
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { offset = .zero }
                                    client.sendLive(progress: 0, y: 0.5)
                                    return
                                }
                                let s = v.translation.width < 0 ? "left" : "right"
                                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                                live(progress: 1, y: y, size: geo.size, force: true) // final position: the Mac continues from here
                                client.sendDrop(y: y, side: s)
                                withAnimation(.easeIn(duration: 0.3)) { sentSide = s }
                                onSend(s)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { onClose() }
                            }
                    )
                VStack {
                    HStack {
                        Button {
                            client.sendLive(progress: 0, y: 0.5)
                            onClose()
                        } label: {
                            Image(systemName: "xmark").font(.headline).foregroundStyle(.white)
                                .frame(width: 40, height: 40).background(.white.opacity(0.15), in: Circle())
                        }
                        Spacer()
                    }
                    Spacer()
                    Text(client.macName == nil ? "Connect to your Mac first" :
                            "Drag toward \(client.macName ?? "your Mac")")
                        .font(.footnote).foregroundStyle(.white.opacity(0.6))
                }
                .padding(.horizontal, 20).padding(.vertical, 8)
            }
            .animation(.easeOut(duration: 0.2), value: side)
        }
        .ignoresSafeArea(edges: .horizontal)
        .task { await load() }
    }

    var cards: some View {
        ZStack {
            ForEach(Array(images.prefix(3).enumerated().reversed()), id: \.offset) { k, img in
                Image(uiImage: img).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
                    .rotationEffect(.degrees(Double(k) * -5))
                    .offset(x: CGFloat(k) * -8, y: CGFloat(k) * 6)
            }
            if batch.count > 1 {
                Text("\(batch.count)").font(.headline).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.blue, in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
    }

    /// Stream the drag to the Mac (~30/s): its corner lights up in step, and the part of the photo that has
    /// crossed this phone's edge is drawn on the Mac at the same height — one photo split across both screens.
    func live(progress: Double, y: Double, size: CGSize, force: Bool = false) {
        guard force || Date().timeIntervalSince(lastLive) > 1.0 / 30 else { return }
        lastLive = Date()
        let card = imageRect(in: size)
        client.sendLive(progress: progress, y: y, card: card, screen: size, angle: Double(offset.width) / 45)
    }

    /// Where the top photo actually is on screen (the card frame is 64% × 50%, the photo fits inside it).
    func imageRect(in size: CGSize) -> CGRect {
        let box = CGSize(width: size.width * 0.64, height: size.height * 0.5)
        let a = images.first.map { $0.size.width / max($0.size.height, 1) } ?? 1
        let fit = box.width / box.height > a ? CGSize(width: box.height * a, height: box.height)
                                             : CGSize(width: box.width, height: box.width / a)
        let c = CGPoint(x: size.width / 2 + offset.width, y: size.height / 2 + offset.height)
        return CGRect(x: c.x - fit.width / 2, y: c.y - fit.height / 2, width: fit.width, height: fit.height)
    }

    func load() async {
        if !batch.files.isEmpty { // files already on the phone: just read them
            var out: [UIImage] = []
            for u in batch.files.prefix(3) { if let img = await fileImage(u, size: 1000) { out.append(img) } }
            images = out
            if let first = out.first { client.sendPreview(first, count: batch.count) }
            return
        }
        // 1) a quick small version straight away, so the Mac has the picture long before you let go
        if let a = batch.assets.first {
            let o = PHImageRequestOptions()
            o.deliveryMode = .fastFormat
            o.isNetworkAccessAllowed = true
            let quick: UIImage? = await withCheckedContinuation { c in
                PHImageManager.default().requestImage(for: a, targetSize: CGSize(width: 500, height: 500),
                                                      contentMode: .aspectFit, options: o) { img, _ in c.resume(returning: img) }
            }
            if let quick {
                if images.isEmpty { images = [quick] }
                client.sendPreview(quick, count: batch.count)
            }
        }
        // 2) sharp versions for the cards on screen
        var out: [UIImage] = []
        for a in batch.assets.prefix(3) {
            let o = PHImageRequestOptions()
            o.deliveryMode = .highQualityFormat
            o.isNetworkAccessAllowed = true
            if let img: UIImage = await withCheckedContinuation({ c in
                PHImageManager.default().requestImage(for: a, targetSize: CGSize(width: 1000, height: 1000),
                                                      contentMode: .aspectFit, options: o) { img, _ in c.resume(returning: img) }
            }) { out.append(img) }
        }
        if !out.isEmpty { images = out }
    }
}

/// Mac → phone: the part of the dragged file that has crossed the Mac's edge appears here at the same height;
/// after the drop it grows to the middle, then drops into the "From your Mac" list.
struct IncomingOverlay: View {
    @ObservedObject var state: IncomingState
    let onGrab: (URL) -> Void // you touched the arriving photo: open it to send it on

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                if let card = state.live {
                    RadialGradient(stops: [
                        .init(color: Color(red: 1, green: 0.95, blue: 0.88).opacity(0.6 * card.progress), location: 0),
                        .init(color: Color(red: 1, green: 0.78, blue: 0.62).opacity(0.35 * card.progress), location: 0.35),
                        .init(color: Color(red: 0.62, green: 0.52, blue: 1).opacity(0.15 * card.progress), location: 0.68),
                        .init(color: .clear, location: 1),
                    ], center: UnitPoint(x: card.touchLeft ? 0 : 1, y: 0.5 + card.cy / h),
                       startRadius: 0, endRadius: h * (0.3 + 0.4 * card.progress))
                    .allowsHitTesting(false)
                    if let img = state.preview {
                        let f = card.frame(in: geo.size)
                        Image(uiImage: img).resizable().scaledToFill()
                            .frame(width: f.size.width, height: f.size.height)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
                            .position(f.center)
                            .allowsHitTesting(false)
                    }
                }
                if let hero = state.hero {
                    let a = hero.image.size.width / max(hero.image.size.height, 1)
                    let big = a > 0.8 * w / (0.5 * h) ? CGSize(width: w * 0.8, height: w * 0.8 / a)
                                                       : CGSize(width: h * 0.5 * a, height: h * 0.5)
                    let start = hero.start?.frame(in: geo.size) ?? (center: CGPoint(x: -80, y: h / 2), size: CGSize(width: 160 * a, height: 160))
                    let size = hero.phase == 0 ? start.size : hero.phase == 1 ? big : CGSize(width: 50 * a, height: 50)
                    Image(uiImage: hero.image).resizable().scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .clipShape(RoundedRectangle(cornerRadius: hero.phase == 1 ? 18 : 10, style: .continuous))
                        .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
                        .opacity(hero.phase == 2 ? 0.2 : 1)
                        .overlay(alignment: .bottom) {
                            if hero.phase == 1 {
                                Text("Tap to send it back").font(.caption).foregroundStyle(.white)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(.black.opacity(0.45), in: Capsule()).padding(10)
                            }
                        }
                        .contentShape(Rectangle())
                        .allowsHitTesting(hero.phase == 1)
                        .onTapGesture { state.grab(onGrab) }
                        .gesture(DragGesture(minimumDistance: 8).onChanged { _ in state.grab(onGrab) })
                        .position(hero.phase == 0 ? start.center : hero.phase == 1 ? CGPoint(x: w / 2, y: h / 2)
                                  : CGPoint(x: w / 2, y: h * 0.88))
                }
            }
            .animation(.linear(duration: 0.08), value: state.live?.cx)
        }
        .ignoresSafeArea()
    }
}

/// Soft light along one edge (while dragging). Same look on the Mac (Drop.swift).
struct EdgeStrip: View {
    let right: Bool
    let strength: Double // 0…1
    var body: some View {
        LinearGradient(colors: [.white.opacity(0.85 * strength), .cyan.opacity(0.45 * strength),
                                .purple.opacity(0.2 * strength), .clear],
                       startPoint: right ? .trailing : .leading, endPoint: right ? .leading : .trailing)
            .frame(width: 24 + 90 * strength)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: right ? .trailing : .leading)
            .allowsHitTesting(false)
    }
}

/// Circular light waves from a screen edge. Same code on the Mac (Drop.swift) — keep in sync.
struct WaveLayer: View {
    let starts: [(Date, Bool, Double)] // (start, fromRight, strength)
    static let duration = 1.3

    var body: some View {
        TimelineView(.animation(paused: starts.isEmpty)) { tl in
            GeometryReader { geo in
                ZStack {
                    ForEach(starts.indices, id: \.self) { i in
                        let (start, right, strength) = starts[i]
                        wave(t: tl.date.timeIntervalSince(start), right: right, strength: strength, size: geo.size)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    func wave(t: Double, right: Bool, strength: Double, size: CGSize) -> some View {
        // two phases, as in the reference: 0–30% a bright white flash blooms at the edge,
        // 30–100% it travels across the screen as a ring with a soft rainbow front while the white fades
        let p = min(1, max(0, t / Self.duration))
        func out(_ x: Double) -> Double { 1 - pow(1 - x, 2.4) }
        let maxR = hypot(size.width, size.height) * strength
        let r = max(1, maxR * (p < 0.3 ? 0.35 * out(p / 0.3) : 0.35 + 0.65 * out((p - 0.3) / 0.7)))
        let band = min(r, maxR * 0.22)                        // rainbow band thickness
        let core = p < 0.3 ? 0.9 : max(0, 0.9 * (1 - (p - 0.3) / 0.45))
        let rainbow = min(1, p / 0.25) * (p < 1 ? 1 - p : 0)
        func at(_ d: Double) -> Double { max(0, min(1, (r - d) / r)) }
        let stops: [Gradient.Stop] = [
            .init(color: .white.opacity(core), location: 0),
            .init(color: .white.opacity(core * 0.85), location: at(band * 1.3)),
            .init(color: Color(red: 1, green: 0.7, blue: 0.9).opacity(0.55 * rainbow), location: at(band * 0.8)),
            .init(color: Color(red: 1, green: 0.95, blue: 0.6).opacity(0.6 * rainbow), location: at(band * 0.55)),
            .init(color: Color(red: 0.6, green: 1, blue: 0.7).opacity(0.5 * rainbow), location: at(band * 0.33)),
            .init(color: Color(red: 0.55, green: 0.85, blue: 1).opacity(0.35 * rainbow), location: at(band * 0.14)),
            .init(color: .clear, location: 1),
        ]
        return Rectangle().fill(RadialGradient(stops: stops, center: UnitPoint(x: right ? 1 : 0, y: 0.5),
                                               startRadius: 0, endRadius: r))
    }
}
