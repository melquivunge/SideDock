// Share sheet → SideDrop: sends the shared photos/files straight to the paired Mac, without opening the app.
// Uses the pairing secret the app stored in the shared App Group (pair once in the app, next to the Mac).
import UIKit
import SwiftUI
import MultipeerConnectivity
import UniformTypeIdentifiers

// Shared with the app and the Mac — keep in sync.
let dropServiceType = "sidedrop"
let appGroup = "group.com.melquiantonio.sidedrop"
struct DropMessage: Codable { var type: String; var secret: String? = nil; var side: String? = nil }

final class ShareViewController: UIViewController {
    let sender = ShareSender()

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareView(sender: sender) { [weak self] in self?.finish() })
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        sender.onDone = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { self?.finish() }
        }
        collectFiles()
    }

    /// Copy every shared attachment to temp (the originals are only readable inside the callback).
    func collectFiles() {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        let group = DispatchGroup(), lock = NSLock()
        var urls: [URL] = []
        for p in providers {
            group.enter()
            _ = p.loadFileRepresentation(for: .item, openInPlace: false) { url, _, _ in
                defer { group.leave() }
                guard let url, let tmp = copyToTemp(url) else { return }
                lock.lock(); urls.append(tmp); lock.unlock()
            }
        }
        group.notify(queue: .main) { [weak self] in
            if urls.isEmpty { self?.sender.fail("Nothing to send") } else { self?.sender.start(urls) }
        }
    }

    func finish() {
        sender.stop()
        extensionContext?.completeRequest(returningItems: nil)
    }
}

func copyToTemp(_ url: URL) -> URL? {
    let ok = url.startAccessingSecurityScopedResource()
    defer { if ok { url.stopAccessingSecurityScopedResource() } }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let dst = dir.appendingPathComponent(url.lastPathComponent)
    return (try? FileManager.default.copyItem(at: url, to: dst)) != nil ? dst : nil
}

final class ShareSender: NSObject, ObservableObject {
    @Published var status = "Looking for your Mac…"
    @Published var progress = 0.0
    @Published var done = false
    @Published var failed = false
    var onDone: () -> Void = {}

    let shared = UserDefaults(suiteName: appGroup)
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
    var files: [URL] = []
    var mac: MCPeerID?, macBeacon: String?
    var fractions: [Double] = []
    var finished = 0
    var observers: [NSKeyValueObservation] = []

    func start(_ urls: [URL]) {
        files = urls
        fractions = Array(repeating: 0, count: urls.count)
        browser.startBrowsingForPeers()
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.mac == nil, !self.done else { return }
            self.fail("Mac not found.\nMake sure SideDock is running and Wi-Fi and Bluetooth are on.")
        }
    }

    func stop() {
        browser.stopBrowsingForPeers()
        session.disconnect()
    }

    func fail(_ message: String) {
        status = message
        failed = true
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    func sendFiles(to peer: MCPeerID) {
        status = files.count == 1 ? "Sending to \(peer.displayName)…" : "Sending \(files.count) items to \(peer.displayName)…"
        for (i, url) in files.enumerated() {
            let p = session.sendResource(at: url, withName: url.lastPathComponent, toPeer: peer) { [weak self] error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if error != nil { return self.fail("Sending failed. Try again.") }
                    self.fractions[i] = 1
                    self.finished += 1
                    self.updateProgress()
                    if self.finished == self.files.count {
                        self.done = true
                        self.status = "Sent to \(peer.displayName)"
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        self.onDone()
                    }
                }
            }
            if let p {
                observers.append(p.observe(\.fractionCompleted) { [weak self] prog, _ in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.fractions[i] = prog.fractionCompleted
                        self.updateProgress()
                    }
                })
            }
        }
    }

    func updateProgress() { progress = fractions.reduce(0, +) / Double(max(fractions.count, 1)) }
}

extension ShareSender: MCNearbyServiceBrowserDelegate, MCSessionDelegate {
    /// Only connect to a Mac this phone was paired with in the app.
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async {
            guard self.mac == nil, let beacon = info?["id"], self.shared?.string(forKey: "secret.\(beacon)") != nil else { return }
            self.mac = peerID
            self.macBeacon = beacon
            self.status = "Connecting to \(peerID.displayName)…"
            browser.invitePeer(peerID, to: self.session, withContext: nil, timeout: 15)
            browser.stopBrowsingForPeers()
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            guard peerID == self.mac else { return }
            switch state {
            case .connected:
                let secret = self.macBeacon.flatMap { self.shared?.string(forKey: "secret.\($0)") }
                if let d = try? JSONEncoder().encode(DropMessage(type: "hello", secret: secret)) {
                    try? session.send(d, toPeers: [peerID], with: .reliable)
                }
            case .notConnected where !self.done && !self.failed:
                self.fail("Lost the connection to your Mac.")
            default: break
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let m = try? JSONDecoder().decode(DropMessage.self, from: data), m.type == "ready" else { return }
        DispatchQueue.main.async { self.sendFiles(to: peerID) }
    }

    func session(_ session: MCSession, didStartReceivingResourceWithName name: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName name: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
}

struct ShareView: View {
    @ObservedObject var sender: ShareSender
    let close: () -> Void

    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 14) {
                Image(systemName: sender.done ? "checkmark.circle.fill" : sender.failed ? "exclamationmark.triangle.fill" : "laptopcomputer")
                    .font(.system(size: 42))
                    .foregroundStyle(sender.done ? .green : sender.failed ? .orange : .accentColor)
                    .symbolEffect(.pulse, isActive: !sender.done && !sender.failed)
                    .contentTransition(.symbolEffect(.replace))
                Text(sender.status).font(.headline).multilineTextAlignment(.center)
                if sender.progress > 0 && !sender.done { ProgressView(value: sender.progress) }
                Button(sender.done || sender.failed ? "Close" : "Cancel", action: close)
                    .buttonStyle(.bordered)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
            .padding()
        }
    }
}
