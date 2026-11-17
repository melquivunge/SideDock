// Corner Dials, Edge Sliders, App Launcher, App Profiles, and the system controls they drive.
import AppKit
import SwiftUI
import CoreAudio
import AudioToolbox
import IOKit

// MARK: - System controls

/// volume | brightness | keyboard | output | appearance | none
enum Sys {
    static let names = ["volume": "Volume", "brightness": "Brightness", "keyboard": "Keyboard light",
                        "output": "Audio output", "appearance": "Appearance", "none": "Off"]
    static let icons = ["volume": "speaker.wave.2.fill", "brightness": "sun.max.fill", "keyboard": "light.max",
                        "output": "hifispeaker.2.fill", "appearance": "circle.lefthalf.filled", "none": "circle.dashed"]

    static func get(_ c: String) -> Double {
        switch c {
        case "volume": volume
        case "brightness": brightness
        case "keyboard": keyboard
        case "output":
            outputs.count > 1 ? Double(outputs.firstIndex { $0.id == defaultOutput } ?? 0) / Double(outputs.count - 1) : 0
        case "appearance": dark ? 1 : 0
        default: 0
        }
    }

    static func set(_ c: String, _ v: Double) {
        let v = min(1, max(0, v))
        switch c {
        case "volume": volume = v
        case "brightness": brightness = v
        case "keyboard": keyboard = v
        case "output":
            let o = outputs
            guard o.count > 1 else { return }
            let id = o[Int((v * Double(o.count - 1)).rounded())].id
            if id != defaultOutput { defaultOutput = id }
        case "appearance": if (v >= 0.5) != dark { setDark(v >= 0.5) }
        default: break
        }
    }

    /// Text in the middle of a dial while turning it.
    static func label(_ c: String, _ v: Double) -> String {
        switch c {
        case "output": outputs.first { $0.id == defaultOutput }?.name ?? "—"
        case "appearance": v >= 0.5 ? "Dark" : "Light"
        default: "\(Int((v * 100).rounded()))"
        }
    }

    // Audio (CoreAudio)
    static func addr(_ sel: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static var defaultOutput: AudioDeviceID {
        get {
            var id = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
            var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id)
            return id
        }
        set {
            var id = newValue, a = addr(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil,
                                       UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        }
    }
    static var volume: Double {
        get {
            var v = Float32(0), size = UInt32(4)
            var a = addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
            AudioObjectGetPropertyData(defaultOutput, &a, 0, nil, &size, &v)
            return Double(v)
        }
        set {
            let dev = defaultOutput
            var v = Float32(newValue)
            var a = addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
            AudioObjectSetPropertyData(dev, &a, 0, nil, 4, &v)
            var mute = UInt32(newValue < 0.01 ? 1 : 0), m = addr(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
            AudioObjectSetPropertyData(dev, &m, 0, nil, 4, &mute)
        }
    }
    /// Devices that can play sound (speakers, headphones, AirPlay…).
    static var outputs: [(id: AudioDeviceID, name: String)] {
        var a = addr(kAudioHardwarePropertyDevices), size = UInt32(0)
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
        return ids.compactMap { id in
            var s = addr(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput), n = UInt32(0)
            AudioObjectGetPropertyDataSize(id, &s, 0, nil, &n)
            guard n > 0 else { return nil }
            var na = addr(kAudioObjectPropertyName), name: Unmanaged<CFString>?
            var ns = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            AudioObjectGetPropertyData(id, &na, 0, nil, &ns, &name)
            return (id, (name?.takeRetainedValue() as String?) ?? "Output")
        }
    }

    /// The screen the controls act on: the one the pointer was on when a dial/slider opened.
    nonisolated(unsafe) static var display: CGDirectDisplayID = CGMainDisplayID()

    // Brightness of `display`: built-in and Apple displays through private DisplayServices, other monitors through DDC/CI.
    typealias GetB = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias SetB = @convention(c) (CGDirectDisplayID, Float) -> Int32
    nonisolated(unsafe) static let ds = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    static var builtIn: CGDirectDisplayID {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16), n = UInt32(0)
        CGGetActiveDisplayList(16, &ids, &n)
        return ids.prefix(Int(n)).first { CGDisplayIsBuiltin($0) != 0 } ?? CGMainDisplayID()
    }
    static var brightness: Double {
        get {
            var v: Float = 0
            if let f = dlsym(ds, "DisplayServicesGetBrightness"), unsafeBitCast(f, to: GetB.self)(display, &v) == 0 { return Double(v) }
            return DDC.get(display) ?? 0.5
        }
        set {
            if let f = dlsym(ds, "DisplayServicesSetBrightness"), unsafeBitCast(f, to: SetB.self)(display, Float(newValue)) == 0 { return }
            DDC.set(display, newValue)
        }
    }

    // Keyboard backlight. ponytail: private CoreBrightness KeyboardBrightnessClient; does nothing on Macs without one
    nonisolated(unsafe) static let kbc: NSObject? = {
        dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
        return (NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type)?.init()
    }()
    static let kbID: UInt64 = {
        let sel = NSSelectorFromString("copyKeyboardBacklightIDs")
        guard let c = kbc, c.responds(to: sel), let ids = c.perform(sel)?.takeRetainedValue() as? [NSNumber],
              let first = ids.first else { return 1 }
        return first.uint64Value
    }()
    static var keyboard: Double {
        get {
            let sel = NSSelectorFromString("brightnessForKeyboard:")
            guard let c = kbc, c.responds(to: sel) else { return 0 }
            typealias F = @convention(c) (AnyObject, Selector, UInt64) -> Float
            return Double(unsafeBitCast(c.method(for: sel), to: F.self)(c, sel, kbID))
        }
        set {
            let sel = NSSelectorFromString("setBrightness:forKeyboard:")
            guard let c = kbc, c.responds(to: sel) else { return }
            typealias F = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
            _ = unsafeBitCast(c.method(for: sel), to: F.self)(c, sel, Float(newValue), kbID)
        }
    }

    // Light / dark mode (asks for Automation permission for System Events once)
    static var dark: Bool { UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" }
    static func setDark(_ on: Bool) {
        DispatchQueue.global().async {
            sh("osascript", "-e", "tell application \"System Events\" to tell appearance preferences to set dark mode to \(on)")
        }
    }
}

// MARK: - App Profiles

/// Control keys: cornerTL/TR/BL/BR, edgeLeft/Right. A profile overrides some of them while one app is in front.
let controlKeys = ["cornerTL", "cornerTR", "cornerBL", "cornerBR", "edgeLeft", "edgeRight"]

/// [bundle id: [control key: control, "_name": app name]]
var profiles: [String: [String: String]] {
    get { prefs.dictionary(forKey: "profiles") as? [String: [String: String]] ?? [:] }
    set { prefs.set(newValue, forKey: "profiles") }
}

/// What a corner/edge does right now: the front app's profile, else the default.
func control(_ key: String) -> String {
    let app = prefs.string(forKey: "lastAppID") ?? ""
    return profiles[app]?[key] ?? prefs.string(forKey: key) ?? "none"
}

// MARK: - Corner Dials

final class DialState: ObservableObject {
    @Published var shown = false
    @Published var expanded = false
    @Published var dragging = false
    @Published var scrolling = false
    @Published var value = 0.0
    @Published var control = "none"
    var lastAngle: Double?
    var scrollID = 0
}

/// A quarter of a dial peeks out of the corner; press and turn it (it grows into a full dial) to change the value.
struct CornerDialView: View {
    @ObservedObject var state: DialState
    let anchor: UnitPoint // which corner of the panel touches the screen corner
    static let size: CGFloat = 440, small: CGFloat = 120, big: CGFloat = 230, inset: CGFloat = 210

    var bigCenter: CGPoint {
        CGPoint(x: anchor.x * Self.size + (anchor.x == 0 ? Self.inset : -Self.inset),
                y: anchor.y * Self.size + (anchor.y == 0 ? Self.inset : -Self.inset))
    }

    var body: some View {
        let d = state.expanded ? Self.big : Self.small
        ZStack {
            if state.shown {
                Dial(value: state.value, control: state.control, showValue: state.dragging || state.scrolling)
                    .frame(width: d, height: d)
                    .position(state.expanded ? bigCenter : CGPoint(x: anchor.x * Self.size, y: anchor.y * Self.size))
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("panel"))
                        .onChanged(turn)
                        .onEnded { _ in // stays open; closes when the pointer moves away (Controls.tick)
                            state.dragging = false
                            state.lastAngle = nil
                        })
                    .transition(.scale(scale: 0.3, anchor: anchor).combined(with: .opacity))
            }
        }
        .frame(width: Self.size, height: Self.size)
        .coordinateSpace(name: "panel")
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: state.shown)
        .animation(.spring(response: 0.4, dampingFraction: 0.78), value: state.expanded)
    }

    /// Turning: the change in angle around the big dial's centre moves the value (300° = 0…100%).
    func turn(_ g: DragGesture.Value) {
        if !state.dragging {
            state.dragging = true
            state.value = Sys.get(state.control)
            state.expanded = true
        }
        let c = bigCenter
        let a = atan2(g.location.y - c.y, g.location.x - c.x) * 180 / .pi
        defer { state.lastAngle = a }
        guard let last = state.lastAngle else { return }
        var delta = a - last
        if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
        let v = min(1, max(0, state.value + delta / 300))
        guard v != state.value else { return }
        state.value = v
        Sys.set(state.control, v)
    }
}

/// White disc with a ring of ticks; the ticks up to the value are lit.
struct Dial: View {
    let value: Double, control: String, showValue: Bool
    var body: some View {
        GeometryReader { geo in
            let r = geo.size.width / 2
            ZStack {
                Circle().fill(.regularMaterial)
                    .overlay(Circle().fill(.white.opacity(0.55)))
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
                Canvas { ctx, size in
                    let c = CGPoint(x: size.width / 2, y: size.height / 2), n = 40
                    for i in 0..<n {
                        let t = Double(i) / Double(n - 1), a = (135 + 300 * t) * .pi / 180
                        var p = Path()
                        p.move(to: CGPoint(x: c.x + cos(a) * r * 0.70, y: c.y + sin(a) * r * 0.70))
                        p.addLine(to: CGPoint(x: c.x + cos(a) * r * 0.86, y: c.y + sin(a) * r * 0.86))
                        let on = value > 0.005 && t <= value + 0.001
                        ctx.stroke(p, with: .color(on ? .accentColor : .gray.opacity(0.35)),
                                   style: StrokeStyle(lineWidth: max(2, r * 0.05), lineCap: .round))
                    }
                }
                Circle().strokeBorder(.gray.opacity(0.2)).frame(width: r * 0.42, height: r * 0.42)
                Group {
                    if showValue {
                        Text(Sys.label(control, value)).font(.system(size: r * 0.16, weight: .semibold)).lineLimit(1)
                            .minimumScaleFactor(0.4).frame(width: r * 0.8)
                    } else {
                        Image(systemName: Sys.icons[control] ?? "circle").font(.system(size: r * 0.16, weight: .semibold))
                    }
                }
                .foregroundStyle(Color.accentColor)
            }
        }
    }
}

// MARK: - Edge Sliders

final class SliderState: ObservableObject {
    @Published var shown = false
    @Published var value = 0.0
    @Published var control = "none"
    var dragging = false
}

/// A dark tab slides out of the screen edge with a tall slider in it.
struct EdgeSliderView: View {
    @ObservedObject var state: SliderState
    let right: Bool
    static let size = CGSize(width: 70, height: 250)

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: right ? 26 : 0, bottomLeadingRadius: right ? 26 : 0,
                                           bottomTrailingRadius: right ? 0 : 26, topTrailingRadius: right ? 0 : 26,
                                           style: .continuous)
        ZStack {
            shape.fill(.black.opacity(0.88))
            GeometryReader { g in
                let h = g.size.height
                ZStack(alignment: .bottom) {
                    Capsule().fill(.white.opacity(0.18))
                    Capsule().fill(.white).frame(height: max(26, h * state.value))
                    Image(systemName: Sys.icons[state.control] ?? "circle")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(Color.accentColor).padding(.bottom, 8)
                }
                .contentShape(Capsule())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    state.dragging = true
                    state.value = min(1, max(0, 1 - v.location.y / h))
                    Sys.set(state.control, state.value)
                }.onEnded { _ in state.dragging = false })
            }
            .frame(width: 26)
            .padding(.vertical, 22)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .offset(x: state.shown ? 0 : (right ? Self.size.width : -Self.size.width))
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: state.shown)
    }
}

// MARK: - Overlay panels (corners + edges), driven by the 60 Hz pointer tick in AppDelegate

@MainActor
final class Controls {
    let corners: [(key: String, anchor: UnitPoint, state: DialState, panel: NSPanel)]
    let edges: [(key: String, right: Bool, state: SliderState, panel: NSPanel)]

    init() {
        func panel(_ v: some View, _ size: CGSize) -> NSPanel {
            let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.isReleasedWhenClosed = false
            p.level = .init(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.contentView = NSHostingView(rootView: v)
            return p
        }
        let s = CGSize(width: CornerDialView.size, height: CornerDialView.size)
        corners = [("cornerTL", UnitPoint.topLeading), ("cornerTR", .topTrailing), ("cornerBL", .bottomLeading), ("cornerBR", .bottomTrailing)]
            .map { key, a in let st = DialState(); return (key, a, st, panel(CornerDialView(state: st, anchor: a), s)) }
        edges = [("edgeLeft", false), ("edgeRight", true)]
            .map { key, r in let st = SliderState(); return (key, r, st, panel(EdgeSliderView(state: st, right: r), EdgeSliderView.size)) }
        // trackpad two-finger swipe / mouse wheel over a dial or slider changes it (no need to hold the button)
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            MainActor.assumeIsolated { self?.scroll(e) == true ? nil : e }
        }
    }

    func scroll(_ e: NSEvent) -> Bool {
        // up on the trackpad / wheel rolled up = more, whatever the "natural scrolling" setting
        let dy = e.isDirectionInvertedFromDevice ? -e.scrollingDeltaY : e.scrollingDeltaY
        let delta = dy * (e.hasPreciseScrollingDeltas ? 1.0 / 400 : 1.0 / 25)
        if let c = corners.first(where: { $0.panel == e.window && $0.state.shown }) {
            let v = min(1, max(0, c.state.value + delta))
            c.state.value = v
            Sys.set(c.state.control, v)
            c.state.scrolling = true
            c.state.scrollID += 1
            let id = c.state.scrollID
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { if c.state.scrollID == id { c.state.scrolling = false } }
            return true
        }
        if let s = edges.first(where: { $0.panel == e.window && $0.state.shown }) {
            s.state.value = min(1, max(0, s.state.value + delta))
            Sys.set(s.state.control, s.state.value)
            return true
        }
        return false
    }

    /// Controls follow the pointer's screen; while one is open they stay on that screen.
    var held: NSScreen?
    var dwell: [String: Date] = [:] // edges shared with another screen: when the pointer arrived there

    var last: (p: NSPoint, screen: NSScreen?)?
    var resistedAt = Date.distantPast

    /// The pointer can't stop at an edge/corner shared with another screen (it slides across). So when it crosses
    /// where a control lives, it's held back at the edge once and the control opens; push again (>0.6 s) to cross.
    func resist(_ m: inout NSPoint) {
        let cur = NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) }
        defer { last = (m, cur) }
        guard let l = last, let from = l.screen, cur != from, Date().timeIntervalSince(resistedAt) > 0.6 else { return }
        let f = from.frame, vf = from.visibleFrame, right = m.x >= f.maxX
        guard m.x >= f.maxX || m.x < f.minX, isShared(from, right: right) else { return }
        let edgeX = right ? f.maxX - 1 : f.minX
        var hit = false, y = l.p.y
        for c in corners where (c.anchor.x != 0) == right && control(c.key) != "none" {
            let pc = CGPoint(x: right ? f.maxX : f.minX, y: c.anchor.y == 0 ? vf.maxY : f.minY)
            if abs(l.p.y - pc.y) < 80 { hit = true; y = pc.y + (c.anchor.y == 0 ? -8 : 8) } // into the corner
        }
        for e in edges where e.right == right && control(e.key) != "none" {
            let y = vf.minY + vf.height * 0.62 - EdgeSliderView.size.height / 2
            if l.p.y >= y && l.p.y <= y + EdgeSliderView.size.height { hit = true }
        }
        guard hit else { return }
        resistedAt = Date()
        let p = NSPoint(x: edgeX, y: min(max(y, f.minY + 1), f.maxY - 1))
        CGWarpMouseCursorPosition(CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.height ?? 0) - p.y))
        CGAssociateMouseAndMouseCursorPosition(1)
        m = p
        held = from
    }

    /// At a shared edge the control opens right after the pointer was held back there,
    /// or after resting ~0.25 s; a real screen edge reacts at once.
    func arrived(_ key: String, _ near: Bool, shared: Bool) -> Bool {
        guard near else { dwell[key] = nil; return false }
        guard shared, Date().timeIntervalSince(resistedAt) > 0.6 else { return true }
        let since = dwell[key] ?? Date()
        dwell[key] = since
        return Date().timeIntervalSince(since) > 0.25
    }

    func isShared(_ s: NSScreen, right: Bool) -> Bool {
        let f = s.frame, strip = CGRect(x: right ? f.maxX : f.minX - 2, y: f.minY, width: 2, height: f.height)
        return NSScreen.screens.contains { $0 != s && $0.frame.intersects(strip) }
    }

    /// Returns true while the pointer is on a control, so the dock doesn't pop out underneath it.
    func tick(_ pointer: NSPoint) -> Bool {
        var m = pointer
        resist(&m)
        let open = corners.contains { $0.state.shown || $0.state.dragging } || edges.contains { $0.state.shown || $0.state.dragging }
        if !open, Date().timeIntervalSince(resistedAt) > 0.6 { held = NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } }
        guard let screen = held else { return false }
        if !open, let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            Sys.display = id // brightness = the screen you're on
        }
        let f = screen.frame, vf = screen.visibleFrame
        var busy = false
        for c in corners {
            let ctl = control(c.key)
            // the corner point; top corners sit just under the menu bar
            let p = CGPoint(x: c.anchor.x == 0 ? f.minX : f.maxX, y: c.anchor.y == 0 ? vf.maxY : f.minY)
            let d = hypot(m.x - p.x, m.y - p.y)
            if c.state.dragging { busy = true; continue }
            if c.state.expanded {
                // open big dial: stays until the pointer is well away from it
                let v = CornerDialView(state: c.state, anchor: c.anchor).bigCenter, pf = c.panel.frame
                let center = CGPoint(x: pf.minX + v.x, y: pf.maxY - v.y)
                if hypot(m.x - center.x, m.y - center.y) > CornerDialView.big / 2 + 90 && d > 95 { hide(c.state, c.panel) }
                busy = true
                continue
            }
            if ctl == "none" { if c.state.shown { hide(c.state, c.panel) }; continue }
            if !c.state.shown, arrived(c.key, d < 24, shared: isShared(screen, right: c.anchor.x != 0)) {
                c.state.control = ctl
                c.state.value = Sys.get(ctl)
                let size = CornerDialView.size
                c.panel.setFrameOrigin(NSPoint(x: c.anchor.x == 0 ? p.x : p.x - size, y: c.anchor.y == 0 ? p.y - size : p.y))
                c.panel.ignoresMouseEvents = false
                c.panel.orderFrontRegardless()
                c.state.shown = true
            } else if c.state.shown, d > 95 {
                hide(c.state, c.panel)
            }
            if c.state.shown { busy = true }
        }
        for e in edges {
            let ctl = control(e.key)
            if e.state.dragging { busy = true; continue }
            if ctl == "none" { if e.state.shown { e.state.shown = false; e.panel.ignoresMouseEvents = true }; continue }
            let h = EdgeSliderView.size.height, w = EdgeSliderView.size.width
            let y = vf.minY + vf.height * 0.62 - h / 2 // upper part of the edge, like the reference
            let edgeD = e.right ? f.maxX - m.x : m.x - f.minX
            let inBand = m.y >= y && m.y <= y + h
            if !e.state.shown, arrived(e.key, inBand && edgeD < (isShared(screen, right: e.right) ? 3 : 2) && edgeD >= -0.5,
                                       shared: isShared(screen, right: e.right)) {
                e.state.control = ctl
                e.state.value = Sys.get(ctl)
                e.panel.setFrame(NSRect(x: e.right ? f.maxX - w : f.minX, y: y, width: w, height: h), display: true)
                e.panel.ignoresMouseEvents = false
                e.panel.orderFrontRegardless()
                e.state.shown = true
            } else if e.state.shown, !inBand || edgeD > w + 30 {
                e.state.shown = false
                e.panel.ignoresMouseEvents = true
            }
            if e.state.shown || (inBand && edgeD < 4) { busy = true }
        }
        return busy
    }

    func hide(_ s: DialState, _ p: NSPanel) {
        s.shown = false
        s.expanded = false
        p.ignoresMouseEvents = true
    }
}

// MARK: - App Launcher

/// Every app on the Mac as a grid that opens next to the dock.
struct LauncherView: View {
    let apps: [(url: URL, icon: NSImage)]
    let close: () -> Void
    let cols = Array(repeating: GridItem(.fixed(64), spacing: 8), count: 8)
    var body: some View {
        VStack(spacing: 8) {
            Capsule().fill(.secondary.opacity(0.5)).frame(width: 36, height: 4)
            ScrollView {
                LazyVGrid(columns: cols, spacing: 12) {
                    ForEach(apps, id: \.url) { app in
                        let name = app.url.deletingPathExtension().lastPathComponent
                        VStack(spacing: 3) {
                            Image(nsImage: app.icon).resizable().interpolation(.high).frame(width: 52, height: 52)
                            Text(name).font(.system(size: 10)).lineLimit(1)
                        }
                        .frame(width: 64)
                        .contentShape(Rectangle())
                        .help(name)
                        .onTapGesture {
                            NSWorkspace.shared.openApplication(at: app.url, configuration: .init())
                            close()
                        }
                        .onDrag { NSItemProvider(object: app.url as NSURL) } // drag onto the dock to keep it there
                    }
                }
                .padding(.horizontal, 14)
            }
        }
        .padding(.top, 8).padding(.bottom, 12)
        .frame(width: LauncherView.width, height: LauncherView.height)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(.regularMaterial))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
    static let width: CGFloat = 8 * 64 + 7 * 8 + 28, height: CGFloat = 430
}

/// .app bundles in the usual places, sorted by name.
func allApps() -> [URL] {
    let fm = FileManager.default
    let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                NSHomeDirectory() + "/Applications"]
    var seen = Set<String>()
    return dirs.flatMap { (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: $0), includingPropertiesForKeys: nil)) ?? [] }
        .filter { $0.pathExtension == "app" && seen.insert($0.lastPathComponent).inserted }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
}

// MARK: - iPhone Deck (Mac side)

/// The music app to talk to: Spotify if it's running, else Music if it's running. Never launches either.
/// (Each script names its app literally: "current track" only compiles inside a tell to a real music app.)
func musicApp() -> String? {
    let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    return running.contains("com.spotify.client") ? "Spotify" : running.contains("com.apple.Music") ? "Music" : nil
}

/// Runs AppleScript inside SideDock (main thread), so macOS asks *SideDock* for permission to control the app,
/// and logs why it failed instead of failing silently.
@MainActor func runScript(_ source: String) -> String? {
    var err: NSDictionary?
    let out = NSAppleScript(source: source)?.executeAndReturnError(&err)
    if let err { dropLog.notice("AppleScript failed: \(err, privacy: .public)") }
    return out?.stringValue
}

struct NowPlaying {
    var title = "", artist = "", playing = false, artURL = "", position = 0.0, duration = 0.0
    var artData: Data?
}

/// Music's cover only changes with the track: keep it, send it again now and then (a phone may have just connected).
@MainActor var musicArt: (title: String, data: Data?, sent: Date) = ("", nil, .distantPast)

/// Now playing in Spotify (or Music): title, artist, state, cover, position.
@MainActor func nowPlaying() -> NowPlaying? {
    guard let app = musicApp() else { return nil }
    // Spotify gives a cover URL and milliseconds; Music gives seconds (its cover is fetched separately below)
    let art = app == "Spotify" ? "(artwork url of t)" : "\"\""
    let dur = app == "Spotify" ? "((duration of t) / 1000)" : "(duration of t)"
    guard let out = runScript("""
    tell application "\(app)"
      if player state is stopped then return ""
      set t to current track
      return (name of t) & linefeed & (artist of t) & linefeed & (player state as string) & linefeed & \(art) ¬
        & linefeed & (player position as string) & linefeed & (\(dur) as string)
    end tell
    """) else { return nil } // failures are logged by runScript
    let p = out.components(separatedBy: "\n")
    guard p.count >= 6 else { return nil }
    let num = { (s: String) in Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 } // decimal comma in some locales
    var np = NowPlaying(title: p[0], artist: p[1], playing: p[2] == "playing", artURL: p[3], position: num(p[4]), duration: num(p[5]))
    if app == "Music" {
        if musicArt.title != np.title {
            var err: NSDictionary?
            let d = NSAppleScript(source: "tell application \"Music\" to get data of artwork 1 of current track")?
                .executeAndReturnError(&err).data
            musicArt = (np.title, d.flatMap(NSImage.init(data:)).flatMap { jpeg($0, max: 400) }, .distantPast)
        }
        if Date().timeIntervalSince(musicArt.sent) > 10 { np.artData = musicArt.data; musicArt.sent = Date() }
    }
    return np
}

/// Small JPEG (longest side `max` px) for sending over the air.
func jpeg(_ img: NSImage, max: CGFloat) -> Data? {
    let k = min(1, max / Swift.max(img.size.width, img.size.height, 1))
    let size = NSSize(width: img.size.width * k, height: img.size.height * k)
    let small = NSImage(size: size)
    small.lockFocus()
    img.draw(in: NSRect(origin: .zero, size: size))
    small.unlockFocus()
    guard let tiff = small.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
    return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.75])
}

func mediaCommand(_ cmd: String) {
    guard let app = musicApp() else { return }
    let verb = ["playpause": "playpause", "next": "next track", "previous": "previous track"][cmd] ?? "playpause"
    DispatchQueue.main.async { _ = runScript("tell application \"\(app)\" to \(verb)") }
}

/// Small PNG of an app icon for the phone.
func pngIcon(_ path: String, px: Int = 120) -> Data {
    let src = NSWorkspace.shared.icon(forFile: path)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return Data() }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    src.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:]) ?? Data()
}

// MARK: - DDC/CI (brightness of non-Apple external monitors, Apple Silicon)

@_silgen_name("IOAVServiceCreateWithService")
func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOAVServiceReadI2C")
func IOAVServiceReadI2C(_ service: CFTypeRef, _ chip: UInt32, _ offset: UInt32, _ buf: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn
@_silgen_name("IOAVServiceWriteI2C")
func IOAVServiceWriteI2C(_ service: CFTypeRef, _ chip: UInt32, _ offset: UInt32, _ buf: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn

/// VCP 0x10 (luminance) over the display's I²C channel.
/// ponytail: external screens are matched to AV services by order; with 2+ third-party monitors the order can be off
enum DDC {
    nonisolated(unsafe) static var cache: [CGDirectDisplayID: Double] = [:]
    nonisolated(unsafe) static var pending: [CGDirectDisplayID: Double] = [:]
    nonisolated(unsafe) static var busy = false
    static let queue = DispatchQueue(label: "sidedock.ddc")

    static func service(_ display: CGDirectDisplayID) -> CFTypeRef? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16), n = UInt32(0)
        CGGetActiveDisplayList(16, &ids, &n)
        let externals = ids.prefix(Int(n)).filter { CGDisplayIsBuiltin($0) == 0 }.sorted()
        guard let index = externals.firstIndex(of: display) else { return nil }
        var iter = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        var services: [CFTypeRef] = []
        while case let s = IOIteratorNext(iter), s != 0 {
            defer { IOObjectRelease(s) }
            let loc = IORegistryEntryCreateCFProperty(s, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            if loc == "External", let av = IOAVServiceCreateWithService(kCFAllocatorDefault, s)?.takeRetainedValue() { services.append(av) }
        }
        return index < services.count ? services[index] : nil
    }

    static func packet(_ body: [UInt8]) -> [UInt8] { body + [body.reduce(0x6E ^ 0x51) { $0 ^ $1 }] }

    /// Last value we set (reading over I²C is slow and flaky); read once otherwise.
    static func get(_ display: CGDirectDisplayID) -> Double? {
        if let v = cache[display] { return v }
        guard let av = service(display) else { return nil }
        var req = packet([0x82, 0x01, 0x10])
        guard IOAVServiceWriteI2C(av, 0x37, 0x51, &req, UInt32(req.count)) == KERN_SUCCESS else { return nil }
        usleep(40_000)
        var reply = [UInt8](repeating: 0, count: 12)
        guard IOAVServiceReadI2C(av, 0x37, 0x51, &reply, 12) == KERN_SUCCESS else { return nil }
        let maxV = Double(Int(reply[6]) << 8 | Int(reply[7])), cur = Double(Int(reply[8]) << 8 | Int(reply[9]))
        guard maxV > 0 else { return nil }
        cache[display] = min(1, cur / maxV)
        return cache[display]
    }

    /// Coalesced (main thread): while a write is in flight only the newest value waits (monitors take ~50 ms per command).
    static func set(_ display: CGDirectDisplayID, _ v: Double) {
        cache[display] = v
        pending[display] = v
        if !busy { pump() }
    }

    static func pump() {
        guard let (d, value) = pending.first else { busy = false; return }
        pending[d] = nil
        busy = true
        queue.async {
            if let av = service(d) {
                let x = Int((value * 100).rounded())
                var data = packet([0x84, 0x03, 0x10, UInt8(x >> 8), UInt8(x & 0xFF)])
                _ = IOAVServiceWriteI2C(av, 0x37, 0x51, &data, UInt32(data.count))
                usleep(50_000)
            }
            DispatchQueue.main.async { pump() }
        }
    }
}
