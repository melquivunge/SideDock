// Mac side of the iPhone Deck's extra widgets: Claude Code / Codex status, and Creative Pro (keys + colours
// for Photoshop, Illustrator, After Effects, Premiere Pro, Blender). Wired up in AppDelegate.handleDeck.
import AppKit

// MARK: - Claude Code & Codex

/// Reads the newest session transcript of each agent: is it working, waiting for you, or idle?
/// ponytail: heuristic from transcript files (no hooks to install); "working" = written to in the last 15 s
func agentStatuses() -> [AgentStatus] {
    let home = NSHomeDirectory()
    return [status(name: "Claude Code", file: newest(in: home + "/.claude/projects", depth: 2), claude: true),
            status(name: "Codex", file: newest(in: home + "/.codex/sessions", depth: 4), claude: false)]
}

func newest(in dir: String, depth: Int) -> URL? {
    guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: [.contentModificationDateKey],
                                                 options: [.skipsHiddenFiles]) else { return nil }
    var best: (url: URL, date: Date)?
    for case let u as URL in e {
        if e.level > depth { e.skipDescendants(); continue }
        guard u.pathExtension == "jsonl",
              let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
        if best == nil || d > best!.date { best = (u, d) }
    }
    return best?.url
}

func status(name: String, file: URL?, claude: Bool) -> AgentStatus {
    var s = AgentStatus(name: name, project: "", state: "none", text: "", age: 0)
    guard let file, let h = try? FileHandle(forReadingFrom: file),
          let mod = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return s }
    defer { try? h.close() }
    s.age = Date().timeIntervalSince(mod)
    guard s.age < 6 * 3600 else { return s } // nothing in the last 6 hours: no session
    let size = (try? h.seekToEnd()) ?? 0
    try? h.seek(toOffset: size > 200_000 ? size - 200_000 : 0) // the end is enough
    let lines = String(decoding: h.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").reversed()
    s.state = s.age < 15 ? "working" : "idle"
    var decided = s.state == "working"
    for line in lines {
        guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
        if s.project.isEmpty, let cwd = (d["cwd"] ?? (d["payload"] as? [String: Any])?["cwd"]) as? String {
            s.project = (cwd as NSString).lastPathComponent
        }
        if claude, d["type"] as? String == "assistant", let m = d["message"] as? [String: Any] {
            let parts = m["content"] as? [[String: Any]] ?? []
            if s.text.isEmpty, let t = parts.compactMap({ $0["text"] as? String }).last { s.text = t }
            if !decided { s.state = m["stop_reason"] as? String == "end_turn" ? "waiting" : "idle"; decided = true }
        } else if claude, d["type"] as? String == "user", !decided {
            decided = true // you spoke last and nothing is being written: idle
        } else if !claude, let p = d["payload"] as? [String: Any], let t = p["type"] as? String {
            if !decided, t == "task_complete" { s.state = "waiting"; decided = true }
            if s.text.isEmpty, t == "agent_message" {
                s.text = (p["message"] as? String)
                    ?? (p["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: " ") ?? ""
            }
        }
        if decided && !s.text.isEmpty && !s.project.isEmpty { break }
    }
    s.text = String(s.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
    return s
}

/// Bring the terminal (or editor) that runs `claude` / `codex` to the front.
func showAgent(_ command: String) {
    // pid → ppid for every process, then walk up from the agent to the first real app
    var parent: [pid_t: pid_t] = [:], agent: pid_t?
    for row in sh("ps", "-Ao", "pid=,ppid=,comm=").split(separator: "\n") {
        let f = row.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard f.count == 3, let pid = pid_t(f[0]), let pp = pid_t(f[1]) else { continue }
        parent[pid] = pp
        if (String(f[2]) as NSString).lastPathComponent == command { agent = pid }
    }
    var p = agent
    while let cur = p, cur > 1 {
        if let app = NSRunningApplication(processIdentifier: cur), app.activationPolicy == .regular {
            app.activate()
            return
        }
        p = parent[cur]
    }
}

// MARK: - Creative Pro

/// Supported creative apps: bundle id prefix → short key the phone uses to pick its tools.
let creativeApps = ["com.adobe.Photoshop": "photoshop", "com.adobe.illustrator": "illustrator",
                    "com.adobe.AfterEffects": "aftereffects", "com.adobe.PremierePro": "premiere",
                    "org.blenderfoundation.blender": "blender"]

/// The creative app in front (or last in front, if SideDock itself has focus), if any.
func frontCreative() -> (key: String, name: String, bundle: String)? {
    let front = NSWorkspace.shared.frontmostApplication
    let id = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? prefs.string(forKey: "lastAppID") : front?.bundleIdentifier
    guard let id, let key = creativeApps.first(where: { id.hasPrefix($0.key) })?.value else { return nil }
    let name = NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.localizedName ?? key
    return (key, name, id)
}

let keyCodes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
    "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
    "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36, "l": 37, "j": 38, "k": 40,
    ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "delete": 51, "escape": 53,
    "f12": 111, "home": 115, "pageup": 116, "end": 119, "pagedown": 121, "left": 123, "right": 124, "down": 125, "up": 126,
]

/// Types shortcuts into the front app: "cmd+shift+z", or several separated by spaces ("4 5" = opacity 45% in Photoshop).
/// Needs Accessibility. Only ever sent while a supported creative app is in front.
func pressKeys(_ combos: String) {
    guard frontCreative() != nil, AXIsProcessTrusted() else { return }
    for combo in combos.split(separator: " ") {
        var flags: CGEventFlags = []
        var key: CGKeyCode?
        for part in combo.lowercased().split(separator: "+") {
            switch part {
            case "cmd": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "opt": flags.insert(.maskAlternate)
            case "ctrl": flags.insert(.maskControl)
            default: key = keyCodes[String(part)]
            }
        }
        guard let key else { continue }
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }
}

/// Sets the foreground colour (Photoshop) or the fill of the selection (Illustrator).
func setCreativeColor(_ hex: String) {
    guard hex.count == 6, hex.allSatisfy(\.isHexDigit), let c = frontCreative() else { return } // validated: goes into a script
    let v = Int(hex, radix: 16)!, r = (v >> 16) & 255, g = (v >> 8) & 255, b = v & 255
    let js = switch c.key {
    case "photoshop": "var c=new SolidColor();c.rgb.hexValue='\(hex)';app.foregroundColor=c;"
    case "illustrator": "var c=new RGBColor();c.red=\(r);c.green=\(g);c.blue=\(b);var d=app.activeDocument;d.defaultFillColor=c;"
        + "for(var i=0;i<d.selection.length;i++){try{d.selection[i].fillColor=c}catch(e){}}"
    default: ""
    }
    guard !js.isEmpty else { return }
    DispatchQueue.global().async {
        sh("osascript", "-e", "tell application id \"\(c.bundle)\" to do javascript \"\(js)\"")
    }
}

// MARK: - Windows: split apps side by side on a screen, from the phone

/// Running apps that have a normal window (on any Space, minimised included), for the phone's picker.
func windowApps() -> [DeckApp] {
    let info = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let pids = Set(info.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }.compactMap { $0[kCGWindowOwnerPID as String] as? pid_t })
    return NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular && pids.contains($0.processIdentifier) && $0 != .current }
        .map { DeckApp(name: $0.localizedName ?? "App", path: "\($0.processIdentifier)", icon: pngIcon($0.bundleURL?.path ?? "")) }
}

/// The app's front window (focused, else its first), or nil.
func frontWindow(_ pid: pid_t) -> AXUIElement? {
    let ax = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(ax, 0.5)
    var v: CFTypeRef?
    if AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &v) == .success, let v,
       CFGetTypeID(v) == AXUIElementGetTypeID() { return (v as! AXUIElement) }
    if AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &v) == .success { return (v as? [AXUIElement])?.first }
    return nil
}

/// Every window of the app (for minimising all of them).
func allWindows(_ pid: pid_t) -> [AXUIElement] {
    let ax = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(ax, 0.5)
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &v) == .success else { return [] }
    return v as? [AXUIElement] ?? []
}

func needsAccessibility() -> String? {
    guard !AXIsProcessTrusted() else { return nil }
    AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    return "Allow SideDock in System Settings → Privacy & Security → Accessibility on the Mac"
}

/// Moves/resizes a window to `r` (AX coordinates). Handles the usual reasons apps ignore it:
/// full screen, and "AXEnhancedUserInterface" (Chrome, Electron…) which makes them skip size changes.
func place(_ win: AXUIElement, pid: pid_t, _ r: CGRect) {
    let app = AXUIElementCreateApplication(pid)
    var e: CFTypeRef?
    let enhanced = AXUIElementCopyAttributeValue(app, "AXEnhancedUserInterface" as CFString, &e) == .success && (e as? Bool) == true
    if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
    defer { if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) } }
    var fs: CFTypeRef?
    if AXUIElementCopyAttributeValue(win, "AXFullScreen" as CFString, &fs) == .success, (fs as? Bool) == true {
        AXUIElementSetAttributeValue(win, "AXFullScreen" as CFString, kCFBooleanFalse)
        usleep(700_000) // leaving full screen animates
    }
    AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    axSet(win, kAXPositionAttribute, .cgPoint, r.origin) // move first (the new screen may allow a bigger size)
    axSet(win, kAXSizeAttribute, .cgSize, r.size)
    axSet(win, kAXPositionAttribute, .cgPoint, r.origin)
    AXUIElementPerformAction(win, kAXRaiseAction as CFString)
}

/// Close enough to where we wanted it? (apps may round sizes or have a minimum width)
func landed(_ win: AXUIElement, _ r: CGRect) -> Bool {
    guard let p = axValue(win, kAXPositionAttribute, .cgPoint, CGPoint.zero) else { return false }
    return abs(p.x - r.minX) < 30 && abs(p.y - r.minY) < 40
}

/// Puts each app's front window on `screen`, side by side in equal parts (2 apps = 50/50, 1 app = whole screen).
/// Returns what happened, for the phone.
func split(_ pids: [pid_t], screen i: Int) -> String {
    if let msg = needsAccessibility() { return msg }
    guard NSScreen.screens.indices.contains(i), (1...4).contains(pids.count) else { return "Pick an app first" }
    let vf = NSScreen.screens[i].visibleFrame, primaryH = NSScreen.screens.first?.frame.height ?? 0
    let w = (vf.width / CGFloat(pids.count)).rounded(.down)
    // unhide everything first and give the apps a moment to bring their windows back
    let apps = pids.compactMap { NSRunningApplication(processIdentifier: $0) }.filter { $0.activationPolicy == .regular }
    if apps.contains(where: \.isHidden) { apps.forEach { $0.unhide() }; usleep(300_000) }
    var failed: [String] = []
    var targets: [(AXUIElement, pid_t, CGRect)] = []
    for (k, pid) in pids.enumerated() {
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "App"
        guard apps.contains(where: { $0.processIdentifier == pid }), let win = frontWindow(pid) else { failed.append(name); continue }
        // AX coordinates: top-left of the main screen, y down
        let r = CGRect(x: vf.minX + w * CGFloat(k), y: primaryH - vf.maxY, width: w, height: vf.height)
        place(win, pid: pid, r)
        targets.append((win, pid, r))
    }
    usleep(250_000)
    for (win, pid, r) in targets where !landed(win, r) { // some apps need a second try (animations, enhanced UI)
        place(win, pid: pid, r)
        usleep(150_000)
        if !landed(win, r) { failed.append(NSRunningApplication(processIdentifier: pid)?.localizedName ?? "App") }
    }
    for pid in pids.reversed() { NSRunningApplication(processIdentifier: pid)?.activate() } // all to the front, first on top
    if !failed.isEmpty { return "Couldn’t move: \(failed.joined(separator: ", "))" }
    return pids.count == 1 ? "Maximized" : "Split \(pids.count) windows"
}

/// front: bring to the front · minimize: minimise all its windows · maximize: fill `screen` (100 %)
func windowAction(_ cmd: String, pid: pid_t, screen: Int) -> String {
    guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular else { return "That app is no longer open" }
    if cmd == "maximize" { return split([pid], screen: screen) }
    if let msg = needsAccessibility() { return msg }
    switch cmd {
    case "minimize":
        let wins = allWindows(pid).filter { w in // only real windows (not palettes/sheets), not already minimised
            var role: CFTypeRef?, min: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXSubroleAttribute as CFString, &role)
            AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &min)
            return (role as? String) == kAXStandardWindowSubrole && (min as? Bool) != true
        }
        // nothing "standard" found (some apps label their windows differently): use the app's front window
        let targets = wins.isEmpty ? frontWindow(pid).map { [$0] } ?? [] : wins
        guard !targets.isEmpty else { app.hide(); return "Hid \(app.localizedName ?? "App")" }
        let ax = AXUIElementCreateApplication(pid)
        var e: CFTypeRef?
        let enhanced = AXUIElementCopyAttributeValue(ax, "AXEnhancedUserInterface" as CFString, &e) == .success && (e as? Bool) == true
        if enhanced { AXUIElementSetAttributeValue(ax, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        defer { if enhanced { AXUIElementSetAttributeValue(ax, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) } }
        var done = 0
        for w in targets {
            if AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success { done += 1; continue }
            // some apps refuse the attribute: press the window's yellow button instead
            var b: CFTypeRef?
            if AXUIElementCopyAttributeValue(w, kAXMinimizeButtonAttribute as CFString, &b) == .success, let b,
               CFGetTypeID(b) == AXUIElementGetTypeID(), AXUIElementPerformAction(b as! AXUIElement, kAXPressAction as CFString) == .success {
                done += 1
            }
        }
        if done == 0 { app.hide(); return "Hid \(app.localizedName ?? "App") (it can’t be minimized)" }
        return "Minimized \(app.localizedName ?? "App")"
    default: // front
        app.unhide()
        if let w = frontWindow(pid) {
            AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        }
        app.activate()
        return "\(app.localizedName ?? "App") is in front"
    }
}
