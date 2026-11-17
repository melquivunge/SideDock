// The dock itself + the menu-bar control panel.
import SwiftUI
import ServiceManagement
import ApplicationServices

final class PanelState: ObservableObject {
    @Published var hidden = false
    @Published var mouse: CGPoint? // pointer in panel coords (top-left origin), nil when outside
    var reserve: CGFloat = 0       // dock width windows should stay clear of
    var edgeSince: Date?           // when the pointer reached a shared edge (auto-hide)
}

// MARK: - Dock

/// Where every icon goes. Too many icons for the screen: wrap into more columns, or shrink.
struct DockLayout {
    static let dotW: CGFloat = 7 // running dot + its spacing
    var s: CGFloat, pad: CGFloat, perCol: Int, cols: Int, contentWidth: CGFloat
    var centers: [CGPoint] = [] // x = distance from screen edge, y = from top
    var sep: [Bool] = []

    init(items: [Item], length h: CGFloat, size: Double, spacing sp: Double, gap: Double, columns: Bool) {
        pad = max(4, size * 0.15)
        let n = max(items.count, 1)
        let avail = h - 2 * pad - 20
        perCol = columns ? max(1, Int((avail + sp) / (size + sp))) : n
        cols = Int((Double(n) / Double(perCol)).rounded(.up))
        let oneCol = cols == 1
        sep = items.indices.map { oneCol && $0 > 0 && items[$0].group != items[$0 - 1].group }
        let seps = CGFloat(sep.filter { $0 }.count), sepH = sp + 1
        let rows = CGFloat(min(n, perCol))
        s = max(16, min(size, (avail - (rows - 1) * sp - seps * sepH) / rows))
        contentWidth = 2 * pad + CGFloat(cols) * (s + Self.dotW) + CGFloat(cols - 1) * sp
        let top = (h - (2 * pad + rows * s + (rows - 1) * sp + seps * sepH)) / 2 + pad
        var y = top
        for i in items.indices {
            if i % perCol == 0 { y = top }
            if sep[i] { y += sepH }
            let x = gap + pad + CGFloat(i / perCol) * (s + Self.dotW + sp) + s / 2
            centers.append(CGPoint(x: x, y: y + s / 2))
            y += s + sp
        }
    }
}

struct DockView: View {
    @ObservedObject var model: Model
    @ObservedObject var state: PanelState
    @AppStorage("size") var size = 48.0
    @AppStorage("magnification") var mag = 0.5
    @AppStorage("spacing") var spacing = 6.0
    @AppStorage("side") var side = "left"
    @AppStorage("autohide") var autohide = false
    @AppStorage("dots") var dots = true
    @AppStorage("showRunning") var showRunning = true
    @AppStorage("showFolders") var showFolders = true
    @AppStorage("showTrash") var showTrash = true
    @AppStorage("showLauncher") var showLauncher = true
    @AppStorage("style") var style = "liquid"
    @AppStorage("tint") var tint = "1E1E1E"
    @AppStorage("opacity") var opacity = 1.0
    @AppStorage("radius") var radius = 18.0
    @AppStorage("gap") var gap = 6.0
    @AppStorage("overflow") var overflow = "columns"

    var visible: [Item] {
        model.items.filter {
            switch $0.kind {
            case .app: $0.pinned || showRunning
            case .folder: showFolders
            case .trash: showTrash
            case .launcher: showLauncher
            }
        }
    }

    // "main" axis runs along the edge (vertical for left/right, horizontal for bottom); "cross" points away from it.
    var bottom: Bool { side == "bottom" }

    var body: some View {
        GeometryReader { geo in
            let items = visible
            let L = DockLayout(items: items, length: bottom ? geo.size.width : geo.size.height, size: size,
                               spacing: spacing, gap: gap, columns: overflow == "columns")
            let chunks = stride(from: 0, to: items.count, by: L.perCol).map { Array($0..<min($0 + L.perCol, items.count)) }
            let lines = bottom ? AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
                               : AnyLayout(HStackLayout(alignment: .top, spacing: spacing))
            let line = bottom ? AnyLayout(HStackLayout(alignment: .bottom, spacing: spacing))
                              : AnyLayout(VStackLayout(alignment: side == "left" ? .leading : .trailing, spacing: spacing))
            let edge: Edge = bottom ? .bottom : side == "left" ? .leading : .trailing
            lines {
                ForEach(side == "left" ? chunks : chunks.reversed(), id: \.first) { chunk in // chunk 0 hugs the edge
                    line {
                        ForEach(chunk, id: \.self) { i in
                            if L.sep[i] {
                                Capsule().fill(.primary.opacity(0.25))
                                    .frame(width: bottom ? 1 : L.s * 0.7, height: bottom ? L.s * 0.7 : 1)
                                    .frame(width: bottom ? nil : L.s + DockLayout.dotW, height: bottom ? L.s + DockLayout.dotW : nil)
                            }
                            row(items[i], s: L.s * scale(L.centers[i], L, geo.size))
                        }
                    }
                }
            }
            .padding(L.pad)
            // like the macOS Dock: the bar keeps the un-magnified thickness, magnified icons rise out of it
            .background(alignment: bottom ? .bottom : side == "left" ? .leading : .trailing) {
                background.frame(width: bottom ? nil : L.contentWidth, height: bottom ? L.contentWidth : nil)
            }
            .contentShape(Rectangle())
            .onDrop(of: [.fileURL, .plainText], isTargeted: nil) { model.handleDrop($0, onto: nil) }
            .contextMenu { dockMenu }
            .padding(Edge.Set(edge), gap)
            .offset(x: state.hidden && !bottom ? (side == "left" ? -geo.size.width : geo.size.width) : 0,
                    y: state.hidden && bottom ? geo.size.height : 0)
            .frame(width: geo.size.width, height: geo.size.height,
                   alignment: bottom ? .bottom : side == "left" ? .leading : .trailing)
            .animation(.easeOut(duration: 0.12), value: state.mouse)
            .animation(.easeOut(duration: 0.2), value: state.hidden)
        }
    }

    /// Magnification: icons near the pointer grow, cosine falloff over ~3 icons.
    func scale(_ c: CGPoint, _ L: DockLayout, _ panel: CGSize) -> CGFloat {
        guard mag > 0, !state.hidden, let m = state.mouse else { return 1 }
        // pointer as (cross distance from edge, position along edge)
        let p = switch side {
        case "right": CGPoint(x: panel.width - m.x, y: m.y)
        case "bottom": CGPoint(x: panel.height - m.y, y: m.x)
        default: m
        }
        guard p.x <= gap + L.contentWidth + 10 else { return 1 }
        let dx = L.cols > 1 ? p.x - c.x : 0 // one line of icons: only distance along the edge matters
        let d = hypot(dx, p.y - c.y), range = L.s * 3
        return d >= range ? 1 : 1 + mag * (cos(.pi * d / range) + 1) / 2
    }

    func row(_ item: Item, s: CGFloat) -> some View {
        let stack = bottom ? AnyLayout(VStackLayout(spacing: 3)) : AnyLayout(HStackLayout(spacing: 3))
        return stack {
            if side == "right" { dot(item) }
            Image(nsImage: item.icon).resizable().interpolation(.high).frame(width: s, height: s)
                .modifier(Bounce(on: model.launching.contains(item.id), height: s * 0.45, side: side))
            if side != "right" { dot(item) } // left: dot to the right; bottom: dot underneath
        }
        .help(item.name)
        .contentShape(Rectangle())
        .onTapGesture { model.bounce(item); click(item) }
        .onDrag { NSItemProvider(object: "sidedock:\(item.id)" as NSString) }
        .onDrop(of: [.fileURL, .plainText], isTargeted: nil) { model.handleDrop($0, onto: item) }
        .contextMenu { itemMenu(item) }
    }

    func dot(_ item: Item) -> some View {
        Circle().fill(dots && item.running ? Color.primary.opacity(0.8) : .clear).frame(width: 4, height: 4)
    }

    @ViewBuilder var background: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        switch style {
        case "liquid": Color.clear.glassEffect(.regular, in: shape).opacity(opacity)
        case "frosted": shape.fill(.ultraThinMaterial).overlay(shape.strokeBorder(.white.opacity(0.15))).opacity(opacity)
        case "color": shape.fill(Color(hex: tint).opacity(opacity)).overlay(shape.strokeBorder(.white.opacity(0.1)))
        default: EmptyView()
        }
    }

    @ViewBuilder func itemMenu(_ item: Item) -> some View {
        switch item.kind {
        case .app:
            Button(item.running ? "Show" : "Open") { click(item) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Divider()
            Button(item.pinned ? "Remove from Dock" : "Keep in Dock") { model.togglePin(item) }
            if item.running {
                Divider()
                Button("Hide") { runningApp(item.id)?.hide() }
                Button("Quit") { runningApp(item.id)?.terminate() }
            }
        case .folder:
            Button("Open in Finder") { NSWorkspace.shared.open(item.url) }
            Button("Remove from Dock") { model.remove(item.id) }
        case .trash:
            Button("Open") { NSWorkspace.shared.open(trashURL) }
            Button("Empty Trash…") { emptyTrash() }
        case .launcher:
            Button("Show All Apps") { click(item) }
            Button("Remove from Dock") { showLauncher = false }
        }
        Divider()
        dockMenu
    }

    @ViewBuilder var dockMenu: some View {
        Button(autohide ? "Turn Hiding Off" : "Turn Hiding On") { autohide.toggle() }
        Menu("Position on Screen") {
            ForEach([("Left", "left"), ("Bottom", "bottom"), ("Right", "right")], id: \.1) { name, value in
                Button { side = value } label: { Text(side == value ? "✓ \(name)" : name) }
            }
        }
        Button("Dock Settings…") { (NSApp.delegate as? AppDelegate)?.showPanel() }
        Button("Turn SideDock Off") { prefs.set(false, forKey: "dockEnabled") }
    }
}

// MARK: - Control panel (menu-bar popover)

struct ControlPanel: View {
    @ObservedObject var drop: DropCenter
    @AppStorage("dropEnabled") var dropEnabled = true
    @AppStorage("phoneSide") var phoneSide = "right"
    @AppStorage("glowScreen") var glowScreen = ""
    @AppStorage("dropFolder") var dropFolder = "desktop"
    @AppStorage("shelfAuto") var shelfAuto = false
    @AppStorage("airdrop") var airdrop = true
    @AppStorage("phoneScale") var phoneScale = 0.8
    @AppStorage("phoneY") var phoneY = 0.62
    @AppStorage("size") var size = 48.0
    @AppStorage("magnification") var mag = 0.5
    @AppStorage("spacing") var spacing = 6.0
    @AppStorage("side") var side = "left"
    @AppStorage("screen") var screen = "all"
    @AppStorage("autohide") var autohide = false
    @AppStorage("reserveSpace") var reserve = false
    @AppStorage("dots") var dots = true
    @AppStorage("showRunning") var showRunning = true
    @AppStorage("showFolders") var showFolders = true
    @AppStorage("showTrash") var showTrash = true
    @AppStorage("style") var style = "liquid"
    @AppStorage("tint") var tint = "1E1E1E"
    @AppStorage("opacity") var opacity = 1.0
    @AppStorage("radius") var radius = 18.0
    @AppStorage("gap") var gap = 6.0
    @AppStorage("overflow") var overflow = "columns"
    @AppStorage("dockEnabled") var dockEnabled = true
    @AppStorage("dockMode") var dockMode = "replace"
    @AppStorage("showLauncher") var showLauncher = true
    @AppStorage("lastAppID") var lastAppID = ""
    @AppStorage("lastAppName") var lastAppName = ""
    @State var scope = "" // "" = all apps, else the bundle id whose profile is being edited
    @State var rev = 0    // bumps when profiles change, to redraw
    @State var tab = 0
    @State var login = SMAppService.mainApp.status == .enabled

    let tabs = [("dock.rectangle", "Dock"), ("rectangle.split.3x1", "Position"),
                ("paintpalette", "Appearance"), ("square.grid.2x2", "Items"), ("dial.medium", "Controls"),
                ("iphone.radiowaves.left.and.right", "iPhone"), ("gearshape.2", "Behavior")]
    let swatches = ["1E1E1E", "F2F2F7", "2C3E50", "5B2C6F", "0E6655", "7B241C", "B9770E"]

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "dock.rectangle").font(.system(size: 34, weight: .light)).padding(.top, 6)
            tabBar
            // panel height is fixed; tabs that are taller scroll (header and bottom buttons stay put)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(tabs[tab].1.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    switch tab {
                    case 0: dockTab
                    case 1: positionTab
                    case 2: appearanceTab
                    case 3: itemsTab
                    case 4: controlsTab
                    case 5: iphoneTab
                    default: behaviorTab
                    }
                }
                .padding(.bottom, 4)
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: .infinity)
            HStack(spacing: 10) {
                BigButton(title: dockEnabled ? "Turn Dock Off" : "Turn Dock On",
                          icon: dockEnabled ? "pause.circle" : "play.circle") { dockEnabled.toggle() }
                BigButton(title: "Quit", icon: "power") { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 340, height: 640, alignment: .top) // fixed size: switching tabs never resizes/moves the popover
    }

    var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(tabs.indices, id: \.self) { i in
                Button { tab = i } label: {
                    Image(systemName: tabs[i].0).font(.system(size: 14))
                        .foregroundStyle(tab == i ? .white : .secondary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(tab == i ? Color.accentColor : .clear))
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(tabs[i].1)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.06)))
    }

    var dockTab: some View {
        VStack(spacing: 10) {
            Card {
                Label("Icon size")
                Chips(options: [("S", 36.0), ("M", 48.0), ("L", 64.0), ("XL", 88.0)], selection: $size)
                SliderRow(title: "Size", value: $size, range: 24...128) { "\(Int($0)) pt" }
                Label("When the dock is full")
                Chips(options: [("Add columns", "columns"), ("Shrink icons", "shrink")], selection: $overflow, columns: 2)
            }
            Card {
                Label("Magnification")
                Chips(options: [("Off", 0.0), ("Small", 0.3), ("Medium", 0.6), ("Large", 1.0)], selection: $mag)
                SliderRow(title: "Zoom", value: $mag, range: 0...1) { "\(Int($0 * 100))%" }
                SliderRow(title: "Icon spacing", value: $spacing, range: 0...20) { "\(Int($0)) pt" }
            }
        }
    }

    var positionTab: some View {
        VStack(spacing: 10) {
            Card {
                Label("Dock")
                Chips(options: [("Replace macOS Dock", "replace"), ("Hidden Dock", "alongside")], selection: $dockMode, columns: 2)
                Hint(dockMode == "replace"
                     ? "SideDock’s dock takes the place of the macOS Dock, on any edge."
                     : "The macOS Dock stays. Move the pointer to the end of it and the Hidden Dock slides out. Drag apps onto it from Finder or the App Launcher. Needs Accessibility.")
                if dockMode == "alongside" {
                    ActionChip(title: "Recalibrate") { (NSApp.delegate as? AppDelegate)?.stash.recalibrate() }
                }
            }
            if dockMode == "replace" { replaceOptions }
        }
    }

    var replaceOptions: some View {
        VStack(spacing: 10) {
            Card {
                Label("Side")
                Chips(options: [("Left", "left"), ("Bottom", "bottom"), ("Right", "right")], selection: $side, columns: 3)
            }
            Card {
                Label("Show on")
                Chips(options: [("All screens", "all")] + NSScreen.screens.map { ($0.name, $0.name) },
                      selection: $screen, columns: 2)
                Hint("Pick one screen, or show the dock on every screen at once.")
            }
            Card { SliderRow(title: "Distance from edge", value: $gap, range: 0...40) { "\(Int($0)) pt" } }
        }
    }

    var appearanceTab: some View {
        VStack(spacing: 10) {
            Card {
                Label("Background")
                Chips(options: [("Liquid", "liquid"), ("Frosted", "frosted"), ("Color", "color"), ("None", "none")],
                      selection: $style)
                if style == "color" {
                    HStack(spacing: 8) {
                        ForEach(swatches, id: \.self) { hex in
                            Circle().fill(Color(hex: hex)).frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(tint == hex ? Color.accentColor : .white.opacity(0.2),
                                                               lineWidth: tint == hex ? 2 : 1))
                                .onTapGesture { tint = hex }
                        }
                        Spacer()
                        ColorPicker("", selection: Binding(get: { Color(hex: tint) }, set: { tint = $0.hex }),
                                    supportsOpacity: false).labelsHidden()
                    }
                }
            }
            Card {
                SliderRow(title: "Opacity", value: $opacity, range: 0.1...1) { "\(Int($0 * 100))%" }
                SliderRow(title: "Corner radius", value: $radius, range: 0...40) { "\(Int($0)) pt" }
            }
        }
    }

    var itemsTab: some View {
        VStack(spacing: 10) {
            Card {
                ToggleRow(title: "Open-app indicators", isOn: $dots)
                Divider()
                ToggleRow(title: "Open apps that aren't kept", subtitle: "Shown below a divider", isOn: $showRunning)
                Divider()
                ToggleRow(title: "Folders & Downloads", subtitle: "Click to see the newest files", isOn: $showFolders)
                Divider()
                ToggleRow(title: "Trash", isOn: $showTrash)
                Divider()
                ToggleRow(title: "App Launcher", subtitle: "Every app in a grid, one click away", isOn: $showLauncher)
            }
            Card {
                Hint("Drag apps or folders from Finder onto the dock to add them. Drag icons to reorder. Drop an icon on the Trash to remove it. Right-click for more.")
                ActionChip(title: "Re-import from macOS Dock") {
                    importSystemDock(force: true)
                    (NSApp.delegate as? AppDelegate)?.model.reload()
                }
            }
        }
    }

    // MARK: Controls (Corner Dials, Edge Sliders, App Profiles)

    static let cornerOptions = ["none", "volume", "brightness", "keyboard", "output"]
    static let edgeOptions = ["none", "volume", "brightness", "keyboard", "appearance"]

    /// Apps you can give their own controls: ones that already have a profile + the app you used last.
    var profileApps: [(String, String)] {
        _ = rev
        var list = profiles.map { ($0.value["_name"] ?? $0.key, $0.key) }.sorted { $0.0 < $1.0 }
        if !lastAppID.isEmpty, !list.contains(where: { $0.1 == lastAppID }) { list.append((lastAppName, lastAppID)) }
        return list
    }

    /// Binding to one corner/edge in the scope being edited. In an app profile, "" = same as all apps.
    func binding(_ key: String) -> Binding<String> {
        Binding(get: {
            _ = rev
            return scope.isEmpty ? prefs.string(forKey: key) ?? "none" : profiles[scope]?[key] ?? ""
        }, set: { v in
            if scope.isEmpty { prefs.set(v, forKey: key) } else {
                var all = profiles, p = all[scope] ?? ["_name": scope == lastAppID ? lastAppName : scope]
                p[key] = v.isEmpty ? nil : v
                all[scope] = p.count > 1 ? p : nil // only a name left: drop the profile
                profiles = all
            }
            rev += 1
        })
    }

    func controlPicker(_ title: String, _ key: String, _ options: [String]) -> some View {
        HStack {
            Text(title).font(.system(size: 12))
            Spacer()
            Picker("", selection: binding(key)) {
                if !scope.isEmpty { Text("Same as all apps").tag("") }
                ForEach(options, id: \.self) { Text(Sys.names[$0] ?? $0).tag($0) }
            }
            .labelsHidden().fixedSize()
        }
    }

    var controlsTab: some View {
        VStack(spacing: 10) {
            Card {
                Label("Settings for")
                Chips(options: [("All apps", "")] + profileApps, selection: $scope, columns: 2)
                Hint(scope.isEmpty ? "App Profiles: switch to an app, reopen this panel and pick it to give it its own controls."
                                   : "Used automatically while this app is in front.")
            }
            Card {
                Label("Corner dials")
                controlPicker("Top left", "cornerTL", Self.cornerOptions)
                controlPicker("Top right", "cornerTR", Self.cornerOptions)
                controlPicker("Bottom left", "cornerBL", Self.cornerOptions)
                controlPicker("Bottom right", "cornerBR", Self.cornerOptions)
                Hint("Push the pointer into a corner, then scroll (trackpad or mouse wheel) or press and turn the dial.")
            }
            Card {
                Label("Edge sliders")
                controlPicker("Left edge", "edgeLeft", Self.edgeOptions)
                controlPicker("Right edge", "edgeRight", Self.edgeOptions)
                Hint("Touch the upper part of the edge; a slider slides out — scroll or drag it. Appearance switches light/dark (asks for permission once).")
            }
            if !scope.isEmpty {
                Card {
                    ActionChip(title: "Remove this app’s profile") {
                        profiles[scope] = nil
                        scope = ""
                        rev += 1
                    }
                }
            }
        }
    }

    var builtInName: String {
        NSScreen.screens.first { $0.localizedName.localizedCaseInsensitiveContains("built-in") }?.name ?? NSScreen.screens.first?.name ?? ""
    }

    var iphoneTab: some View {
        VStack(spacing: 10) {
            Card {
                ToggleRow(title: "Share files with iPhone", subtitle: "Open SideDrop on the iPhone and hold it next to the Mac",
                          isOn: $dropEnabled)
                Divider()
                ToggleRow(title: "Use AirDrop too", subtitle: "Edge drops use AirDrop when SideDrop isn’t open; AirDrop arrivals get the glow",
                          isOn: $airdrop)
                Divider()
                HStack(spacing: 8) {
                    Circle().fill(drop.peers.isEmpty ? Color.secondary : .green).frame(width: 8, height: 8)
                    Text(drop.peers.isEmpty ? "No iPhone connected" : drop.peers.map(\.displayName).joined(separator: ", "))
                        .font(.system(size: 12))
                }
            }
            Card {
                Label("Your iPhone sits on the")
                Chips(options: [("Left", "left"), ("Right", "right")], selection: $phoneSide, columns: 2)
                Label("Glow on screen")
                // "" (default) means the built-in display, so show that chip as selected
                Chips(options: NSScreen.screens.map { ($0.name, $0.name) },
                      selection: Binding(get: { glowScreen.isEmpty ? builtInName : glowScreen }, set: { glowScreen = $0 }),
                      columns: 2)
                    .onChange(of: glowScreen) { _, _ in (NSApp.delegate as? AppDelegate)?.previewGlow() }
                ActionChip(title: "Preview glow") { (NSApp.delegate as? AppDelegate)?.previewGlow() }
                SliderRow(title: "Photo size on the Mac", value: $phoneScale, range: 0.5...1.3) { "\(Int($0 * 100))%" }
                SliderRow(title: "iPhone height along the edge", value: $phoneY, range: 0.3...0.9) {
                    $0 < 0.5 ? "higher" : $0 > 0.7 ? "lower" : "middle"
                }
                Hint("Line these up so a photo dragged off the iPhone continues seamlessly onto the Mac.")
                Hint("Learned automatically from the way you swipe on the iPhone or which edge you drop on. While dragging a file, both edges light up — drop on either to send.")
            }
            Card {
                Label("Save received files to")
                Chips(options: [("Desktop", "desktop"), ("Downloads/SideDrop", "downloads")], selection: $dropFolder, columns: 2)
                ToggleRow(title: "Open the shelf when files arrive", isOn: $shelfAuto)
                ActionChip(title: "Show file shelf") { (NSApp.delegate as? AppDelegate)?.showShelf() }
                ActionChip(title: "Open received files folder") {
                    try? FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(inboxURL)
                }
                ActionChip(title: "Forget paired iPhones") { prefs.removeObject(forKey: "dropSecrets") }
                Hint("A new iPhone must be approved on this Mac the first time it connects.")
            }
        }
    }

    var behaviorTab: some View {
        VStack(spacing: 10) {
            Card {
                ToggleRow(title: "Auto-hide", subtitle: "Appears when the pointer touches the edge", isOn: $autohide)
                Divider()
                ToggleRow(title: "Keep windows clear of the dock",
                          subtitle: "Moves windows off the dock · needs Accessibility", isOn: $reserve)
                    .onChange(of: reserve) { _, on in
                        if on {
                            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
                        }
                    }
                Divider()
                ToggleRow(title: "Open at login", isOn: $login)
                    .onChange(of: login) { _, on in
                        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        login = SMAppService.mainApp.status == .enabled
                    }
            }
            Card { ActionChip(title: "Reset all settings") { defaultPrefs.keys.forEach(prefs.removeObject) } }
        }
    }
}

// MARK: - Panel building blocks

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }
}

struct Label: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.system(size: 13)) }
}

struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct ChipLabel: View {
    let title: String, on: Bool
    var body: some View {
        Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            .frame(maxWidth: .infinity).padding(.vertical, 6)
            .background(Capsule().fill(on ? Color.accentColor : .white.opacity(0.08)))
            .foregroundStyle(on ? .white : .primary)
            .contentShape(Capsule())
    }
}

struct Chips<T: Hashable>: View {
    let options: [(String, T)]
    @Binding var selection: T
    var columns = 4
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
            ForEach(options.indices, id: \.self) { i in
                Button { selection = options[i].1 } label: { ChipLabel(title: options[i].0, on: selection == options[i].1) }
                    .buttonStyle(.plain)
            }
        }
    }
}

struct ActionChip: View {
    let title: String
    let action: () -> Void
    var body: some View { Button(action: action) { ChipLabel(title: title, on: false) }.buttonStyle(.plain) }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value)).foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.system(size: 12))
            Slider(value: $value, in: range).controlSize(.small)
        }
    }
}

struct ToggleRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            Spacer()
            Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
    }
}

struct BigButton: View {
    let title: String, icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) { Image(systemName: icon); Text(title) }
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.08)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension Color {
    init(hex: String) {
        let v = UInt64(hex, radix: 16) ?? 0
        self.init(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
    }
    var hex: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(format: "%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}

/// The launch bounce: the icon hops away from the screen edge, easing like a ball, while `on`.
struct Bounce: ViewModifier {
    let on: Bool, height: CGFloat, side: String
    func body(content: Content) -> some View {
        if on {
            TimelineView(.animation) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.6) / 0.6
                let h = height * 4 * t * (1 - t) // parabola: up and back down each 0.6 s
                content.offset(x: side == "left" ? h : side == "right" ? -h : 0, y: side == "bottom" ? -h : 0)
            }
        } else {
            content
        }
    }
}
