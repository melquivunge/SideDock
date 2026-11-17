// Hidden Dock: in "Beside macOS Dock" mode the real Dock stays, and a small extra dock slides out of its end
// when the pointer reaches it. The Dock's exact frame is read with Accessibility (= calibration).
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Apple's Dock (its row of icons), in Cocoa screen coordinates. Needs Accessibility.
/// ponytail: assumes the macOS Dock is visible (not auto-hidden); with auto-hide its frame is off-screen
func systemDockFrame() -> CGRect? {
    guard AXIsProcessTrusted(),
          let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
    let app = AXUIElementCreateApplication(dock.processIdentifier)
    AXUIElementSetMessagingTimeout(app, 0.2)
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &v) == .success,
          let kids = v as? [AXUIElement] else { return nil }
    for k in kids {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(k, kAXRoleAttribute as CFString, &role)
        guard role as? String == "AXList",
              let pos = axValue(k, kAXPositionAttribute, .cgPoint, CGPoint.zero),
              let size = axValue(k, kAXSizeAttribute, .cgSize, CGSize.zero), size.width > 0 else { continue }
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: pos.x, y: primaryH - pos.y - size.height, width: size.width, height: size.height)
    }
    return nil
}

final class StashState: ObservableObject {
    @Published var shown = false
    @Published var items: [Item] = []
    @Published var vertical = false // macOS Dock on the left/right
    @Published var thickness: CGFloat = 60
}

func loadStash() -> [Item] {
    let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path })
    return (prefs.stringArray(forKey: "stashApps") ?? []).filter { FileManager.default.fileExists(atPath: $0) }.map {
        Item(url: URL(fileURLWithPath: $0), kind: .app, pinned: true, running: running.contains($0), icon: flatIcon($0))
    } + [Item(url: launcherURL, kind: .launcher, icon: launcherIcon)]
}

struct StashView: View {
    @ObservedObject var state: StashState
    var icon: CGFloat { state.thickness * 0.78 }

    var body: some View {
        let stack = state.vertical ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
        stack {
            ForEach(state.items) { item in
                ZStack(alignment: state.vertical ? .trailing : .bottom) {
                    Image(nsImage: item.icon).resizable().interpolation(.high).frame(width: icon, height: icon)
                    if item.running {
                        Circle().fill(.primary.opacity(0.8)).frame(width: 4, height: 4).offset(x: 0, y: state.vertical ? 0 : 5)
                    }
                }
                .help(item.kind == .launcher ? "All apps" : item.name)
                .contentShape(Rectangle())
                .onTapGesture { click(item) }
                .contextMenu {
                    if item.kind == .app {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                        Button("Remove from Hidden Dock") { remove(item.id) }
                    }
                    Button("Recalibrate") { (NSApp.delegate as? AppDelegate)?.stash.recalibrate() }
                    Button("Dock Settings…") { (NSApp.delegate as? AppDelegate)?.showPanel() }
                }
            }
        }
        .padding((state.thickness - icon) / 2 + 2)
        .background(Color.clear.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous)))
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: nil) { add($0) }
        .opacity(state.shown ? 1 : 0)
        .scaleEffect(state.shown ? 1 : 0.6, anchor: state.vertical ? .top : .leading)
        .offset(x: state.shown || state.vertical ? 0 : -30, y: state.shown || !state.vertical ? 0 : 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: state.shown)
    }

    /// Apps dragged in from Finder or the App Launcher.
    func add(_ providers: [NSItemProvider]) -> Bool {
        for p in providers {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.pathExtension == "app" else { return }
                DispatchQueue.main.async {
                    var list = prefs.stringArray(forKey: "stashApps") ?? []
                    if !list.contains(url.path) { list.append(url.path) }
                    prefs.set(list, forKey: "stashApps")
                    state.items = loadStash()
                }
            }
        }
        return true
    }

    func remove(_ path: String) {
        prefs.set((prefs.stringArray(forKey: "stashApps") ?? []).filter { $0 != path }, forKey: "stashApps")
        state.items = loadStash()
    }
}

@MainActor
final class Stash {
    let state = StashState()
    lazy var panel: NSPanel = {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isReleasedWhenClosed = false
        p.level = .init(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.contentView = NSHostingView(rootView: StashView(state: state))
        return p
    }()
    var dock: CGRect?
    var active = false

    func setActive(_ on: Bool) {
        active = on
        if on {
            if !AXIsProcessTrusted() {
                AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
            }
            reload()
            calibrate()
            panel.orderFrontRegardless()
        } else {
            state.shown = false
            panel.orderOut(nil)
        }
    }

    func reload() { if active { state.items = loadStash(); place() } }

    func recalibrate() { dock = nil; calibrate() }

    /// Re-read where the macOS Dock is (it moves when apps are added/removed or the Dock is resized).
    func calibrate() {
        guard active, let f = systemDockFrame() else { return }
        if f != dock { dock = f; place() }
    }

    /// The stash sits right after the Dock's end: to its right, or below it when the Dock is on a side.
    func place() {
        guard let d = dock else { return }
        state.vertical = d.height > d.width
        state.thickness = state.vertical ? d.width : d.height
        let n = CGFloat(state.items.count), icon = state.thickness * 0.78
        let len = n * icon + (n - 1) * 6 + 2 * ((state.thickness - icon) / 2 + 2)
        panel.setFrame(state.vertical ? NSRect(x: d.minX, y: d.minY - 8 - len, width: d.width, height: len)
                                      : NSRect(x: d.maxX + 8, y: d.minY, width: len, height: d.height), display: true)
    }

    /// Slides out when the pointer reaches the end of the macOS Dock; hides when the pointer leaves.
    func tick(_ m: NSPoint, keepOpen: Bool) {
        guard active, let d = dock else { return }
        let trigger = state.vertical
            ? CGRect(x: d.minX, y: d.minY - 30, width: d.width, height: 54)
            : CGRect(x: d.maxX - 24, y: d.minY, width: 54, height: d.height)
        let over = panel.frame.insetBy(dx: -20, dy: -20).contains(m)
        let show = trigger.contains(m) || (state.shown && (over || keepOpen))
        guard show != state.shown else { return }
        state.shown = show
        panel.ignoresMouseEvents = !show
    }
}
