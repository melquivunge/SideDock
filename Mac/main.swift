// SideDock: a customisable dock on the left/right edge of one screen or all screens.
// ponytail: the macOS Dock has no API to show it on several screens, so we hide it and draw our own.
import AppKit
import SwiftUI
import ApplicationServices
import QuickLookThumbnailing
import MultipeerConnectivity

// MARK: - System Dock hide/restore

enum SystemDock {
    static func hide() {
        if prefs.string(forKey: "origAutohide") == nil {
            let v = sh("defaults", "read", "com.apple.dock", "autohide")
            prefs.set(v == "1" ? "true" : "false", forKey: "origAutohide")
        }
        sh("defaults", "write", "com.apple.dock", "autohide", "-bool", "true")
        sh("defaults", "write", "com.apple.dock", "autohide-delay", "-float", "1000")
        sh("killall", "Dock")
    }
    static func restore() {
        guard let orig = prefs.string(forKey: "origAutohide") else { return } // not hidden by us (e.g. dock turned off)
        sh("defaults", "write", "com.apple.dock", "autohide", "-bool", orig)
        sh("defaults", "delete", "com.apple.dock", "autohide-delay")
        sh("killall", "Dock")
        prefs.removeObject(forKey: "origAutohide")
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Model()
    let drop = DropCenter()
    var shelf: NSPanel?
    let glowState = GlowState()
    var glows: [NSPanel] = []     // light, left + right edge of the glow screen
    var dropZones: [NSPanel] = [] // drop targets, left + right
    let fx = FXState()
    var grabPanel: NSPanel?
    var airdropWatcher: AirDropWatcher?
    var fxPanel: NSPanel?
    var dragBaseline = -1
    var dragResetPending = false
    var panels: [(panel: NSPanel, screen: NSScreen, state: PanelState)] = []
    var laidOutScreen = ""
    var status: NSStatusItem!
    let popover = NSPopover()
    let axQueue = DispatchQueue(label: "sidedock.ax")
    lazy var controls = Controls()
    var launcher: NSPanel?
    var launcherApps: [(url: URL, icon: NSImage)] = []
    var clickMonitor: Any?
    var dockApplied: String?
    let stash = Stash()
    var axBusy = false

    var side: String { prefs.string(forKey: "side") ?? "left" }
    var screenChoice: String { prefs.string(forKey: "screen") ?? "all" }

    func applicationDidFinishLaunching(_ n: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "SideDock")
        status.button?.target = self
        status.button?.action = #selector(togglePanel)
        popover.behavior = .transient
        let hc = NSHostingController(rootView: ControlPanel(drop: drop))
        hc.sizingOptions = .preferredContentSize
        popover.contentViewController = hc
        popover.contentSize = NSSize(width: 340, height: 640)

        drop.onDeck = { [weak self] m, peer in MainActor.assumeIsolated { self?.handleDeck(m, from: peer) } }
        drop.onActivity = { [weak self] in
            MainActor.assumeIsolated { if prefs.bool(forKey: "shelfAuto") { self?.showShelf() } }
        }
        drop.onWave = { [weak self] in
            MainActor.assumeIsolated { self?.fx.wave(right: prefs.string(forKey: "phoneSide") != "left") }
        }
        drop.onLive = { [weak self] m in MainActor.assumeIsolated { self?.fx.setLive(m) } }
        drop.onPreview = { [weak self] img in MainActor.assumeIsolated { self?.fx.preview = img } }
        drop.onDrop = { [weak self] y in
            MainActor.assumeIsolated { self?.fx.drop(y: y, right: prefs.string(forKey: "phoneSide") != "left") }
        }
        drop.onReceived = { [weak self] url in
            let r = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 900, height: 900), scale: 1, representationTypes: .all)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: r) { rep, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        let thumb = rep?.nsImage ?? NSWorkspace.shared.icon(forFile: url.path)
                        // part of a hand-off from the phone: the big photo settles onto the Desktop
                        if self.fx.fileArrived(thumb, url: url) { return }
                        let right = prefs.string(forKey: "phoneSide") != "left"
                        self.fx.fly(thumb, right: right)
                        self.fx.wave(right: right, strength: 0.6)
                    }
                }
            }
        }
        fx.onGrabReady = { [weak self] in MainActor.assumeIsolated { self?.showGrabPanel() } }
        fx.onGrabDone = { [weak self] in MainActor.assumeIsolated { self?.hideGrabPanel() } }
        fx.onActive = { [weak self] on in
            MainActor.assumeIsolated { on ? self?.fxPanel?.orderFrontRegardless() : self?.fxPanel?.orderOut(nil) }
        }
        applyDrop()

        let ws = NSWorkspace.shared.notificationCenter
        for (name, active) in [(NSWorkspace.sessionDidResignActiveNotification, false), (NSWorkspace.sessionDidBecomeActiveNotification, true)] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sessionActive = active; self?.applyDrop() }
            }
        }
        // App Profiles: remember the app in front (not us) so corners/edges can follow it
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier,
                  id != prefs.string(forKey: "lastAppID") else { return }
            prefs.set(id, forKey: "lastAppID")
            prefs.set(app.localizedName ?? id, forKey: "lastAppName")
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.reload(); self?.stash.reload(); self?.position() } // column count may change
            }
        }
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
        nc.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.applyDrop()
                self.applyDockEnabled()
                if self.screenChoice != self.laidOutScreen { self.layout() } else { self.position() }
            }
        }
        // ponytail: 60 Hz pointer polling (no tracking areas/permissions needed); event taps if CPU ever matters
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        let ax = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.keepWindowsClear(); self?.stash.calibrate() } }
        RunLoop.main.add(ax, forMode: .common)
        applyDockEnabled()
    }

    /// Turn SideDock's dock off/on without quitting: off gives the macOS Dock back; corners, edges and iPhone keep working.
    var dockOn: Bool { prefs.bool(forKey: "dockEnabled") }
    /// "replace": our dock instead of the macOS Dock · "alongside": macOS Dock stays, Hidden Dock slides out of its end
    var mode: String { prefs.string(forKey: "dockMode") ?? "replace" }
    var replacing: Bool { dockOn && mode == "replace" }
    func applyDockEnabled() {
        let key = "\(dockOn)-\(mode)"
        guard dockApplied != key else { return }
        dockApplied = key
        status.button?.appearsDisabled = !dockOn
        if replacing { SystemDock.hide() } else { SystemDock.restore() }
        if !dockOn { closeLauncher() }
        stash.setActive(dockOn && mode == "alongside")
        layout()
    }

    // MARK: App Launcher

    func toggleLauncher() {
        if launcher?.isVisible == true { return closeLauncher() }
        if launcherApps.isEmpty { launcherApps = allApps().map { ($0, flatIcon($0.path)) } }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: LauncherView.width, height: LauncherView.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isReleasedWhenClosed = false
        p.level = .init(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 2)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.contentView = NSHostingView(rootView: LauncherView(apps: launcherApps) { [weak self] in
            MainActor.assumeIsolated { self?.closeLauncher() }
        })
        // next to the launcher icon (= the pointer), on the screen side away from the dock, kept on screen
        let m = NSEvent.mouseLocation
        let vf = (NSScreen.screens.first { $0.frame.contains(m) } ?? NSScreen.main!).visibleFrame
        let w = LauncherView.width, h = LauncherView.height, off: CGFloat = prefs.double(forKey: "size") + 30
        // beside the macOS Dock: open away from it (it's usually at the bottom)
        let side = !replacing ? (stash.state.vertical ? ((stash.dock?.midX ?? 0) < vf.midX ? "left" : "right") : "bottom") : side
        var o = switch side {
        case "bottom": NSPoint(x: m.x - w / 2, y: m.y + off)
        case "right": NSPoint(x: m.x - off - w, y: m.y - h / 2)
        default: NSPoint(x: m.x + off, y: m.y - h / 2)
        }
        o.x = min(max(o.x, vf.minX + 8), vf.maxX - w - 8)
        o.y = min(max(o.y, vf.minY + 8), vf.maxY - h - 8)
        p.setFrameOrigin(o)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 }
        launcher = p
        // a click anywhere outside closes it
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeLauncher() }
        }
    }

    func closeLauncher() {
        launcher?.orderOut(nil)
        launcher = nil
        if let c = clickMonitor { NSEvent.removeMonitor(c) }
        clickMonitor = nil
    }

    // MARK: iPhone Deck

    /// control: set volume etc. · state: phone asks for values + now playing · apps: phone asks for the launch grid
    /// launch: open an app the phone threw · media: play/pause/next/previous
    func handleDeck(_ m: DropMessage, from peer: MCPeerID) {
        switch m.type {
        case "control":
            if let c = m.control, let v = m.value, Sys.names[c] != nil { Sys.set(c, v) }
        case "launch":
            // only apps we offered (pinned in the dock), never an arbitrary path
            if let path = m.path, model.items.contains(where: { $0.kind == .app && $0.id == path }) {
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init())
            }
        case "media":
            mediaCommand(m.cmd ?? "playpause")
        case "keys":
            if let k = m.keys { pressKeys(k) }
        case "color":
            if let h = m.hex { setCreativeColor(h) }
        case "windows":
            var r = DropMessage(type: "windows")
            r.apps = windowApps()
            r.screens = NSScreen.screens.map(\.name)
            drop.sendMessage(r, to: peer)
        case "split", "window":
            // do it, then tell the phone what happened (and send the fresh list: minimised/closed apps change)
            let result = m.type == "split"
                ? split((m.pids ?? []).map { pid_t($0) }, screen: m.screen ?? 0)
                : windowAction(m.cmd ?? "front", pid: pid_t(m.pids?.first ?? 0), screen: m.screen ?? 0)
            var r = DropMessage(type: "result")
            r.title = result
            drop.sendMessage(r, to: peer)
        case "agentOpen":
            if let c = m.cmd, ["claude", "codex"].contains(c) { showAgent(c) }
        case "apps":
            let apps = model.items.filter { $0.kind == .app && $0.pinned }.prefix(24)
                .map { DeckApp(name: $0.name, path: $0.id, icon: pngIcon($0.id)) }
            var r = DropMessage(type: "apps")
            r.apps = Array(apps)
            drop.sendMessage(r, to: peer)
        case "state":
            var values: [String: Double] = [:]
            for c in ["volume", "brightness", "keyboard", "appearance"] { values[c] = Sys.get(c) }
            let creative = frontCreative(), np = nowPlaying()
            DispatchQueue.global().async { [weak self] in
                let agents = agentStatuses()
                DispatchQueue.main.async {
                    var r = DropMessage(type: "state")
                    r.values = values
                    r.front = creative?.key; r.frontName = creative?.name
                    r.agents = agents
                    r.title = np?.title; r.artist = np?.artist; r.playing = np?.playing
                    r.artURL = np?.artURL; r.artData = np?.artData; r.position = np?.position; r.duration = np?.duration
                    self?.drop.sendMessage(r, to: peer)
                }
            }
        default: break
        }
    }

    /// With two people logged in (fast user switching), only the one on screen is visible to the iPhone;
    /// the other's SideDock goes quiet until they switch back.
    var sessionActive = true
    func applyDrop() { drop.setEnabled(sessionActive && prefs.bool(forKey: "dropEnabled")) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showPanel() // opening SideDock.app again shows the settings
        return false
    }

    func applicationWillTerminate(_ n: Notification) { SystemDock.restore() }

    @objc func togglePanel() { popover.isShown ? popover.performClose(nil) : showPanel() }

    func showPanel() {
        guard let b = status.button else { return }
        NSApp.activate()
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
    }

    /// Floating SideDrop shelf; first shown on the edge opposite the dock, then wherever you drag it.
    func showShelf() {
        if shelf == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 480),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isReleasedWhenClosed = false
            p.level = .floating
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.isMovableByWindowBackground = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: ShelfView(drop: drop) { [weak self] in
                MainActor.assumeIsolated { self?.shelf?.orderOut(nil) }
            })
            if let f = NSScreen.main?.visibleFrame {
                p.setFrameOrigin(NSPoint(x: side == "right" ? f.minX + 16 : f.maxX - 276, y: f.midY - 240))
            }
            shelf = p
        }
        shelf?.orderFrontRegardless()
    }

    // MARK: Panels

    func layout() {
        panels.forEach { $0.panel.close() }
        panels = []
        laidOutScreen = screenChoice
        guard replacing else { return position() }
        let chosen = NSScreen.screens.filter { screenChoice == "all" || $0.name == screenChoice }
        panels = (chosen.isEmpty ? [NSScreen.main!] : chosen).map { screen in
            let state = PanelState()
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isReleasedWhenClosed = false
            p.level = .init(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.contentView = NSHostingView(rootView: DockView(model: model, state: state))
            p.orderFrontRegardless()
            return (p, screen, state)
        }
        position()
    }

    /// Glow strip on the screen edge next to the iPhone. Click-through, except while a file is being dragged.
    /// The screen the iPhone stands next to (Settings → iPhone → Glow on screen; default the built-in one).
    var glowScreen: NSScreen? {
        let name = prefs.string(forKey: "glowScreen") ?? ""
        return NSScreen.screens.first(where: { $0.name == name })
            ?? NSScreen.screens.first(where: { $0.localizedName.localizedCaseInsensitiveContains("built-in") })
            ?? NSScreen.main
    }

    func layoutGlow() {
        guard let screen = glowScreen else { return }
        if glows.isEmpty {
            func panel(_ view: some View) -> NSPanel {
                let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                p.isReleasedWhenClosed = false
                p.level = .init(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
                p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
                p.isOpaque = false
                p.backgroundColor = .clear
                p.hasShadow = false
                p.ignoresMouseEvents = true
                p.contentView = NSHostingView(rootView: view)
                return p
            }
            // [left light, right light] never take the mouse; [left drop zone, right drop zone] do while dragging
            glows = [false, true].map { panel(GlowView(drop: drop, state: glowState, right: $0)) }
            dropZones = [false, true].map { panel(DropZoneView(drop: drop, state: glowState, right: $0)) }
            fxPanel = panel(FXView(fx: fx))
        }
        fxPanel?.setFrame(screen.frame, display: false)
        let f = screen.frame
        for (i, p) in glows.enumerated() {
            let w: CGFloat = 160
            p.setFrame(NSRect(x: i == 1 ? f.maxX - w : f.minX, y: f.minY, width: w, height: f.height), display: true)
            p.orderFrontRegardless()
        }
        for (i, p) in dropZones.enumerated() {
            let w: CGFloat = 110
            p.setFrame(NSRect(x: i == 1 ? f.maxX - w : f.minX, y: f.minY, width: w, height: f.height), display: true)
            p.orderFrontRegardless()
        }
    }

    /// A real (mouse-taking) window exactly over the big arrived photo, so it can be dragged.
    func showGrabPanel() {
        guard let g = fx.grab, let f = glowScreen?.frame else { return }
        let a = g.image.size.width / max(g.image.size.height, 1), w = f.width, h = f.height
        let big = a > 1 ? CGSize(width: min(w * 0.6, h * 0.6 * a), height: min(w * 0.6, h * 0.6 * a) / a)
                        : CGSize(width: h * 0.6 * a, height: h * 0.6) // same size the FX view grows it to
        if grabPanel == nil {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isReleasedWhenClosed = false
            p.level = .init(rawValue: Int(CGWindowLevelForKey(.overlayWindow)) + 1)
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.contentView = NSHostingView(rootView: GrabView(fx: fx))
            grabPanel = p
        }
        grabPanel?.alphaValue = 1
        grabPanel?.setFrame(NSRect(x: f.midX - big.width / 2, y: f.midY - big.height / 2, width: big.width, height: big.height), display: true)
        grabPanel?.orderFrontRegardless()
    }

    /// Hidden but kept until any drag it started has ended (removing a drag source mid-drag can cancel the drag).
    func hideGrabPanel() {
        grabPanel?.alphaValue = 0
        grabPanel?.ignoresMouseEvents = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.closeGrabWhenIdle() }
    }

    func closeGrabWhenIdle() {
        guard NSEvent.pressedMouseButtons & 1 == 0 else {
            return DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.closeGrabWhenIdle() }
        }
        grabPanel?.orderOut(nil)
        grabPanel?.ignoresMouseEvents = false
        fx.grab = nil
        fx.grabHover = false
    }

    // MARK: Mac → phone hand-off (mirror of the phone → Mac one)

    var lastLiveOut = Date.distantPast
    var dragAspect: CGFloat = 1

    /// A file drag started: send the phone a picture of it, so it can show the part that crosses over.
    func sendDragPreview(_ pb: NSPasteboard) {
        guard !drop.peers.isEmpty,
              let url = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first
        else { return }
        let r = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 600, height: 600), scale: 1, representationTypes: .all)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: r) { [weak self] rep, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let img = rep?.nsImage ?? Optional(NSWorkspace.shared.icon(forFile: url.path)),
                          let tiff = img.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff),
                          let jpg = bmp.representation(using: .jpeg, properties: [.compressionFactor: 0.65]) else { return }
                    self.dragAspect = img.size.width / max(img.size.height, 1)
                    self.drop.broadcast(DropMessage(type: "preview", preview: jpg))
                }
            }
        }
    }

    /// While dragging near the phone's edge, stream where the file is (~30/s) in phone points.
    func streamDragToPhone() {
        guard glowState.dragging, !drop.peers.isEmpty, let f = glowScreen?.frame else { return stopLive() }
        let m = NSEvent.mouseLocation, right = prefs.string(forKey: "phoneSide") != "left"
        let d = right ? f.maxX - m.x : m.x - f.minX // pointer distance from the phone's edge
        guard m.y >= f.minY, m.y <= f.maxY, d > -40, d < 320 else { return stopLive() }
        guard Date().timeIntervalSince(lastLiveOut) > 1.0 / 30 else { return }
        lastLiveOut = Date()
        let k = prefs.double(forKey: "phoneScale")
        let card = CGSize(width: 200 * dragAspect, height: 200) // Mac points, centred on the pointer
        var msg = DropMessage(type: "live", side: right ? "left" : "right", progress: max(0.05, min(1, 1 - d / 320)))
        msg.cx = -d / k                                                        // past the shared edge, phone points
        msg.cy = ((f.maxY - m.y) - f.height * prefs.double(forKey: "phoneY")) / k // from the phone's middle
        msg.cw = card.width / k
        msg.ch = card.height / k
        drop.lastLiveOut = msg
        drop.broadcast(msg, reliable: false)
    }

    func stopLive() {
        guard drop.lastLiveOut != nil else { return }
        drop.lastLiveOut = nil
        drop.broadcast(DropMessage(type: "live", progress: 0))
    }

    /// Settings: flash the glow so you can see which display it's on.
    func previewGlow() {
        layoutGlow()
        fx.wave(right: true)
        fx.wave(right: false)
    }

    /// Notices a file drag anywhere (the system drag pasteboard changes while the mouse is down)
    /// and makes the glow strip a drop target until the drag ends.
    func watchDrags() {
        let pb = NSPasteboard(name: .drag)
        if NSEvent.pressedMouseButtons & 1 == 0 {
            dragBaseline = pb.changeCount
            if glowState.dragging && !dragResetPending {
                dragResetPending = true // wait so the drop itself can finish first
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    guard let self else { return }
                    self.dragResetPending = false
                    guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
                    self.glowState.dragging = false
                    self.dropZones.forEach { $0.ignoresMouseEvents = true }
                    self.stopLive()
                }
            }
        } else if !glowState.dragging, !drop.peers.isEmpty || prefs.bool(forKey: "airdrop"), pb.changeCount != dragBaseline,
                  pb.types?.contains(.fileURL) == true {
            glowState.dragging = true
            dropZones.forEach { $0.ignoresMouseEvents = false }
            sendDragPreview(pb)
        }
    }

    /// Panel is a transparent strip along the edge; clicks on empty parts fall through to windows below.
    func position() {
        layoutGlow()
        let items = model.items.filter(isVisible)
        let gap = prefs.double(forKey: "gap")
        for (p, screen, st) in panels {
            let f = screen.visibleFrame
            let bottom = side == "bottom"
            let L = DockLayout(items: items, length: bottom ? f.width : f.height, size: prefs.double(forKey: "size"),
                               spacing: prefs.double(forKey: "spacing"), gap: gap,
                               columns: prefs.string(forKey: "overflow") != "shrink")
            st.reserve = gap + L.contentWidth + 4
            let w = st.reserve + L.s * max(prefs.double(forKey: "magnification"), 0.5) + 8 // room to magnify / bounce
            p.setFrame(bottom ? NSRect(x: f.minX, y: f.minY, width: f.width, height: w)
                              : NSRect(x: side == "left" ? f.minX : f.maxX - w, y: f.minY, width: w, height: f.height), display: true)
        }
    }

    // MARK: Pointer: magnification + auto-hide

    func tick() {
        watchDrags()
        streamDragToPhone()
        let m = NSEvent.mouseLocation
        let onControl = controls.tick(m)
        stash.tick(m, keepOpen: launcher != nil)
        let autohide = prefs.bool(forKey: "autohide"), side = side
        for (p, screen, st) in panels {
            let pf = p.frame
            let mouse: CGPoint? = pf.contains(m) ? CGPoint(x: m.x - pf.minX, y: pf.maxY - m.y) : nil
            if st.mouse != mouse { st.mouse = mouse }
            var hidden = false
            if autohide && onControl && st.hidden {
                hidden = true // pointer is on a corner dial / edge slider: don't slide the dock out under it
            } else if autohide {
                let f = screen.frame
                // d = pointer distance from the dock's edge; along = pointer is within the edge's span
                let (d, along, depth) = switch side {
                case "bottom": (m.y - f.minY, m.x >= f.minX && m.x <= f.maxX, pf.height)
                case "right": (f.maxX - m.x, m.y >= f.minY && m.y <= f.maxY, pf.width)
                default: (m.x - f.minX, m.y >= f.minY && m.y <= f.maxY, pf.width)
                }
                if !st.hidden {
                    hidden = !(along && d >= -0.5 && d <= depth) // shown: stay while the pointer is over the dock
                } else if along && d >= -0.5 && d <= (sharedEdge(screen, side) ? 12 : 3) {
                    // An edge shared with another screen can't stop the pointer (it slides onto the next screen),
                    // so there a 12 pt zone + a short pause reveals the dock; just passing through doesn't.
                    let since = st.edgeSince ?? Date()
                    st.edgeSince = since
                    hidden = sharedEdge(screen, side) && Date().timeIntervalSince(since) < 0.3
                } else {
                    st.edgeSince = nil
                    hidden = true
                }
                if !hidden { st.edgeSince = nil }
            }
            if st.hidden != hidden { st.hidden = hidden }
        }
    }

    /// Is there another screen right behind this screen's dock edge?
    func sharedEdge(_ screen: NSScreen, _ side: String) -> Bool {
        let f = screen.frame
        let strip = switch side {
        case "bottom": CGRect(x: f.minX, y: f.minY - 2, width: f.width, height: 2)
        case "right": CGRect(x: f.maxX, y: f.minY, width: 2, height: f.height)
        default: CGRect(x: f.minX - 2, y: f.minY, width: 2, height: f.height)
        }
        return NSScreen.screens.contains { $0 != screen && $0.frame.intersects(strip) }
    }

    // MARK: Keep windows clear (Accessibility)

    func keepWindowsClear() {
        guard replacing, prefs.bool(forKey: "reserveSpace"), !prefs.bool(forKey: "autohide"), AXIsProcessTrusted(), !axBusy else { return }
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let side = side
        // allowed area per dock screen, in AX coords (top-left origin of the primary screen)
        let zones: [(screen: CGRect, allowed: CGRect)] = panels.map { _, s, st in
            let f = s.visibleFrame, w = st.reserve
            let r = CGRect(x: f.minX, y: primaryH - f.maxY, width: f.width, height: f.height)
            let allowed = switch side {
            case "bottom": CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height - w)
            case "left": CGRect(x: r.minX + w, y: r.minY, width: r.width - w, height: r.height)
            default: CGRect(x: r.minX, y: r.minY, width: r.width - w, height: r.height)
            }
            return (r, allowed)
        }
        let pids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }.map(\.processIdentifier)
        axBusy = true
        axQueue.async { [weak self] in
            for pid in pids { fixWindows(pid: pid, zones: zones, bottom: side == "bottom") }
            DispatchQueue.main.async { self?.axBusy = false }
        }
    }
}

// ponytail: polls every 1 s and nudges windows; an AXObserver per app would react instantly but is far more code
nonisolated func fixWindows(pid: pid_t, zones: [(screen: CGRect, allowed: CGRect)], bottom: Bool) {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.2) // a hung app can't stall us
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v) == .success,
          let wins = v as? [AXUIElement] else { return }
    for win in wins {
        var fs: CFTypeRef?
        if AXUIElementCopyAttributeValue(win, "AXFullScreen" as CFString, &fs) == .success, (fs as? Bool) == true { continue }
        guard var pos = axValue(win, kAXPositionAttribute, .cgPoint, CGPoint.zero),
              var size = axValue(win, kAXSizeAttribute, .cgSize, CGSize.zero) else { continue }
        let r = CGRect(origin: pos, size: size)
        guard let z = zones.first(where: { $0.screen.contains(CGPoint(x: r.midX, y: r.midY)) }),
              r.minX < z.allowed.minX - 1 || r.maxX > z.allowed.maxX + 1 || (bottom && r.maxY > z.allowed.maxY + 1)
        else { continue }
        size.width = min(r.width, z.allowed.width)
        pos.x = min(max(r.minX, z.allowed.minX), z.allowed.maxX - size.width)
        if bottom { // AX y grows downward: keep the window's bottom above the dock
            size.height = min(r.height, z.allowed.height)
            pos.y = max(min(r.minY, z.allowed.maxY - size.height), z.allowed.minY)
        }
        axSet(win, kAXSizeAttribute, .cgSize, size)
        axSet(win, kAXPositionAttribute, .cgPoint, pos)
    }
}

nonisolated func axValue<T>(_ e: AXUIElement, _ attr: String, _ type: AXValueType, _ empty: T) -> T? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success, let v else { return nil }
    var out = empty
    return AXValueGetValue(v as! AXValue, type, &out) ? out : nil
}

nonisolated func axSet<T>(_ e: AXUIElement, _ attr: String, _ type: AXValueType, _ value: T) {
    var val = value
    if let ax = AXValueCreate(type, &val) { AXUIElementSetAttributeValue(e, attr as CFString, ax) }
}

// MARK: - Main

// The app used to be "local.sidedock" (dev builds); carry its settings over to com.melquiantonio.sidedock once.
if Bundle.main.bundleIdentifier != "local.sidedock", prefs.object(forKey: "pinned") == nil,
   let old = prefs.persistentDomain(forName: "local.sidedock") {
    for (k, v) in old { prefs.set(v, forKey: k) }
}
prefs.register(defaults: defaultPrefs)
importSystemDock()
let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
// restore the macOS Dock on Ctrl-C / kill too
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { SystemDock.restore(); exit(0) }
    src.resume()
    signalSources.append(src)
}
app.run()
