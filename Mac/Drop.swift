// SideDrop (Mac side): hold an iPhone running SideDrop next to the Mac → they connect → files go both ways
// through a floating shelf. Transport: MultipeerConnectivity (peer-to-peer Wi-Fi/Bluetooth, encrypted).
// Closeness: the Mac advertises a Bluetooth LE beacon; the iPhone measures its signal strength.
import AppKit
import SwiftUI
import MultipeerConnectivity
import CoreBluetooth
import QuickLookThumbnailing
import os

/// Diagnostics: `log show --last 10m --info --predicate 'subsystem == "local.sidedock"'`
let dropLog = Logger(subsystem: "local.sidedock", category: "drop")

// Shared with the iPhone app (iOS/SideDrop/DropClient.swift) — keep in sync.
let dropServiceType = "sidedrop"
let dropBLEService = CBUUID(string: "5E1D0C4A-8F3B-4C1E-9A57-2D6B1F0E7A11")
/// Handshake: iPhone → hello(secret?) ; Mac → pair(secret) on first approval ; Mac → ready once trusted.
struct DropMessage: Codable {
    var type: String                 // hello | pair | ready | side | live | preview | drop
    var secret: String? = nil
    var side: String? = nil
    var progress: Double? = nil      // live: 0…1 how close the phone's card is to its edge
    var y: Double? = nil             // live/drop: card height on the phone, 0 top … 1 bottom
    var preview: Data? = nil         // preview: small JPEG of the photo being handed over
    var count: Int? = nil
    // live card geometry in phone points (see LiveCard)
    var cx: Double? = nil, cy: Double? = nil, cw: Double? = nil, ch: Double? = nil
    var pw: Double? = nil, ph: Double? = nil, angle: Double? = nil
    // Deck (phone ↔ Mac remote): control/value, state (values + now playing), apps, launch (path), media (cmd)
    var control: String? = nil, value: Double? = nil
    var values: [String: Double]? = nil
    var apps: [DeckApp]? = nil
    var path: String? = nil, cmd: String? = nil
    var title: String? = nil, artist: String? = nil, playing: Bool? = nil
    // Creative Pro: keys ("cmd+z", "4 5"), hex colour; state carries the creative app in front + agent status
    var keys: String? = nil, hex: String? = nil
    var front: String? = nil, frontName: String? = nil
    var agents: [AgentStatus]? = nil
    // Windows: Mac → phone list of apps with windows (DeckApp.path = pid) + screen names; phone → Mac split
    var screens: [String]? = nil, pids: [Int]? = nil, screen: Int? = nil
    // now playing extras: cover (Spotify: URL, Music: JPEG), position/duration in seconds (for synced lyrics)
    var artURL: String? = nil, artData: Data? = nil, position: Double? = nil, duration: Double? = nil
}

/// Claude Code / Codex: state = working | waiting | idle | none; text = last thing it said; age = seconds since activity
struct AgentStatus: Codable, Hashable {
    var name: String, project: String, state: String, text: String, age: Double
}

struct DeckApp: Codable, Hashable {
    var name: String, path: String, icon: Data
}

/// Where the photo is on the phone right now (phone points). The Mac draws the part past the phone's edge.
struct LiveCard {
    var cx, cy, cw, ch, pw, ph, angle: Double
    init?(_ m: DropMessage) {
        guard let cx = m.cx, let cy = m.cy, let cw = m.cw, let ch = m.ch, let pw = m.pw, let ph = m.ph else { return nil }
        (self.cx, self.cy, self.cw, self.ch, self.pw, self.ph, self.angle) = (cx, cy, cw, ch, pw, ph, m.angle ?? 0)
    }

    /// Phone points → Mac points, as if the phone stood against that edge of the screen.
    /// phoneScale/phoneY are calibration knobs: screen densities and where the phone stands vary.
    func frame(in screen: CGSize, phoneOnRight: Bool) -> (center: CGPoint, size: CGSize) {
        let k = prefs.double(forKey: "phoneScale"), anchorY = screen.height * prefs.double(forKey: "phoneY")
        // phone on the Mac's right: its left edge touches the Mac's right edge (and mirrored)
        let x = phoneOnRight ? screen.width + cx * k : (cx - pw) * k
        let y = anchorY + (cy - ph / 2) * k
        return (CGPoint(x: x, y: y), CGSize(width: cw * k, height: ch * k))
    }
}

/// Received files go to the Desktop (like the reference video) or ~/Downloads/SideDrop.
var inboxURL: URL {
    URL(fileURLWithPath: NSHomeDirectory() + (prefs.string(forKey: "dropFolder") == "downloads" ? "/Downloads/SideDrop" : "/Desktop"))
}

struct Transfer: Identifiable {
    let id = UUID()
    let name: String
    let incoming: Bool
    var fraction = 0.0
}

final class DropCenter: NSObject, ObservableObject {
    @Published var files: [URL] = []         // received this session, newest first
    @Published var peers: [MCPeerID] = []    // connected AND trusted iPhones
    @Published var transfers: [Transfer] = []
    var onActivity: () -> Void = {}
    var onWave: () -> Void = {}              // light wave: connected / file leaving / file arriving
    var onReceived: (URL) -> Void = { _ in } // file landed (thumbnail flies in)
    var onLive: (DropMessage) -> Void = { _ in }       // phone card moving: progress, y, card geometry
    var onPreview: (NSImage) -> Void = { _ in }        // picture of what's about to be handed over
    var onDrop: (Double) -> Void = { _ in }            // the card left the phone at height y
    var onDeck: (DropMessage, MCPeerID) -> Void = { _, _ in } // iPhone Deck remote commands

    /// Short id in the BLE beacon so the iPhone can match beacon ↔ Multipeer peer (BLE packets are tiny).
    let macID: String = {
        if let id = prefs.string(forKey: "dropID") { return id }
        let id = String(UUID().uuidString.prefix(6))
        prefs.set(id, forKey: "dropID")
        return id
    }()
    // "Mac name · User": with several macOS users, the iPhone shows whose session it's controlling
    lazy var me = MCPeerID(displayName: String("\(Host.current().localizedName ?? "Mac") · \(NSFullUserName())".prefix(60)))
    lazy var session: MCSession = {
        let s = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .required)
        s.delegate = self
        return s
    }()
    lazy var advertiser: MCNearbyServiceAdvertiser = {
        let a = MCNearbyServiceAdvertiser(peer: me, discoveryInfo: ["id": macID], serviceType: dropServiceType)
        a.delegate = self
        return a
    }()
    var ble: CBPeripheralManager?
    var running = false
    var observers: [UUID: NSKeyValueObservation] = [:]

    func setEnabled(_ on: Bool) {
        guard on != running else { return }
        running = on
        if on {
            advertiser.startAdvertisingPeer()
            ble = CBPeripheralManager(delegate: self, queue: .main)
        } else {
            advertiser.stopAdvertisingPeer()
            ble?.stopAdvertising()
            ble = nil
            session.disconnect()
            peers = []
        }
    }

    /// Mac → iPhone
    func send(_ urls: [URL]) {
        dropLog.notice("sending \(urls.count) file(s) to \(self.peers.count) iPhone(s)")
        for peer in peers {
            for url in urls where !isDir(url.path) { // ponytail: folders skipped; zip them first if needed
                let t = Transfer(name: url.lastPathComponent, incoming: false)
                transfers.append(t)
                let p = session.sendResource(at: url, withName: url.lastPathComponent, toPeer: peer) { [weak self] _ in
                    DispatchQueue.main.async { self?.finish(t.id) }
                }
                observe(p, t.id)
            }
        }
        if !peers.isEmpty && !urls.isEmpty { onWave() }
    }

    func observe(_ progress: Progress?, _ id: UUID) {
        guard let progress else { return finish(id) }
        observers[id] = progress.observe(\.fractionCompleted) { [weak self] p, _ in
            DispatchQueue.main.async {
                guard let self, let i = self.transfers.firstIndex(where: { $0.id == id }) else { return }
                self.transfers[i].fraction = p.fractionCompleted
            }
        }
    }

    func finish(_ id: UUID) {
        transfers.removeAll { $0.id == id }
        observers[id] = nil
    }

    /// Mac → phone hand-off: the last live position sent, so the drop continues from exactly there.
    var lastLiveOut: DropMessage?

    func broadcast(_ m: DropMessage, reliable: Bool = true) {
        guard !peers.isEmpty, let d = try? JSONEncoder().encode(m) else { return }
        try? session.send(d, toPeers: peers, with: reliable ? .reliable : .unreliable)
    }

    func sendMessage(_ m: DropMessage, to peer: MCPeerID) {
        guard let d = try? JSONEncoder().encode(m) else { return }
        try? session.send(d, toPeers: [peer], with: .reliable)
    }

    func trust(_ peer: MCPeerID) {
        if !peers.contains(peer) { peers.append(peer); onWave() }
        sendMessage(DropMessage(type: "ready"), to: peer)
        onActivity()
    }

    /// Known iPhones present the secret they got when first approved; new ones need a click on the Mac.
    func handleHello(_ m: DropMessage, from peer: MCPeerID) {
        let secrets = prefs.stringArray(forKey: "dropSecrets") ?? []
        if let s = m.secret, secrets.contains(s) { return trust(peer) }
        let a = NSAlert()
        a.messageText = "Allow “\(peer.displayName)” to share files with this Mac?"
        a.informativeText = "Only allow iPhones you own. You can forget paired iPhones in SideDock settings → iPhone."
        a.addButton(withTitle: "Allow")
        a.addButton(withTitle: "Don’t Allow")
        NSApp.activate()
        guard a.runModal() == .alertFirstButtonReturn else { return session.cancelConnectPeer(peer) }
        let secret = UUID().uuidString + UUID().uuidString
        prefs.set(secrets + [secret], forKey: "dropSecrets")
        sendMessage(DropMessage(type: "pair", secret: secret), to: peer)
        trust(peer)
    }

    /// Move a received file into ~/Downloads/SideDrop without overwriting anything.
    func save(_ tmp: URL, name: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        var clean = (name as NSString).lastPathComponent // the name comes from the phone: no paths allowed
        if clean.isEmpty || clean == "." || clean == ".." { clean = "file" }
        let base = (clean as NSString).deletingPathExtension, ext = (clean as NSString).pathExtension
        var dst = inboxURL.appendingPathComponent(clean), n = 2
        while fm.fileExists(atPath: dst.path) {
            dst = inboxURL.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        guard (try? fm.moveItem(at: tmp, to: dst)) != nil else { return }
        files.insert(dst, at: 0)
        onReceived(dst)
        onActivity()
    }
}

extension DropCenter: MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, CBPeripheralManagerDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        guard state == .notConnected else { return }
        DispatchQueue.main.async { self.peers.removeAll { $0 == peerID } }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let m = try? JSONDecoder().decode(DropMessage.self, from: data) else {
            dropLog.notice("undecodable message, \(data.count) bytes")
            return
        }
        if m.type != "live" { dropLog.notice("message \(m.type, privacy: .public), \(data.count) bytes") }
        DispatchQueue.main.async {
            switch m.type {
            case "hello": self.handleHello(m, from: peerID)
            case "side" where self.peers.contains(peerID):
                // phone flicked toward its left → the Mac is on the phone's left → the phone sits on the Mac's right
                prefs.set(m.side == "left" ? "right" : "left", forKey: "phoneSide")
            case "live" where self.peers.contains(peerID):
                self.onLive(m)
            case "preview" where self.peers.contains(peerID):
                if let d = m.preview, let img = NSImage(data: d) { self.onPreview(img) }
                else { dropLog.notice("preview could not be decoded") }
            case "drop" where self.peers.contains(peerID):
                if let s = m.side { prefs.set(s == "left" ? "right" : "left", forKey: "phoneSide") }
                self.onDrop(m.y ?? 0.5)
            case "control", "state", "apps", "launch", "media", "keys", "color", "agentOpen", "windows", "split", "window":
                if self.peers.contains(peerID) { self.onDeck(m, peerID) } // trusted iPhones only
            default: break
            }
        }
    }

    func session(_ session: MCSession, didStartReceivingResourceWithName name: String, fromPeer peerID: MCPeerID,
                 with progress: Progress) {
        DispatchQueue.main.async {
            guard self.peers.contains(peerID) else { return progress.cancel() } // untrusted: refuse
            let t = Transfer(name: name, incoming: true)
            self.transfers.append(t)
            self.observe(progress, t.id)
            self.onWave()
            self.onActivity()
        }
    }

    func session(_ session: MCSession, didFinishReceivingResourceWithName name: String, fromPeer peerID: MCPeerID,
                 at localURL: URL?, withError error: Error?) {
        // localURL is deleted as soon as this returns, so move it out synchronously first
        var tmp: URL?
        if error == nil, let localURL {
            let t = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            if (try? FileManager.default.moveItem(at: localURL, to: t)) != nil { tmp = t }
        }
        DispatchQueue.main.async {
            if let t = self.transfers.first(where: { $0.incoming && $0.name == name }) { self.finish(t.id) }
            guard let tmp else { return }
            guard self.peers.contains(peerID) else { try? FileManager.default.removeItem(at: tmp); return }
            self.save(tmp, name: name)
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session) // connecting is harmless: nothing is accepted until the hello/pair handshake
    }

    func peripheralManagerDidUpdateState(_ p: CBPeripheralManager) {
        guard p.state == .poweredOn else { return }
        p.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [dropBLEService], CBAdvertisementDataLocalNameKey: macID])
    }
}

// MARK: - Shelf (floating panel with received files + drop zone to send)

struct ShelfView: View {
    @ObservedObject var drop: DropCenter
    let close: () -> Void
    @State var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: drop.peers.isEmpty ? "iphone.slash" : "iphone.radiowaves.left.and.right")
                    .foregroundStyle(drop.peers.isEmpty ? Color.secondary : Color.green)
                Text(drop.peers.first?.displayName ?? "No iPhone connected").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                Button(action: close) { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(drop.transfers) { t in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(t.incoming ? "↓" : "↑") \(t.name)").font(.system(size: 11)).lineLimit(1)
                            ProgressView(value: t.fraction).controlSize(.small)
                        }
                    }
                    ForEach(drop.files, id: \.self) { url in
                        FileRow(url: url)
                            .onDrag { NSItemProvider(object: url as NSURL) } // drag out to Finder/any app
                            .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                            .contextMenu {
                                Button("Open") { NSWorkspace.shared.open(url) }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            }
                    }
                    if drop.files.isEmpty && drop.transfers.isEmpty {
                        Hint("Files from your iPhone appear here. Drag them anywhere.").padding(.top, 20)
                    }
                }
            }
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                .foregroundStyle(targeted ? Color.accentColor : .secondary.opacity(0.5))
                .background(RoundedRectangle(cornerRadius: 12).fill(targeted ? Color.accentColor.opacity(0.15) : .clear))
                .frame(height: 64)
                .overlay(Text(drop.peers.isEmpty ? "Connect an iPhone to send" : "Drop files to send to iPhone")
                    .font(.system(size: 11)).foregroundStyle(.secondary))
                .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                    guard !drop.peers.isEmpty else { return false }
                    for p in providers {
                        _ = p.loadObject(ofClass: URL.self) { url, _ in
                            if let url { DispatchQueue.main.async { drop.send([url]) } }
                        }
                    }
                    return true
                }
            HStack {
                Button("Open Folder") {
                    try? FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(inboxURL)
                }
                Spacer()
                Button("Clear") { drop.files = [] }.disabled(drop.files.isEmpty)
            }
            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 260, height: 480)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

struct FileRow: View {
    let url: URL
    @State var thumb: NSImage?
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: thumb ?? NSWorkspace.shared.icon(forFile: url.path))
                .resizable().scaledToFill().frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Text(ByteCountFormatter.string(fromByteCount: Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0),
                                               countStyle: .file))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .task {
            let r = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 44, height: 44), scale: 2, representationTypes: .thumbnail)
            thumb = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: r).nsImage
        }
    }
}

// MARK: - Regular AirDrop arrivals get the same effects

/// Watches ~/Downloads; files that AirDrop delivered (quarantine agent "sharingd") trigger the fly-in + wave.
final class AirDropWatcher {
    let dir = URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")
    var source: DispatchSourceFileSystemObject?
    var seen: Set<String> = []
    let onFile: (URL) -> Void

    init(onFile: @escaping (URL) -> Void) {
        self.onFile = onFile
        seen = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return } // no access to Downloads: AirDrop still works, just without the effect
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in self?.scan() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    func scan() {
        let now = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        let new = now.subtracting(seen)
        seen = now
        guard prefs.bool(forKey: "airdrop") else { return }
        for name in new where !name.hasPrefix(".") {
            let url = dir.appendingPathComponent(name)
            // give AirDrop a moment to finish writing and tagging the file
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if quarantineAgent(url) == "sharingd" { self.onFile(url) }
            }
        }
    }
}

/// Which app downloaded a file: the 3rd field of the com.apple.quarantine attribute ("0083;…;sharingd;…" for AirDrop).
func quarantineAgent(_ url: URL) -> String? {
    let n = getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0)
    guard n > 0 else { return nil }
    var buf = [UInt8](repeating: 0, count: n)
    guard getxattr(url.path, "com.apple.quarantine", &buf, n, 0, 0) == n else { return nil }
    let parts = String(decoding: buf, as: UTF8.self).split(separator: ";", omittingEmptySubsequences: false)
    return parts.count > 2 ? String(parts[2]) : nil
}

// MARK: - Light effects (modelled on the reference video, frame by frame):
// a white flash at the phone's edge spreads across the whole screen as a circular wave with a rainbow leading
// edge (~1 s); a received file's thumbnail glides in from that edge. Gradients only, no blur, so it stays cheap.

final class GlowState: ObservableObject {
    @Published var dragging = false          // a file drag is happening somewhere on screen
    @Published var hover = [false, false]    // drag is over the [left, right] drop zone
}

/// Soft light along one edge (while dragging). Same look on the iPhone (RecentPhotos.swift).
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

/// Circular light waves from a screen edge. Same code on the iPhone (RecentPhotos.swift) — keep in sync.
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

struct Flyer: Identifiable {
    let id = UUID()
    let image: NSImage
    let right: Bool
    var landed = false
    var gone = false
}

/// Full-screen, click-through effects on the glow screen; the panel is only on screen while something plays.
/// The photo handed over from the phone: enters at the edge (0), shows big in the middle (1), shrinks onto the Desktop (2).
struct Hero {
    let image: NSImage
    let right: Bool
    let y: Double
    var start: LiveCard? = nil // where the split photo was when you let go: the hand-off continues from there
    var phase = 0
}

final class FXState: ObservableObject {
    @Published var waves: [(Date, Bool, Double)] = []
    @Published var flyers: [Flyer] = []
    @Published var ambient = 0.0   // live light near the phone, follows the phone's drag (0…1)
    @Published var ambientY = 0.5
    @Published var hero: Hero?
    @Published var preview: NSImage?  // the photo currently being handed over
    @Published var live: LiveCard?    // its position on the phone, while dragging
    var heroShownAt: Date?
    var awaiting: (y: Double, right: Bool, until: Date)? // dropped before the preview arrived: hero comes with the file
    var onActive: (Bool) -> Void = { _ in }

    func setLive(_ m: DropMessage) {
        ambient = m.progress ?? 0
        ambientY = m.y ?? 0.5
        live = ambient > 0 ? LiveCard(m) : nil
        if ambient > 0 { onActive(true) } else { idleCheck() }
    }

    func drop(y: Double, right: Bool) {
        ambient = 0
        wave(right: right, strength: 0.8)
        guard let img = preview else {
            dropLog.notice("drop without preview: hero will use the file's thumbnail")
            awaiting = (y, right, Date().addingTimeInterval(30))
            return
        }
        preview = nil
        showHero(img, y: y, right: right, start: live)
        live = nil
    }

    /// The file arrived. Returns true if it belongs to a hand-off (so no separate fly-in).
    func fileArrived(_ thumbnail: NSImage, url: URL) -> Bool {
        if let h = hero {
            grab = (h.image, url)
            landHero()
            return true
        }
        if let a = awaiting, a.until > Date() {
            awaiting = nil
            grab = (thumbnail, url)
            showHero(thumbnail, y: a.y, right: a.right, landAfter: 1.6)
            return true
        }
        return false
    }

    // Grabbing the arrived photo: while it's big on screen you can drag it like a file (anywhere, or back to the phone).
    @Published var grab: (image: NSImage, url: URL)?
    var grabHover = false
    var onGrabReady: () -> Void = {}
    var onGrabDone: () -> Void = {}

    func grabbed() {
        hero = nil   // the drag image takes over; the file stays where it landed
        onGrabDone()
        idleCheck()
    }

    func showHero(_ img: NSImage, y: Double, right: Bool, start: LiveCard? = nil, landAfter: Double? = nil) {
        dropLog.notice("hero shown")
        hero = Hero(image: img, right: right, y: y, start: start)
        onActive(true)
        DispatchQueue.main.async {
            self.heroShownAt = Date()
            withAnimation(.spring(response: 0.7, dampingFraction: 0.82)) { self.hero?.phase = 1 }
        }
        // land once the file is in (landAfter), or after 8 s if it never comes
        DispatchQueue.main.asyncAfter(deadline: .now() + (landAfter ?? 8)) { self.landHero() }
    }

    /// The file arrived: once the photo has been on show for a moment, shrink it onto the Desktop.
    func landHero() {
        guard hero?.phase == 1 else { return }
        if grab != nil { onGrabReady() }
        // ~3 s on show to grab it; waits while the pointer is over it
        let wait = max(0, (grab != nil ? 3 : 1.6) - Date().timeIntervalSince(heroShownAt ?? .distantPast))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            guard self.hero?.phase == 1 else { return }
            if self.grabHover { return self.landHero() }
            self.onGrabDone()
            withAnimation(.easeIn(duration: 0.5)) { self.hero?.phase = 2 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { self.hero = nil; self.idleCheck() }
        }
    }

    func wave(right: Bool, strength: Double = 1) {
        let w = (Date(), right, strength)
        waves.append(w)
        onActive(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + WaveLayer.duration + 0.1) {
            self.waves.removeAll { $0.0 == w.0 }
            self.idleCheck()
        }
    }

    func fly(_ image: NSImage, right: Bool) {
        let f = Flyer(image: image, right: right)
        flyers.append(f)
        onActive(true)
        func set(_ change: @escaping (inout Flyer) -> Void, after: Double, _ anim: Animation) {
            DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                guard let i = self.flyers.firstIndex(where: { $0.id == f.id }) else { return }
                withAnimation(anim) { change(&self.flyers[i]) }
            }
        }
        set({ $0.landed = true }, after: 0.03, .spring(response: 0.7, dampingFraction: 0.8))
        set({ $0.gone = true }, after: 1.6, .easeOut(duration: 0.4))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) {
            self.flyers.removeAll { $0.id == f.id }
            self.idleCheck()
        }
    }

    func idleCheck() { if waves.isEmpty && flyers.isEmpty && hero == nil && ambient == 0 { onActive(false) } }
}

struct FXView: View {
    @ObservedObject var fx: FXState
    @AppStorage("phoneSide") var phoneSide = "right"

    var body: some View {
        GeometryReader { geo in
            let right = phoneSide == "right"
            let w = geo.size.width, h = geo.size.height
            ZStack {
                // warm light where the phone touches the Mac (lower part of the edge), growing as the card approaches
                RadialGradient(stops: [
                    .init(color: Color(red: 1, green: 0.96, blue: 0.9).opacity(0.75 * fx.ambient), location: 0),
                    .init(color: Color(red: 1, green: 0.8, blue: 0.65).opacity(0.45 * fx.ambient), location: 0.3),
                    .init(color: Color(red: 0.6, green: 1, blue: 0.75).opacity(0.18 * fx.ambient), location: 0.55),
                    .init(color: Color(red: 0.65, green: 0.5, blue: 1).opacity(0.15 * fx.ambient), location: 0.75),
                    .init(color: .clear, location: 1),
                ], center: UnitPoint(x: right ? 1 : 0, y: 0.55 + 0.4 * fx.ambientY),
                   startRadius: 0, endRadius: h * (0.3 + 0.6 * fx.ambient))
                    .opacity(fx.ambient > 0 ? 1 : 0)
                    .animation(.linear(duration: 0.1), value: fx.ambient)
                WaveLayer(starts: fx.waves)
                // the part of the photo that has crossed the phone's edge, drawn at the same place on this screen
                if let card = fx.live, let img = fx.preview, fx.hero == nil {
                    let f = card.frame(in: geo.size, phoneOnRight: right)
                    Image(nsImage: img).resizable().scaledToFill()
                        .frame(width: f.size.width, height: f.size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
                        .rotationEffect(.degrees(card.angle))
                        .position(f.center)
                }
                if let hero = fx.hero, !(hero.phase == 1 && fx.grab != nil) { // when grabbable, the grab panel draws it
                    let a = hero.image.size.width / max(hero.image.size.height, 1)
                    let big = a > 1 ? CGSize(width: min(w * 0.6, h * 0.6 * a), height: min(w * 0.6, h * 0.6 * a) / a)
                                    : CGSize(width: h * 0.6 * a, height: h * 0.6)
                    let start = hero.start?.frame(in: geo.size, phoneOnRight: hero.right)
                        ?? (center: CGPoint(x: hero.right ? w + 80 : -80, y: h * (0.55 + 0.4 * hero.y)),
                            size: CGSize(width: 160 * a, height: 160))
                    let size = hero.phase == 0 ? start.size : hero.phase == 1 ? big : CGSize(width: 64 * a, height: 64)
                    Image(nsImage: hero.image).resizable().scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .clipShape(RoundedRectangle(cornerRadius: hero.phase == 1 ? 16 : 10, style: .continuous))
                        .shadow(color: .black.opacity(0.45), radius: 28, y: 12)
                        .rotationEffect(.degrees(hero.phase == 0 ? hero.start?.angle ?? 0 : 0))
                        .opacity(hero.phase == 2 ? 0.2 : 1)
                        .position(hero.phase == 0 ? start.center
                                  : hero.phase == 1 ? CGPoint(x: w / 2, y: h / 2)
                                  : CGPoint(x: w - 70, y: 90)) // new Desktop icons appear top right
                }
                ForEach(fx.flyers) { f in
                    Image(nsImage: f.image).resizable().scaledToFit()
                        .frame(width: 84, height: 84)
                        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                        .scaleEffect(f.landed ? 1 : 0.7)
                        .opacity(f.gone ? 0 : 1)
                        .position(x: f.landed ? (f.right ? geo.size.width - 200 : 200) : (f.right ? geo.size.width + 50 : -50),
                                  y: geo.size.height * (f.landed ? 0.5 : 0.42))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// The arrived photo, big in the middle and draggable like the file it is (click-through FX can't take the mouse).
struct GrabView: View {
    @ObservedObject var fx: FXState
    var body: some View {
        if let g = fx.grab {
            Image(nsImage: g.image).resizable().scaledToFill()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.45), radius: 28, y: 12)
                .overlay(alignment: .bottom) {
                    Text("Drag it anywhere — or back to the iPhone")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.black.opacity(0.45), in: Capsule()).padding(12)
                }
                .onHover { fx.grabHover = $0 }
                .onDrag({
                    DispatchQueue.main.async { fx.grabbed() }
                    return NSItemProvider(object: g.url as NSURL)
                }, preview: {
                    Image(nsImage: g.image).resizable().scaledToFit().frame(width: 200, height: 200)
                })
        }
    }
}

/// Edge light + label for one edge while a file is being dragged (click-through panel).
struct GlowView: View {
    @ObservedObject var drop: DropCenter
    @ObservedObject var state: GlowState
    let right: Bool

    var body: some View {
        let viaAirDrop = drop.peers.isEmpty
        let on = state.dragging && (!viaAirDrop || prefs.bool(forKey: "airdrop"))
        let hover = state.hover[right ? 1 : 0]
        ZStack(alignment: right ? .trailing : .leading) {
            EdgeStrip(right: right, strength: on ? (hover ? 1 : 0.4) : 0)
            if on {
                SwiftUI.Label(hover ? "Release to send" : viaAirDrop ? "AirDrop" : "Send to iPhone",
                              systemImage: viaAirDrop ? "dot.radiowaves.left.and.right" : "iphone.gen3")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.black.opacity(0.35), in: Capsule())
                    .padding(right ? .trailing : .leading, 18)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: right ? .trailing : .leading)
        .animation(.easeOut(duration: 0.25), value: hover)
        .animation(.easeOut(duration: 0.2), value: on)
    }
}

/// Narrow invisible drop target on one edge; only takes the mouse while a file is being dragged.
struct DropZoneView: View {
    @ObservedObject var drop: DropCenter
    @ObservedObject var state: GlowState
    let right: Bool

    var body: some View {
        let i = right ? 1 : 0
        // a hint of alpha while dragging: fully transparent pixels would let the drag fall through to the window below
        Color.white.opacity(state.dragging ? 0.02 : 0)
            .contentShape(Rectangle())
            .onDrop(of: [.fileURL], isTargeted: Binding(get: { state.hover[i] }, set: { state.hover[i] = $0 })) { providers in
                let viaAirDrop = drop.peers.isEmpty // phone app not open: hand the files to the real AirDrop
                guard !viaAirDrop || prefs.bool(forKey: "airdrop") else { return false }
                if !viaAirDrop { prefs.set(right ? "right" : "left", forKey: "phoneSide") } // dropped here → phone is here
                let group = DispatchGroup(), lock = NSLock()
                var urls: [URL] = []
                for p in providers {
                    group.enter()
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        if let url { lock.lock(); urls.append(url); lock.unlock() }
                        group.leave()
                    }
                }
                group.notify(queue: .main) {
                    guard !urls.isEmpty else { return }
                    if !viaAirDrop, var m = drop.lastLiveOut { // hand-off: the phone continues from the split position
                        m.type = "drop"
                        drop.broadcast(m)
                    }
                    if viaAirDrop {
                        // AirDrop's own device picker opens; pick the iPhone there
                        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
                        drop.onWave()
                    } else {
                        drop.send(urls)
                    }
                }
                return true
            }
    }
}
