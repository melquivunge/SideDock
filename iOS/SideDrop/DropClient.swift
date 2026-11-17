// SideDrop (iPhone side): finds the Mac's Bluetooth beacon, connects when the phone is held next to it,
// then sends/receives files over MultipeerConnectivity. Mac side: ../../Drop.swift
import SwiftUI
import MultipeerConnectivity
import CoreBluetooth

// Shared with the Mac (Drop.swift) — keep in sync.
let dropServiceType = "sidedrop"
let dropBLEService = CBUUID(string: "5E1D0C4A-8F3B-4C1E-9A57-2D6B1F0E7A11")
struct DropMessage: Codable {
    var type: String                 // hello | pair | ready | side | live | preview | drop
    var secret: String? = nil
    var side: String? = nil
    var progress: Double? = nil      // live: 0…1 how close the card is to the edge
    var y: Double? = nil             // live/drop: card height on the phone, 0 top … 1 bottom
    var preview: Data? = nil         // preview: small JPEG of the photo being handed over
    var count: Int? = nil
    // live card geometry in phone points, so the Mac can draw the part that has crossed the edge
    var cx: Double? = nil, cy: Double? = nil   // card centre
    var cw: Double? = nil, ch: Double? = nil   // card size
    var pw: Double? = nil, ph: Double? = nil   // phone screen size
    var angle: Double? = nil                   // card tilt, degrees
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

struct Transfer: Identifiable {
    let id = UUID()
    let name: String
    let incoming: Bool
    var fraction = 0.0
}

let receivedDir = URL.documentsDirectory.appendingPathComponent("Received")

/// A file being dragged toward this phone on the Mac (phone points). cx = how far the card's centre is past the
/// edge that touches the Mac (negative = still on the Mac), cy = offset from the screen's vertical centre.
struct IncomingCard {
    var cx, cy, cw, ch: Double
    var touchLeft: Bool
    var progress: Double
    init?(_ m: DropMessage) {
        guard let cx = m.cx, let cy = m.cy, let cw = m.cw, let ch = m.ch else { return nil }
        (self.cx, self.cy, self.cw, self.ch) = (cx, cy, cw, ch)
        touchLeft = m.side != "right"
        progress = m.progress ?? 0
    }
    func frame(in s: CGSize) -> (center: CGPoint, size: CGSize) {
        (CGPoint(x: touchLeft ? cx : s.width - cx, y: s.height / 2 + cy), CGSize(width: cw, height: ch))
    }
}

/// Mac → phone hand-off state. Separate object so only the overlay redraws ~30×/s, not the whole screen.
final class IncomingState: ObservableObject {
    @Published var preview: UIImage?
    @Published var live: IncomingCard?
    @Published var hero: (image: UIImage, start: IncomingCard?, phase: Int)?
    var shownAt = Date.distantPast
    var heroFile: URL?                       // the arrived file behind the big photo
    var pendingGrab: ((URL) -> Void)?        // touched before the file finished arriving

    func drop(_ m: DropMessage) {
        let start = IncomingCard(m) ?? live
        live = nil
        guard let img = preview else { return }
        preview = nil
        hero = (img, start, 0)
        DispatchQueue.main.async {
            self.shownAt = Date()
            withAnimation(.spring(response: 0.65, dampingFraction: 0.82)) { self.hero?.phase = 1 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.landed() } // file never came: tidy up
    }

    /// You touched the arriving photo: take it (now, or as soon as the file is in).
    func grab(_ open: @escaping (URL) -> Void) {
        guard hero?.phase == 1 else { return }
        if let url = heroFile {
            hero = nil
            heroFile = nil
            open(url)
        } else {
            pendingGrab = open
        }
    }

    /// The file is in: give you ~2.5 s to grab it, then the photo drops into the "From your Mac" list.
    func landed(_ url: URL? = nil) {
        guard hero?.phase == 1 else { return }
        heroFile = url ?? heroFile
        if let open = pendingGrab, let url = heroFile {
            pendingGrab = nil
            return grab(open)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, 2.5 - Date().timeIntervalSince(shownAt))) {
            guard self.hero?.phase == 1, self.pendingGrab == nil else { return }
            withAnimation(.easeIn(duration: 0.45)) { self.hero?.phase = 2 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.hero = nil; self.heroFile = nil }
        }
    }
}
/// Pairing secrets live here so the share extension (SideDropShare) can use them too.
let sharedDefaults = UserDefaults(suiteName: "group.com.melquiantonio.sidedrop") ?? .standard

final class DropClient: NSObject, ObservableObject {
    @Published var signal: Double?        // smoothed Bluetooth signal of the nearest Mac, dBm
    @Published var macName: String?       // set once the Mac has accepted us
    @Published var connecting = false
    @Published var bluetoothOff = false
    @Published var received: [URL] = []
    @Published var transfers: [Transfer] = []
    // Deck: what the Mac reports back
    @Published var deckValues: [String: Double] = [:]
    @Published var deckApps: [DeckApp] = []
    @Published var track: (title: String, artist: String, playing: Bool)?
    @Published var art: (url: URL?, image: UIImage?)?   // cover of what's playing
    @Published var trackTime: (position: Double, duration: Double, at: Date) = (0, 0, .distantPast)
    @Published var creative: (key: String, name: String)? // Photoshop etc. in front on the Mac
    @Published var agents: [AgentStatus] = []
    @Published var macWindows: [DeckApp] = []   // apps with windows (path = pid)
    @Published var macScreens: [String] = []
    @Published var deckResult: String?          // what the Mac says happened (shown as a banner)
    let incoming = IncomingState()
    /// Calibration knob: how strong the signal must be to count as "next to the Mac". Radios differ per device/room.
    @Published var threshold: Double = UserDefaults.standard.object(forKey: "threshold") as? Double ?? -50 {
        didSet { UserDefaults.standard.set(threshold, forKey: "threshold") }
    }

    let me = MCPeerID(displayName: UIDevice.current.name)
    lazy var session: MCSession = {
        let s = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .required)
        s.delegate = self
        return s
    }()
    lazy var browser: MCNearbyServiceBrowser = {
        let b = MCNearbyServiceBrowser(peer: me, serviceType: dropServiceType)
        b.delegate = self
        return b
    }()
    var central: CBCentralManager?
    var macs: [String: MCPeerID] = [:]  // beacon id → Multipeer peer
    var rssi: [String: Double] = [:]    // beacon id → smoothed signal
    var peer: MCPeerID?, peerBeacon: String?
    var observers: [UUID: NSKeyValueObservation] = [:]
    var started = false

    /// 0…1 for the UI: how close we are to connecting.
    var closeness: Double {
        guard let s = signal else { return 0 }
        return min(1, max(0, (s + 90) / (threshold + 90)))
    }

    var status: String {
        if let macName { return "Connected to \(macName)" }
        if connecting { return "Connecting…\nApprove on your Mac if it asks" }
        if bluetoothOff { return "Turn on Bluetooth" }
        if signal == nil { return "Looking for your Mac…\nMake sure SideDock is running" }
        return "Hold your iPhone next to the Mac"
    }

    func start() {
        guard !started else { return }
        started = true
        try? FileManager.default.createDirectory(at: receivedDir, withIntermediateDirectories: true)
        received = ((try? FileManager.default.contentsOfDirectory(at: receivedDir, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .sorted { created($0) > created($1) }
        browser.startBrowsingForPeers()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func created(_ u: URL) -> Date {
        (try? u.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
    }

    func connectIfClose(_ beacon: String) {
        guard peer == nil, let s = rssi[beacon], s > threshold, let p = macs[beacon] else { return }
        peer = p
        peerBeacon = beacon
        connecting = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        browser.invitePeer(p, to: session, withContext: nil, timeout: 20)
    }

    func disconnect() {
        session.disconnect()
        reset()
    }

    func reset() {
        peer = nil
        peerBeacon = nil
        macName = nil
        connecting = false
        rssi = [:] // start fresh: you have to bring the phone close again
        signal = nil
        if let c = central, c.state == .poweredOn {
            c.scanForPeripherals(withServices: [dropBLEService], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
    }

    /// side: which way the user swiped ("left"/"right"); the Mac uses it to know which edge the phone is on.
    func send(_ urls: [URL], side: String? = nil) {
        guard let peer, macName != nil else { return }
        if let side, let d = try? JSONEncoder().encode(DropMessage(type: "side", side: side)) {
            UserDefaults.standard.set(side, forKey: "macSide")
            try? session.send(d, toPeers: [peer], with: .reliable)
        }
        for url in urls {
            let t = Transfer(name: url.lastPathComponent, incoming: false)
            transfers.append(t)
            let p = session.sendResource(at: url, withName: url.lastPathComponent, toPeer: peer) { [weak self] _ in
                DispatchQueue.main.async { self?.finish(t.id) }
            }
            observe(p, t.id)
        }
    }

    func message(_ m: DropMessage, reliable: Bool = true) {
        guard let peer, macName != nil, let d = try? JSONEncoder().encode(m) else { return }
        try? session.send(d, toPeers: [peer], with: reliable ? .reliable : .unreliable)
    }

    func sendLive(progress: Double, y: Double, card: CGRect? = nil, screen: CGSize = .zero, angle: Double = 0) {
        var m = DropMessage(type: "live", progress: progress, y: y)
        if let card {
            m.cx = card.midX; m.cy = card.midY; m.cw = card.width; m.ch = card.height
            m.pw = screen.width; m.ph = screen.height; m.angle = angle
        }
        message(m, reliable: progress == 0)
    }
    // Deck → Mac
    func deckSet(_ control: String, _ v: Double) {
        deckValues[control] = v
        var m = DropMessage(type: "control"); m.control = control; m.value = v
        message(m, reliable: false)
    }
    func deckLaunch(_ path: String) { var m = DropMessage(type: "launch"); m.path = path; message(m) }
    func deckMedia(_ cmd: String) {
        var m = DropMessage(type: "media"); m.cmd = cmd; message(m)
        if cmd == "playpause", let t = track { track = (t.title, t.artist, !t.playing) } // feels instant
    }
    func deckKeys(_ k: String) { var m = DropMessage(type: "keys"); m.keys = k; message(m) }
    func deckColor(_ hex: String) { var m = DropMessage(type: "color"); m.hex = hex; message(m) }
    func deckAgentOpen(_ cmd: String) { var m = DropMessage(type: "agentOpen"); m.cmd = cmd; message(m) }
    func deckWindows() { message(DropMessage(type: "windows")) }
    func deckWindow(_ cmd: String, pid: Int, screen: Int = 0) {
        var m = DropMessage(type: "window"); m.cmd = cmd; m.pids = [pid]; m.screen = screen; message(m)
    }
    func deckSplit(_ pids: [Int], screen: Int) { var m = DropMessage(type: "split"); m.pids = pids; m.screen = screen; message(m) }
    func deckRefresh(apps: Bool = false) { message(DropMessage(type: apps ? "apps" : "state")) }

    func sendDrop(y: Double, side: String) { message(DropMessage(type: "drop", side: side, y: y)) }
    func sendPreview(_ image: UIImage, count: Int) {
        let r = UIGraphicsImageRenderer(size: fit(image.size, 600))
        let small = r.jpegData(withCompressionQuality: 0.65) { _ in image.draw(in: CGRect(origin: .zero, size: r.format.bounds.size)) }
        message(DropMessage(type: "preview", preview: small, count: count))
    }

    func fit(_ s: CGSize, _ m: CGFloat) -> CGSize {
        let k = min(1, m / max(s.width, s.height))
        return CGSize(width: s.width * k, height: s.height * k)
    }

    func delete(at offsets: IndexSet) {
        for i in offsets { try? FileManager.default.removeItem(at: received[i]) }
        received.remove(atOffsets: offsets)
    }

    func forgetMacs() {
        for d in [UserDefaults.standard, sharedDefaults] {
            for key in d.dictionaryRepresentation().keys where key.hasPrefix("secret.") { d.removeObject(forKey: key) }
        }
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

    func save(_ tmp: URL, name: String) {
        var clean = (name as NSString).lastPathComponent // name comes from the Mac: no paths allowed
        if clean.isEmpty || clean == "." || clean == ".." { clean = "file" }
        let base = (clean as NSString).deletingPathExtension, ext = (clean as NSString).pathExtension
        var dst = receivedDir.appendingPathComponent(clean), n = 2
        while FileManager.default.fileExists(atPath: dst.path) {
            dst = receivedDir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        guard (try? FileManager.default.moveItem(at: tmp, to: dst)) != nil else { return }
        received.insert(dst, at: 0)
        incoming.landed(dst)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

extension DropClient: CBCentralManagerDelegate, MCNearbyServiceBrowserDelegate, MCSessionDelegate {
    // MARK: Bluetooth closeness

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        bluetoothOff = c.state != .poweredOn
        guard c.state == .poweredOn else { return }
        c.scanForPeripherals(withServices: [dropBLEService], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let r = RSSI.doubleValue
        guard r < 0, let beacon = advertisementData[CBAdvertisementDataLocalNameKey] as? String else { return } // 127 = unknown
        rssi[beacon] = rssi[beacon].map { $0 * 0.7 + r * 0.3 } ?? r // smooth out radio jitter
        // publish only real changes: every publish redraws the whole screen, and adverts arrive many times a second
        if let best = rssi.values.max(), signal == nil || abs(best - signal!) >= 2 { signal = best.rounded() }
        connectIfClose(beacon)
    }

    // MARK: Multipeer discovery

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        guard let beacon = info?["id"] else { return }
        DispatchQueue.main.async {
            self.macs[beacon] = peerID
            self.connectIfClose(beacon)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async { self.macs = self.macs.filter { $0.value != peerID } }
    }

    // MARK: Session

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            guard peerID == self.peer else { return }
            switch state {
            case .connected:
                let secret = self.peerBeacon.flatMap {
                    sharedDefaults.string(forKey: "secret.\($0)") ?? UserDefaults.standard.string(forKey: "secret.\($0)")
                }
                if let d = try? JSONEncoder().encode(DropMessage(type: "hello", secret: secret)) {
                    try? session.send(d, toPeers: [peerID], with: .reliable)
                }
            case .notConnected: self.reset()
            default: break
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let m = try? JSONDecoder().decode(DropMessage.self, from: data) else { return }
        DispatchQueue.main.async {
            switch m.type {
            case "pair":
                if let s = m.secret, let b = self.peerBeacon { sharedDefaults.set(s, forKey: "secret.\(b)") }
            case "preview" where self.macName != nil:
                if let d = m.preview { self.incoming.preview = UIImage(data: d) }
            case "live" where self.macName != nil:
                self.incoming.live = (m.progress ?? 0) > 0 ? IncomingCard(m) : nil
            case "drop" where self.macName != nil:
                self.incoming.drop(m)
            case "state" where self.macName != nil:
                self.deckValues.merge(m.values ?? [:]) { _, new in new }
                let changed = m.title != self.track?.title
                self.track = m.title.map { ($0, m.artist ?? "", m.playing ?? false) }
                self.trackTime = (m.position ?? 0, m.duration ?? 0, Date())
                if let d = m.artData { self.art = (nil, UIImage(data: d)) }
                else if let u = m.artURL, !u.isEmpty { if self.art?.url?.absoluteString != u { self.art = (URL(string: u), nil) } }
                else if changed { self.art = nil }
                self.creative = m.front.map { ($0, m.frontName ?? $0) }
                self.agents = m.agents ?? []
            case "result" where self.macName != nil:
                self.deckResult = m.title
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if self.deckResult == m.title { self.deckResult = nil } }
            case "windows" where self.macName != nil:
                self.macWindows = m.apps ?? []
                self.macScreens = m.screens ?? []
            case "apps" where self.macName != nil:
                self.deckApps = m.apps ?? []
            case "ready":
                // older builds kept the secret in the app's own defaults: copy it over for the share extension
                if let b = self.peerBeacon, sharedDefaults.string(forKey: "secret.\(b)") == nil,
                   let old = UserDefaults.standard.string(forKey: "secret.\(b)") {
                    sharedDefaults.set(old, forKey: "secret.\(b)")
                }
                self.macName = peerID.displayName
                self.connecting = false
                self.central?.stopScan() // connected: no need to keep measuring closeness
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            default: break
            }
        }
    }

    func session(_ session: MCSession, didStartReceivingResourceWithName name: String, fromPeer peerID: MCPeerID,
                 with progress: Progress) {
        DispatchQueue.main.async {
            guard peerID == self.peer, self.macName != nil else { return progress.cancel() }
            let t = Transfer(name: name, incoming: true)
            self.transfers.append(t)
            self.observe(progress, t.id)
        }
    }

    func session(_ session: MCSession, didFinishReceivingResourceWithName name: String, fromPeer peerID: MCPeerID,
                 at localURL: URL?, withError error: Error?) {
        var tmp: URL? // localURL disappears when this returns
        if error == nil, let localURL {
            let t = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            if (try? FileManager.default.moveItem(at: localURL, to: t)) != nil { tmp = t }
        }
        DispatchQueue.main.async {
            if let t = self.transfers.first(where: { $0.incoming && $0.name == name }) { self.finish(t.id) }
            if let tmp { self.save(tmp, name: name) }
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
}
