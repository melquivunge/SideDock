// Dock contents: pinned apps, running apps, folders, Trash. Order + pins stored in our own prefs.
import AppKit
import UniformTypeIdentifiers

let prefs = UserDefaults.standard
let trashURL = URL(fileURLWithPath: NSHomeDirectory() + "/.Trash")

let defaultPrefs: [String: Any] = [
    "size": 48.0, "magnification": 0.5, "spacing": 6.0, "side": "left", "screen": "all",
    "autohide": false, "reserveSpace": false, "dots": true, "showRunning": true,
    "showFolders": true, "showTrash": true, "style": "liquid", "tint": "1E1E1E",
    "opacity": 1.0, "radius": 18.0, "gap": 6.0, "overflow": "columns", "dropEnabled": true, "phoneSide": "right", "dropFolder": "desktop", "shelfAuto": false, "airdrop": true, "phoneScale": 0.8, "phoneY": 0.62,
    "dockEnabled": true, "showLauncher": true, "dockMode": "replace",
    "cornerTL": "brightness", "cornerTR": "volume", "cornerBL": "none", "cornerBR": "none",
    "edgeLeft": "none", "edgeRight": "volume",
]

extension NSScreen {
    /// Some displays report an empty name; fall back to "Display N" so they can be told apart and chosen.
    var name: String {
        localizedName.isEmpty ? "Display \((NSScreen.screens.firstIndex(of: self) ?? 0) + 1)" : localizedName
    }
}

func isVisible(_ i: Item) -> Bool {
    switch i.kind {
    case .app: i.pinned || prefs.bool(forKey: "showRunning")
    case .folder: prefs.bool(forKey: "showFolders")
    case .trash: prefs.bool(forKey: "showTrash")
    case .launcher: prefs.bool(forKey: "showLauncher")
    }
}

enum Kind { case app, folder, trash, launcher }

let launcherURL = URL(fileURLWithPath: "/sidedock-launcher")
let launcherIcon: NSImage = {
    for p in ["/System/Applications/Apps.app", "/System/Applications/Launchpad.app"] where FileManager.default.fileExists(atPath: p) {
        return flatIcon(p)
    }
    return NSImage(systemSymbolName: "square.grid.3x3.fill", accessibilityDescription: "Apps")?
        .withSymbolConfiguration(.init(pointSize: 96, weight: .regular)) ?? NSImage()
}()

struct Item: Identifiable {
    let url: URL
    let kind: Kind
    var pinned = false
    var running = false
    let icon: NSImage
    var id: String { url.path }
    var name: String { url.deletingPathExtension().lastPathComponent }
    /// pinned apps, other running apps, folders+trash: a divider goes between groups
    var group: Int { kind == .launcher ? 0 : kind != .app ? 2 : pinned ? 0 : 1 }
}

/// First launch: copy the apps and folders from the macOS Dock.
func importSystemDock(force: Bool = false) {
    guard force || prefs.array(forKey: "pinned") == nil else { return }
    let dock = UserDefaults(suiteName: "com.apple.dock")
    func paths(_ key: String) -> [String] {
        (dock?.array(forKey: key) as? [[String: Any]] ?? []).compactMap {
            guard let tile = $0["tile-data"] as? [String: Any],
                  let file = tile["file-data"] as? [String: Any],
                  let s = file["_CFURLString"] as? String else { return nil }
            return (s.hasPrefix("file://") ? URL(string: s) : URL(fileURLWithPath: s))?.path
        }
    }
    prefs.set(paths("persistent-apps"), forKey: "pinned")
    var folders = paths("persistent-others").filter { isDir($0) }
    let downloads = NSHomeDirectory() + "/Downloads"
    if !folders.contains(downloads) { folders.append(downloads) }
    prefs.set(folders, forKey: "folders")
}

func isDir(_ path: String) -> Bool {
    var d: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &d) && d.boolValue
}

func runningApp(_ path: String) -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == path }
}

func loadItems() -> [Item] {
    let ws = NSWorkspace.shared
    let running = ws.runningApplications.filter { $0.activationPolicy == .regular }.compactMap { $0.bundleURL?.path }
    let runSet = Set(running)
    let pinned = (prefs.stringArray(forKey: "pinned") ?? []).filter { FileManager.default.fileExists(atPath: $0) }
    let pinSet = Set(pinned)
    var items = pinned.map {
        Item(url: URL(fileURLWithPath: $0), kind: .app, pinned: true, running: runSet.contains($0), icon: flatIcon($0))
    }
    items += running.filter { !pinSet.contains($0) }.map {
        Item(url: URL(fileURLWithPath: $0), kind: .app, running: true, icon: flatIcon($0))
    }
    items += (prefs.stringArray(forKey: "folders") ?? []).filter(isDir).map {
        Item(url: URL(fileURLWithPath: $0), kind: .folder, icon: flatIcon($0))
    }
    // ponytail: without Full Disk Access ~/.Trash can't be listed, so the icon may always show "empty"
    let full = (try? FileManager.default.contentsOfDirectory(atPath: trashURL.path))?.isEmpty == false
    let trashIcon = NSImage(named: full ? NSImage.trashFullName : NSImage.trashEmptyName) ?? NSImage()
    // like the macOS Dock: Apps sits among the apps, right after Finder
    let finder = items.firstIndex { $0.url.lastPathComponent == "Finder.app" && $0.pinned }
    items.insert(Item(url: launcherURL, kind: .launcher, icon: launcherIcon), at: finder.map { $0 + 1 } ?? 0)
    items.append(Item(url: trashURL, kind: .trash, icon: trashIcon))
    return items
}

final class Model: ObservableObject {
    @Published var items: [Item] = loadItems()
    @Published var launching: Set<String> = [] // apps bouncing until they're running
    func reload() {
        items = loadItems()
        let running = Set(items.filter(\.running).map(\.id))
        if !launching.isDisjoint(with: running) { launching.subtract(running) }
    }

    /// Like the macOS Dock: a clicked app that isn't open yet bounces until it is (at most 5 s).
    func bounce(_ item: Item) {
        guard item.kind == .app, !item.running else { return }
        launching.insert(item.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.launching.remove(item.id) }
    }

    func togglePin(_ item: Item) {
        var p = prefs.stringArray(forKey: "pinned") ?? []
        if item.pinned { p.removeAll { $0 == item.id } } else { p.append(item.id) }
        prefs.set(p, forKey: "pinned")
        reload()
    }

    func remove(_ path: String) {
        for key in ["pinned", "folders"] {
            prefs.set((prefs.stringArray(forKey: key) ?? []).filter { $0 != path }, forKey: key)
        }
        reload()
    }

    /// Internal drags carry "sidedock:<path>" text (so dragging out to Finder never moves an app);
    /// Finder drags carry file URLs.
    func handleDrop(_ providers: [NSItemProvider], onto target: Item?) -> Bool {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { self.drop(url.path, fromDock: false, onto: target) }
                }
            } else {
                _ = p.loadObject(ofClass: String.self) { s, _ in
                    guard let s, s.hasPrefix("sidedock:") else { return }
                    DispatchQueue.main.async { self.drop(String(s.dropFirst(9)), fromDock: true, onto: target) }
                }
            }
        }
        return true
    }

    func drop(_ path: String, fromDock: Bool, onto target: Item?) {
        guard path != trashURL.path, path != launcherURL.path else { return } // these two icons aren't movable
        if target?.kind == .trash {
            // dock icon onto Trash = remove from dock; a Finder file onto Trash = move it to the Trash
            if fromDock { remove(path) } else { NSWorkspace.shared.recycle([URL(fileURLWithPath: path)]) { _, _ in } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.reload() }
            return
        }
        let key: String
        if path.hasSuffix(".app") { key = "pinned" } else if isDir(path) { key = "folders" } else { return }
        var list = prefs.stringArray(forKey: key) ?? []
        list.removeAll { $0 == path }
        if let t = target, let i = list.firstIndex(of: t.id) { list.insert(path, at: i) } else { list.append(path) }
        prefs.set(list, forKey: key)
        reload()
    }
}

// MARK: - Actions

func click(_ item: Item) {
    switch item.kind {
    case .app: NSWorkspace.shared.openApplication(at: item.url, configuration: .init()) // activates or launches
    case .folder: showFolderMenu(item.url)
    case .trash: NSWorkspace.shared.open(trashURL)
    case .launcher:
        // the real macOS "Apps" (search, categories, recents), like the macOS Dock; our own grid only on older systems
        if let apps = ["/System/Applications/Apps.app", "/System/Applications/Launchpad.app"]
            .first(where: { FileManager.default.fileExists(atPath: $0) }) {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: apps), configuration: .init())
        } else {
            MainActor.assumeIsolated { (NSApp.delegate as? AppDelegate)?.toggleLauncher() }
        }
    }
}

/// Folder stack as a menu, newest first (like Downloads in the real Dock).
func showFolderMenu(_ url: URL) {
    let files = (try? FileManager.default.contentsOfDirectory(
        at: url, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)) ?? []
    func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast }
    let menu = NSMenu()
    for f in files.sorted(by: { date($0) > date($1) }).prefix(40) { // ponytail: 40 newest, add paging if needed
        let i = ClosureItem(title: f.lastPathComponent) { NSWorkspace.shared.open(f) }
        let img = NSWorkspace.shared.icon(forFile: f.path); img.size = NSSize(width: 16, height: 16)
        i.image = img
        menu.addItem(i)
    }
    if files.isEmpty { menu.addItem(withTitle: "Empty", action: nil, keyEquivalent: "") }
    menu.addItem(.separator())
    menu.addItem(ClosureItem(title: "Open in Finder") { NSWorkspace.shared.open(url) })
    menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
}

func emptyTrash() {
    let a = NSAlert()
    a.messageText = "Empty the Trash?"
    a.informativeText = "You can't undo this action."
    a.addButton(withTitle: "Empty Trash")
    a.addButton(withTitle: "Cancel")
    NSApp.activate()
    guard a.runModal() == .alertFirstButtonReturn else { return }
    sh("osascript", "-e", "tell application \"Finder\" to empty trash")
}

@discardableResult
func sh(_ args: String...) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    // read before waiting: a big output (e.g. ps) fills the pipe and the tool would wait for us forever
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

final class ClosureItem: NSMenuItem {
    let run: () -> Void
    init(title: String, action: @escaping () -> Void) {
        run = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc func fire() { run() }
}

/// Some app icons (e.g. Electron .icns with ARGB/"icp4" small sizes) render as rainbow noise in SwiftUI.
/// Drawing once into a single 256px bitmap avoids that, and is cheaper to redraw while magnifying.
func flatIcon(_ path: String) -> NSImage {
    let src = NSWorkspace.shared.icon(forFile: path)
    let px = 256
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return src }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    src.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    let img = NSImage(size: NSSize(width: px / 2, height: px / 2)) // 128pt @2x
    img.addRepresentation(rep)
    return img
}
