// Deck: the iPhone as a remote for the Mac. Pages: Control (dials in the corners), Launch (throw an app to the Mac),
// Shelf (now playing + timer widgets). Talks to the Mac through DropClient (Mac side: Controls.swift / handleDeck).
import SwiftUI

struct DeckView: View {
    @ObservedObject var client: DropClient
    @Environment(\.dismiss) var dismiss
    @State var page = 0
    let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    static let modes = ["Control", "Launch", "Windows", "Shelf", "Creative"]

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.03, green: 0.2, blue: 0.62), Color(red: 0.2, green: 0.47, blue: 0.98)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            TabView(selection: $page) {
                DeckControl(client: client).tag(0)
                DeckLaunch(client: client).tag(1)
                DeckWindows(client: client).tag(2)
                DeckShelf(client: client).tag(3)
                DeckCreative(client: client).tag(4)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .ignoresSafeArea()
            HStack(spacing: 10) {
                Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 0) {
                    Text(client.macName ?? "Not connected").font(.subheadline.weight(.semibold))
                    Text(page == 4 ? client.creative?.name ?? "Creative" : Self.modes[page])
                        .font(.caption).foregroundStyle(.white.opacity(0.6))
                }
                Button { dismiss() } label: { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                    .padding(.leading, 6)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Capsule().fill(.white.opacity(0.12)).overlay(Capsule().strokeBorder(.white.opacity(0.2))))
            .padding(.top, 8)
        }
        .preferredColorScheme(.dark)
        .onAppear { client.deckRefresh(apps: true); client.deckRefresh() }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onReceive(poll) { _ in client.deckRefresh() }
        .onChange(of: client.macName) { _, name in if name != nil { client.deckRefresh(apps: true) } }
        .overlay {
            if client.macName == nil { // not connected yet: say how, instead of silent controls
                VStack(spacing: 14) {
                    Radar(closeness: client.closeness, connected: false).frame(height: 160)
                    Text("Hold your iPhone next to your Mac").font(.headline)
                    Text(client.status).font(.footnote).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
                    Button("Close") { dismiss() }.buttonStyle(.bordered).padding(.top, 6)
                }
                .foregroundStyle(.white)
                .padding(30)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.ultraThinMaterial)
            }
        }
    }
}

// MARK: - Control

/// Four corners, four controls. Drag up/down anywhere in a corner's quarter of the screen to change it.
struct DeckControl: View {
    @ObservedObject var client: DropClient
    @State var active: String?
    @State var start = 0.0
    // x/y: true = right/bottom
    static let corners: [(control: String, x: Bool, y: Bool, icon: String, name: String)] = [
        ("brightness", false, false, "sun.max", "Brightness"), ("appearance", true, false, "circle.lefthalf.filled", "Appearance"),
        ("volume", false, true, "speaker.wave.2", "Volume"), ("keyboard", true, true, "light.max", "Keyboard"),
    ]

    func value(_ c: String) -> Double { client.deckValues[c] ?? 0 }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                ForEach(Self.corners, id: \.control) { c in
                    CornerTicks(value: value(c.control), right: c.x, bottom: c.y, lit: active == c.control)
                    Image(systemName: c.icon).font(.system(size: 17)).foregroundStyle(.white.opacity(0.7))
                        .position(x: c.x ? size.width - 64 : 64, y: c.y ? size.height - 64 : 64)
                }
                if let a = active, let c = Self.corners.first(where: { $0.control == a }) {
                    VStack(spacing: 6) {
                        Text(a == "appearance" ? (value(a) >= 0.5 ? "Dark" : "Light") : "\(Int((value(a) * 100).rounded()))")
                            .font(.system(size: 96, weight: .semibold, design: .rounded)).monospacedDigit()
                            .contentTransition(.numericText())
                        Text(c.name.uppercased()).font(.footnote.weight(.semibold)).kerning(4).foregroundStyle(.white.opacity(0.6))
                    }
                    .foregroundStyle(.white)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                } else {
                    Text("Drag up or down in a corner").font(.footnote).foregroundStyle(.white.opacity(0.5))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 4).onChanged { g in
                if active == nil {
                    let right = g.startLocation.x > size.width / 2, bottom = g.startLocation.y > size.height / 2
                    guard let c = Self.corners.first(where: { $0.x == right && $0.y == bottom }) else { return }
                    withAnimation(.easeOut(duration: 0.15)) { active = c.control }
                    start = value(c.control)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                guard let a = active else { return }
                var v = min(1, max(0, start - g.translation.height / (size.height * 0.45)))
                if a == "appearance" { v = v >= 0.5 ? 1 : 0 }
                if v != value(a) {
                    if a == "appearance" || Int(v * 20) != Int(value(a) * 20) { UISelectionFeedbackGenerator().selectionChanged() }
                    client.deckSet(a, v)
                }
            }.onEnded { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { withAnimation { active = nil } }
            })
        }
    }
}

/// Ticks running down one edge, round the corner and along the other edge; lit up to the value.
struct CornerTicks: View {
    let value: Double, right: Bool, bottom: Bool, lit: Bool
    var body: some View {
        Canvas { ctx, size in
            let r: CGFloat = 46, e: CGFloat = 4, L: CGFloat = min(size.width, size.height) * 0.32
            // marks for the top-left corner (vertical run → arc → horizontal run), mirrored for the others
            var marks: [(p: CGPoint, n: CGPoint)] = []
            for i in 0..<10 { marks.append((CGPoint(x: e, y: r + L - L * CGFloat(i) / 10), CGPoint(x: 1, y: 0))) }
            for i in 0...10 {
                let a = (180 + 9 * Double(i)) * .pi / 180
                marks.append((CGPoint(x: r + (r - e) * cos(a), y: r + (r - e) * sin(a)), CGPoint(x: -cos(a), y: -sin(a))))
            }
            for i in 1...10 { marks.append((CGPoint(x: r + L * CGFloat(i) / 10, y: e), CGPoint(x: 0, y: 1))) }
            for (i, m) in marks.enumerated() {
                let t = Double(i) / Double(marks.count - 1)
                let p = CGPoint(x: right ? size.width - m.p.x : m.p.x, y: bottom ? size.height - m.p.y : m.p.y)
                let n = CGPoint(x: right ? -m.n.x : m.n.x, y: bottom ? -m.n.y : m.n.y)
                let len: CGFloat = i % 5 == 0 ? 16 : 9
                var path = Path()
                path.move(to: p)
                path.addLine(to: CGPoint(x: p.x + n.x * len, y: p.y + n.y * len))
                let on = value > 0.005 && t <= value + 0.001
                let arc = i >= 10 && i <= 20
                ctx.stroke(path, with: .color(on ? (arc ? Color(red: 0.35, green: 0.7, blue: 1) : .white) : .white.opacity(0.25)),
                           style: StrokeStyle(lineWidth: i % 5 == 0 ? 3 : 2, lineCap: .round))
            }
        }
        .opacity(lit ? 1 : 0.8)
        .allowsHitTesting(false)
    }
}

// MARK: - Launch

/// The Mac's dock apps. Tap one, or flick it up, to throw it onto the Mac's screen.
struct DeckLaunch: View {
    @ObservedObject var client: DropClient
    @State var thrown: String?
    @State var dragPath: String?
    @State var dragY: CGFloat = 0
    let cols = [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 28)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: cols, spacing: 28) {
                ForEach(client.deckApps, id: \.path) { app in
                    VStack(spacing: 6) {
                        Group {
                            if let img = UIImage(data: app.icon) { Image(uiImage: img).resizable() } else { Color.white.opacity(0.1) }
                        }
                        .frame(width: 84, height: 84)
                        .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
                    }
                    .offset(y: thrown == app.path ? -600 : dragPath == app.path ? dragY : 0)
                    .opacity(thrown == app.path ? 0 : 1)
                    .scaleEffect(thrown == app.path ? 0.6 : 1)
                    .onTapGesture { throwApp(app.path) }
                    .gesture(DragGesture(minimumDistance: 12).onChanged { g in
                        dragPath = app.path
                        dragY = min(0, g.translation.height)
                    }.onEnded { g in
                        dragPath = nil
                        dragY = 0
                        if g.translation.height < -60 || g.predictedEndTranslation.height < -200 { throwApp(app.path) }
                    })
                }
            }
            .padding(.horizontal, 60)
            .padding(.top, 76)
            .padding(.bottom, 30)
            if client.deckApps.isEmpty {
                Text("Your Mac’s dock apps appear here.").font(.footnote).foregroundStyle(.white.opacity(0.6)).padding(.top, 40)
            }
        }
        .animation(.spring(response: 0.3), value: dragY)
    }

    func throwApp(_ path: String) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.easeIn(duration: 0.35)) { thrown = path }
        client.deckLaunch(path)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { thrown = nil } // back in the grid for next time
    }
}

// MARK: - Shelf

/// Widgets: what's playing on the Mac (Spotify / Music) and a timer. Long-press the background to switch light/dark.
struct DeckShelf: View {
    @ObservedObject var client: DropClient
    @AppStorage("deckLight") var light = false

    var body: some View {
        GeometryReader { geo in
            if geo.size.width > geo.size.height { landscape(geo.size) } else { portrait(geo.size) }
        }
    }

    /// Upright: widgets stacked, full width, scroll down; the two agents side by side.
    func portrait(_ size: CGSize) -> some View {
        let w = size.width - 48
        return ScrollView {
            VStack(spacing: 18) {
                NowPlayingWidget(client: client, light: light).frame(width: w, height: min(240, w * 0.62))
                TimerWidget(light: light).frame(width: w, height: min(240, w * 0.62))
                HStack(spacing: 14) {
                    ForEach(client.agents, id: \.name) { AgentWidget(client: client, agent: $0, light: light) }
                }
                .frame(width: w, height: min(200, w * 0.5))
                Text("Long-press to switch widget style").font(.caption2).foregroundStyle(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
            .padding(.bottom, 40)
            .contentShape(Rectangle())
            .onLongPressGesture { withAnimation { light.toggle() } }
        }
    }

    /// Sideways: square widgets in a row, two per screen, swipe along.
    func landscape(_ size: CGSize) -> some View {
        let side = min(size.height - 120, (size.width - 120) / 2)
        return Group {
            ScrollView(.horizontal) {
                HStack(spacing: 40) {
                    NowPlayingWidget(client: client, light: light).frame(width: side)
                    TimerWidget(light: light).frame(width: side)
                    ForEach(client.agents, id: \.name) { AgentWidget(client: client, agent: $0, light: light).frame(width: side) }
                }
                .frame(height: side)
                .padding(.horizontal, (size.width - 2 * side - 40) / 2)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
            .frame(maxHeight: .infinity)
            .padding(.top, 30)
            .contentShape(Rectangle())
            .onLongPressGesture { withAnimation { light.toggle() } }
        }
    }
}

struct Widget<Content: View>: View {
    let light: Bool
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(light ? .black : .white)
            .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(light ? Color.white : Color.black))
            .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
    }
}

struct NowPlayingWidget: View {
    @ObservedObject var client: DropClient
    let light: Bool
    @State var full = false
    var body: some View {
        Widget(light: light) {
            VStack(spacing: 14) {
                HStack {
                    Equalizer(playing: client.track?.playing == true)
                    Spacer()
                    // the cover; tap it (or the title) for the big view with lyrics
                    Cover(client: client).frame(width: 46, height: 46)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .onTapGesture { if client.track != nil { full = true } }
                }
                VStack(spacing: 2) {
                    Text(client.track?.title ?? "Nothing playing").font(.headline).lineLimit(1)
                    Text((client.track?.artist ?? "Open Spotify or Music on the Mac").uppercased())
                        .font(.caption2).foregroundStyle(.gray).lineLimit(1)
                }
                .contentShape(Rectangle())
                .onTapGesture { if client.track != nil { full = true } }
                HStack {
                    Button { client.deckMedia("previous") } label: { Image(systemName: "backward.fill") }
                    Spacer()
                    Button { client.deckMedia("playpause") } label: {
                        Image(systemName: client.track?.playing == true ? "pause.fill" : "play.fill")
                    }
                    Spacer()
                    Button { client.deckMedia("next") } label: { Image(systemName: "forward.fill") }
                }
                .font(.system(size: 30))
                .padding(.horizontal, 10)
            }
        }
        .fullScreenCover(isPresented: $full) { NowPlayingView(client: client) }
    }
}

/// Album cover: Spotify sends a link, Music sends the picture itself.
struct Cover: View {
    @ObservedObject var client: DropClient
    var body: some View {
        Group {
            if let img = client.art?.image {
                Image(uiImage: img).resizable().scaledToFill()
            } else if let url = client.art?.url {
                AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.25) }
            } else {
                ZStack { Color.gray.opacity(0.25); Image(systemName: "music.note").foregroundStyle(.gray) }
            }
        }
    }
}

// MARK: - Now playing, full screen: big cover + synced lyrics

struct LyricLine: Hashable { let time: Double, text: String }

/// Lyrics from LRCLIB (lrclib.net, free and open). Only the song title and artist are sent.
@MainActor final class Lyrics: ObservableObject {
    @Published var lines: [LyricLine] = []  // synced: one line per timestamp
    @Published var plain: String?           // not synced: just the text
    @Published var loading = false
    var key = ""

    struct Hit: Decodable { let syncedLyrics: String?, plainLyrics: String?, duration: Double? }

    func load(title: String, artist: String, duration: Double) async {
        let k = title + "\u{1}" + artist
        guard k != key else { return }
        key = k
        lines = []; plain = nil; loading = true
        defer { if key == k { loading = false } }
        var c = URLComponents(string: "https://lrclib.net/api/search")!
        c.queryItems = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
        var req = URLRequest(url: c.url!)
        req.setValue("SideDrop/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let hits = try? JSONDecoder().decode([Hit].self, from: data), key == k else { return }
        // prefer synced lyrics whose length matches the song
        let best = hits.filter { $0.syncedLyrics != nil }.min { abs(($0.duration ?? 0) - duration) < abs(($1.duration ?? 0) - duration) }
            ?? hits.first { $0.plainLyrics != nil }
        if let lrc = best?.syncedLyrics { lines = Self.parse(lrc) }
        if lines.isEmpty { plain = best?.plainLyrics }
    }

    /// "[01:23.45] text" → (83.45, "text")
    static func parse(_ lrc: String) -> [LyricLine] {
        lrc.split(separator: "\n").compactMap { row in
            guard row.hasPrefix("["), let close = row.firstIndex(of: "]") else { return nil }
            let stamp = row[row.index(after: row.startIndex)..<close].split(separator: ":")
            guard stamp.count == 2, let m = Double(stamp[0]), let sec = Double(stamp[1]) else { return nil }
            return LyricLine(time: m * 60 + sec, text: String(row[row.index(after: close)...]).trimmingCharacters(in: .whitespaces))
        }
    }
}

struct NowPlayingView: View {
    @ObservedObject var client: DropClient
    @StateObject var lyrics = Lyrics()
    @Environment(\.dismiss) var dismiss

    /// Where the song is now: last position from the Mac, moved on by the time since (while playing).
    func position(_ now: Date) -> Double {
        let t = client.trackTime
        return t.position + (client.track?.playing == true ? now.timeIntervalSince(t.at) : 0)
    }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > geo.size.height
            ZStack {
                Cover(client: client).blur(radius: 60).overlay(Color.black.opacity(0.55)).ignoresSafeArea()
                let layout = wide ? AnyLayout(HStackLayout(spacing: 40)) : AnyLayout(VStackLayout(spacing: 24))
                layout {
                    player(size: wide ? min(geo.size.height * 0.55, geo.size.width * 0.35) : min(geo.size.width * 0.7, geo.size.height * 0.32))
                        .frame(maxWidth: wide ? geo.size.width * 0.4 : .infinity)
                    lyricsView
                }
                .padding(wide ? 40 : 24)
                .padding(.top, wide ? 0 : 30)
            }
            .overlay(alignment: .topTrailing) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.headline).padding(12).background(Circle().fill(.white.opacity(0.15)))
                }
                .padding(20)
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .task(id: client.track?.title) {
            if let t = client.track { await lyrics.load(title: t.title, artist: t.artist, duration: client.trackTime.duration) }
        }
    }

    func player(size: CGFloat) -> some View {
        VStack(spacing: 14) {
            Cover(client: client).frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
            VStack(spacing: 4) {
                Text(client.track?.title ?? "").font(.title3.weight(.bold)).lineLimit(1)
                Text(client.track?.artist ?? "").font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            }
            TimelineView(.periodic(from: .now, by: 0.5)) { tl in
                let d = max(client.trackTime.duration, 1), p = min(position(tl.date), d)
                VStack(spacing: 4) {
                    ProgressView(value: p, total: d).tint(.white)
                    HStack { Text(clock(p)); Spacer(); Text("-" + clock(d - p)) }
                        .font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(width: size)
            HStack(spacing: 40) {
                Button { client.deckMedia("previous") } label: { Image(systemName: "backward.fill") }
                Button { client.deckMedia("playpause") } label: {
                    Image(systemName: client.track?.playing == true ? "pause.fill" : "play.fill").font(.system(size: 40))
                }
                Button { client.deckMedia("next") } label: { Image(systemName: "forward.fill") }
            }
            .font(.system(size: 28))
        }
    }

    func clock(_ s: Double) -> String { String(format: "%d:%02d", Int(max(0, s)) / 60, Int(max(0, s)) % 60) }

    @ViewBuilder var lyricsView: some View {
        if !lyrics.lines.isEmpty {
            TimelineView(.periodic(from: .now, by: 0.25)) { tl in
                let p = position(tl.date) + 0.3 // a touch early reads better
                let current = lyrics.lines.lastIndex { $0.time <= p } ?? -1
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { i, line in
                                Text(line.text.isEmpty ? "♪" : line.text)
                                    .font(.system(size: 26, weight: .bold))
                                    .foregroundStyle(.white.opacity(i == current ? 1 : 0.35))
                                    .scaleEffect(i == current ? 1.03 : 1, anchor: .leading)
                                    .animation(.easeOut(duration: 0.25), value: current)
                                    .id(i)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 120)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: current) { _, i in withAnimation(.easeInOut(duration: 0.5)) { proxy.scrollTo(i, anchor: .center) } }
                    .onAppear { proxy.scrollTo(max(current, 0), anchor: .center) }
                }
                .mask(LinearGradient(colors: [.clear, .black, .black, .clear], startPoint: .top, endPoint: .bottom))
            }
        } else if let plain = lyrics.plain {
            ScrollView { Text(plain).font(.title3.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading) }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "quote.bubble").font(.largeTitle)
                Text(lyrics.loading ? "Looking for lyrics…" : "No lyrics found for this song").font(.headline)
            }
            .foregroundStyle(.white.opacity(0.6))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Little green level bars that dance while music plays.
struct Equalizer: View {
    let playing: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12, paused: !playing)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<12, id: \.self) { i in
                    Capsule().fill(Color.green)
                        .frame(width: 4, height: playing ? 6 + 14 * abs(sin(t * 3 + Double(i) * 1.3)) : 5)
                }
            }
            .frame(height: 22)
        }
    }
}

struct TimerWidget: View {
    let light: Bool
    @State var total = 60.0      // seconds set with the ticks
    @State var endsAt: Date?     // running
    @State var left: Double?     // paused with this much left
    static let maxSeconds = 3600.0

    func remaining(_ now: Date) -> Double { endsAt.map { max(0, $0.timeIntervalSince(now)) } ?? left ?? total }

    var body: some View {
        Widget(light: light) {
            TimelineView(.periodic(from: .now, by: 0.25)) { tl in
                let r = remaining(tl.date)
                VStack(spacing: 10) {
                    Text(String(format: "%d:%02d", Int(r) / 60, Int(r) % 60))
                        .font(.system(size: 50, weight: .semibold, design: .rounded)).monospacedDigit()
                    // drag along the ticks to set 1–60 minutes
                    GeometryReader { g in
                        let f = r / Self.maxSeconds
                        Canvas { ctx, size in
                            let n = 40
                            for i in 0..<n {
                                let t = Double(i) / Double(n - 1), x = 2 + (size.width - 4) * t
                                var p = Path()
                                p.move(to: CGPoint(x: x, y: size.height * 0.2))
                                p.addLine(to: CGPoint(x: x, y: size.height * (i % 5 == 0 ? 0.9 : 0.65)))
                                ctx.stroke(p, with: .color(t <= f ? .blue : .gray.opacity(0.4)),
                                           style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            }
                        }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                            guard endsAt == nil else { return }
                            let s = max(60, (min(1, max(0, v.location.x / g.size.width)) * 60).rounded() * 60)
                            if s != total { UISelectionFeedbackGenerator().selectionChanged() }
                            total = s
                            left = nil
                        })
                    }
                    .frame(height: 36)
                    HStack(spacing: 24) {
                        Button { endsAt = nil; left = nil } label: { Image(systemName: "arrow.counterclockwise") }
                            .font(.system(size: 18)).foregroundStyle(.gray)
                        Button {
                            if let e = endsAt { left = max(0, e.timeIntervalSinceNow); endsAt = nil }
                            else { endsAt = Date().addingTimeInterval(left ?? total); left = nil }
                        } label: {
                            Image(systemName: endsAt == nil ? "play.fill" : "pause.fill")
                                .font(.system(size: 20, weight: .bold))
                                .frame(width: 48, height: 48)
                                .foregroundStyle(light ? Color.white : Color.black)
                                .background(Circle().fill(light ? Color.black : Color.white))
                        }
                    }
                    .onChange(of: r == 0 && endsAt != nil) { _, done in
                        if done { endsAt = nil; left = 0; UINotificationFeedbackGenerator().notificationOccurred(.success) }
                    }
                }
            }
        }
    }
}

/// Claude Code / Codex on the Mac: working, waiting for you, or idle. Tap to bring its terminal to the front.
struct AgentWidget: View {
    @ObservedObject var client: DropClient
    let agent: AgentStatus
    let light: Bool
    var color: Color { ["working": .orange, "waiting": .green, "idle": .gray][agent.state] ?? .gray.opacity(0.5) }
    var label: String { ["working": "Working…", "waiting": "Waiting for you", "idle": "Idle"][agent.state] ?? "No session" }

    var body: some View {
        Button { client.deckAgentOpen(agent.name == "Codex" ? "codex" : "claude") } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: agent.name == "Codex" ? "chevron.left.forwardslash.chevron.right" : "asterisk")
                        .font(.system(size: 13, weight: .bold))
                    Text(agent.name).font(.subheadline.weight(.semibold))
                    Spacer()
                    Circle().fill(color).frame(width: 9, height: 9)
                        .opacity(agent.state == "working" ? 0.5 : 1)
                        .animation(agent.state == "working" ? .easeInOut(duration: 0.6).repeatForever() : .default, value: agent.state)
                }
                Text(label).font(.caption.weight(.semibold)).foregroundStyle(color)
                if !agent.project.isEmpty { Text(agent.project).font(.caption2).foregroundStyle(.gray).lineLimit(1) }
                Text(agent.text).font(.footnote).lineLimit(6).foregroundStyle(light ? .black.opacity(0.7) : .white.opacity(0.7))
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .foregroundStyle(light ? .black : .white)
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(light ? Color.white : Color.black))
            .shadow(color: .black.opacity(0.25), radius: 12, y: 5)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Creative Pro

/// Tools for the creative app in front on the Mac: shortcut buttons, jog wheels (drag to step), precise sliders, colour.
struct CreativeTools {
    struct Tool { let name, icon, keys: String }
    struct Jog { let name, less, more: String } // keys sent per step left/right
    let tools: [Tool], jogs: [Jog], opacity: Bool, color: Bool

    static let all: [String: CreativeTools] = [
        "photoshop": .init(tools: [.init(name: "Move", icon: "arrow.up.and.down.and.arrow.left.and.right", keys: "v"),
                                   .init(name: "Brush", icon: "paintbrush.pointed", keys: "b"),
                                   .init(name: "Eraser", icon: "eraser", keys: "e"),
                                   .init(name: "Lasso", icon: "lasso", keys: "l"),
                                   .init(name: "Crop", icon: "crop", keys: "c"),
                                   .init(name: "Swap", icon: "arrow.left.arrow.right", keys: "x"),
                                   .init(name: "Undo", icon: "arrow.uturn.backward", keys: "cmd+z"),
                                   .init(name: "Redo", icon: "arrow.uturn.forward", keys: "cmd+shift+z")],
                           jogs: [.init(name: "Brush size", less: "[", more: "]"), .init(name: "Zoom", less: "cmd+-", more: "cmd+=")],
                           opacity: true, color: true),
        "illustrator": .init(tools: [.init(name: "Select", icon: "cursorarrow", keys: "v"),
                                     .init(name: "Direct", icon: "cursorarrow.rays", keys: "a"),
                                     .init(name: "Pen", icon: "pencil.tip", keys: "p"),
                                     .init(name: "Type", icon: "textformat", keys: "t"),
                                     .init(name: "Rectangle", icon: "rectangle", keys: "m"),
                                     .init(name: "Ellipse", icon: "circle", keys: "l"),
                                     .init(name: "Undo", icon: "arrow.uturn.backward", keys: "cmd+z"),
                                     .init(name: "Redo", icon: "arrow.uturn.forward", keys: "cmd+shift+z")],
                             jogs: [.init(name: "Zoom", less: "cmd+-", more: "cmd+="), .init(name: "Nudge", less: "left", more: "right")],
                             opacity: false, color: true),
        "aftereffects": .init(tools: [.init(name: "Select", icon: "cursorarrow", keys: "v"),
                                      .init(name: "Hand", icon: "hand.raised", keys: "h"),
                                      .init(name: "Pen", icon: "pencil.tip", keys: "g"),
                                      .init(name: "Text", icon: "textformat", keys: "cmd+t"),
                                      .init(name: "Play", icon: "play.fill", keys: "space"),
                                      .init(name: "Split", icon: "scissors", keys: "cmd+shift+d"),
                                      .init(name: "Undo", icon: "arrow.uturn.backward", keys: "cmd+z"),
                                      .init(name: "Redo", icon: "arrow.uturn.forward", keys: "cmd+shift+z")],
                              jogs: [.init(name: "Frame", less: "pageup", more: "pagedown"), .init(name: "Timeline zoom", less: "-", more: "=")],
                              opacity: false, color: false),
        "premiere": .init(tools: [.init(name: "Select", icon: "cursorarrow", keys: "v"),
                                  .init(name: "Razor", icon: "scissors", keys: "c"),
                                  .init(name: "Ripple", icon: "arrow.left.and.right", keys: "b"),
                                  .init(name: "Hand", icon: "hand.raised", keys: "h"),
                                  .init(name: "Play", icon: "play.fill", keys: "space"),
                                  .init(name: "Add edit", icon: "plus.rectangle", keys: "cmd+k"),
                                  .init(name: "Undo", icon: "arrow.uturn.backward", keys: "cmd+z"),
                                  .init(name: "Redo", icon: "arrow.uturn.forward", keys: "cmd+shift+z")],
                          jogs: [.init(name: "Frame", less: "left", more: "right"), .init(name: "Timeline zoom", less: "-", more: "=")],
                          opacity: false, color: false),
        "blender": .init(tools: [.init(name: "Grab", icon: "arrow.up.and.down.and.arrow.left.and.right", keys: "g"),
                                 .init(name: "Rotate", icon: "arrow.clockwise", keys: "r"),
                                 .init(name: "Scale", icon: "arrow.up.left.and.arrow.down.right", keys: "s"),
                                 .init(name: "Extrude", icon: "square.stack.3d.up", keys: "e"),
                                 .init(name: "Edit mode", icon: "square.on.square.dashed", keys: "tab"),
                                 .init(name: "Render", icon: "camera.aperture", keys: "f12"),
                                 .init(name: "Undo", icon: "arrow.uturn.backward", keys: "cmd+z"),
                                 .init(name: "Redo", icon: "arrow.uturn.forward", keys: "cmd+shift+z")],
                         jogs: [.init(name: "Frame", less: "left", more: "right")],
                         opacity: false, color: false),
    ]
}

struct DeckCreative: View {
    @ObservedObject var client: DropClient
    @State var color = Color.white
    @State var opacity = 100.0
    let cols = [GridItem(.adaptive(minimum: 84), spacing: 12)]
    static let swatches: [Color] = [.white, .black, .red, .orange, .yellow, .green, .blue, .purple]

    var body: some View {
        if let c = client.creative, let tools = CreativeTools.all[c.key] {
            ScrollView {
                VStack(spacing: 16) {
                    LazyVGrid(columns: cols, spacing: 12) {
                        ForEach(tools.tools, id: \.name) { t in
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                client.deckKeys(t.keys)
                            } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: t.icon).font(.system(size: 20))
                                    Text(t.name).font(.caption2).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity).frame(height: 66)
                                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    ForEach(tools.jogs, id: \.name) { j in JogWheel(jog: j) { client.deckKeys($0) } }
                    if tools.opacity {
                        PanelCard {
                            HStack { Text("Opacity"); Spacer(); Text("\(Int(opacity))%").monospacedDigit() }.font(.subheadline)
                            // Photoshop: typing two digits quickly sets the exact opacity ("4 5" = 45%, "0" = 100%)
                            Slider(value: $opacity, in: 1...100, step: 1) { editing in
                                guard !editing else { return }
                                let v = Int(opacity)
                                client.deckKeys(v == 100 ? "0" : v % 10 == 0 ? "\(v / 10)" : "\(v / 10) \(v % 10)")
                            }
                        }
                    }
                    if tools.color {
                        PanelCard {
                            HStack {
                                Text(c.key == "photoshop" ? "Foreground colour" : "Fill colour").font(.subheadline)
                                Spacer()
                                ColorPicker("", selection: $color, supportsOpacity: false).labelsHidden()
                            }
                            HStack {
                                ForEach(Self.swatches.indices, id: \.self) { i in
                                    Circle().fill(Self.swatches[i]).frame(width: 30, height: 30)
                                        .overlay(Circle().strokeBorder(.white.opacity(0.4)))
                                        .onTapGesture { color = Self.swatches[i] }
                                    if i < Self.swatches.count - 1 { Spacer(minLength: 0) }
                                }
                            }
                        }
                        .onChange(of: color) { _, c in client.deckColor(hex(c)) }
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 60)
                .padding(.top, 70)
                .padding(.bottom, 40)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "paintpalette").font(.system(size: 40))
                Text("Creative Pro").font(.headline)
                Text("Bring Photoshop, Illustrator, After Effects, Premiere Pro or Blender to the front on your Mac and its tools appear here.")
                    .font(.footnote).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.7))
            }
            .foregroundStyle(.white)
            .padding(40)
        }
    }

    func hex(_ c: Color) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a)
        let f = { (v: CGFloat) in Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "%02X%02X%02X", f(r), f(g), f(b))
    }
}

struct PanelCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white.opacity(0.12)))
    }
}

/// A ruler you drag sideways; every 14 pt sends one step (e.g. "]" = bigger brush, "right" = next frame).
struct JogWheel: View {
    let jog: CreativeTools.Jog
    let send: (String) -> Void
    @State var sent = 0
    @State var shift: CGFloat = 0
    static let step: CGFloat = 14

    var body: some View {
        PanelCard {
            HStack {
                Text(jog.name).font(.subheadline)
                Spacer()
                Image(systemName: "chevron.left"); Image(systemName: "chevron.right")
            }
            .foregroundStyle(.white)
            Canvas { ctx, size in
                let off = shift.truncatingRemainder(dividingBy: Self.step * 5)
                var x = off - Self.step * 5
                var i = 0
                while x < size.width + Self.step * 5 {
                    var p = Path()
                    let major = i % 5 == 0
                    p.move(to: CGPoint(x: x, y: size.height * (major ? 0.1 : 0.35)))
                    p.addLine(to: CGPoint(x: x, y: size.height * 0.9))
                    let d = abs(x - size.width / 2) / (size.width / 2)
                    ctx.stroke(p, with: .color(.white.opacity(0.9 - 0.7 * d)), style: StrokeStyle(lineWidth: major ? 3 : 2, lineCap: .round))
                    x += Self.step
                    i += 1
                }
                var mid = Path()
                mid.move(to: CGPoint(x: size.width / 2, y: 0)); mid.addLine(to: CGPoint(x: size.width / 2, y: size.height))
                ctx.stroke(mid, with: .color(Color(red: 0.35, green: 0.7, blue: 1)), lineWidth: 3)
            }
            .frame(height: 44)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                shift = g.translation.width
                let steps = Int(g.translation.width / Self.step)
                while sent < steps { sent += 1; send(jog.more); UISelectionFeedbackGenerator().selectionChanged() }
                while sent > steps { sent -= 1; send(jog.less); UISelectionFeedbackGenerator().selectionChanged() }
            }.onEnded { _ in sent = 0; withAnimation(.spring) { shift = 0 } })
        }
    }
}

// MARK: - Windows

/// Window management: each open app (bring to front, minimise, maximise on a screen) or two apps split 50/50.
struct DeckWindows: View {
    @ObservedObject var client: DropClient
    @State var mode = 0
    @State var picks: [Int: [Int?]] = [:] // screen index → [left pid, right pid]

    var body: some View {
        VStack(spacing: 14) {
            Picker("", selection: $mode) {
                Text("Apps").tag(0)
                Text("Split 50/50").tag(1)
            }
            .pickerStyle(.segmented)
            .frame(width: 280)
            if mode == 0 { appsRow } else { splitRow }
        }
        .padding(.top, 64)
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottom) {
            if let r = client.deckResult {
                Text(r).font(.footnote.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(Capsule().fill(.black.opacity(0.6)))
                    .padding(.bottom, 26)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3), value: client.deckResult)
        .overlay {
            if client.macWindows.isEmpty {
                Text("Loading your Mac’s windows…").font(.footnote).foregroundStyle(.white.opacity(0.6))
            }
        }
        .onAppear { client.deckWindows() }
    }

    // MARK: Apps: one card per open app

    var appsRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 16) {
                ForEach(client.macWindows, id: \.path) { app in appCard(app) }
            }
            .padding(.horizontal, 60)
        }
        .scrollIndicators(.hidden)
    }

    func appCard(_ app: DeckApp) -> some View {
        let pid = Int(app.path) ?? 0
        return VStack(spacing: 10) {
            Button { act("front", pid) } label: {
                VStack(spacing: 6) {
                    if let img = UIImage(data: app.icon) { Image(uiImage: img).resizable().frame(width: 64, height: 64) }
                    Text(app.name).font(.caption.weight(.semibold)).lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            HStack(spacing: 8) {
                circle("arrow.up.forward.app", "Bring to front") { act("front", pid) }
                circle("minus", "Minimize") { act("minimize", pid) }
                if client.macScreens.count > 1 {
                    Menu {
                        ForEach(client.macScreens.indices, id: \.self) { i in
                            Button(client.macScreens[i]) { act("maximize", pid, screen: i) }
                        }
                    } label: { circleLabel("arrow.up.left.and.arrow.down.right") }
                } else {
                    circle("arrow.up.left.and.arrow.down.right", "Maximize") { act("maximize", pid) }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .frame(width: 170, height: 190)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.white.opacity(0.12)))
    }

    func circle(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { circleLabel(icon) }.buttonStyle(.plain).accessibilityLabel(help)
    }
    func circleLabel(_ icon: String) -> some View {
        Image(systemName: icon).font(.system(size: 15, weight: .semibold))
            .frame(width: 40, height: 40)
            .background(Circle().fill(.white.opacity(0.18)))
    }

    func act(_ cmd: String, _ pid: Int, screen: Int = 0) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        client.deckWindow(cmd, pid: pid, screen: screen)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { client.deckWindows() }
    }

    // MARK: Split: each screen as a card split in two

    var splitRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 30) {
                ForEach(client.macScreens.indices, id: \.self) { i in screenCard(i) }
            }
            .padding(.horizontal, 60)
        }
        .scrollIndicators(.hidden)
    }

    func screenCard(_ i: Int) -> some View {
        let p = picks[i] ?? [nil, nil]
        return VStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(0..<2, id: \.self) { half in slot(i, half, p[half]) }
            }
            .padding(6)
            .frame(width: 290, height: 160)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.black.opacity(0.35)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.25)))
            HStack {
                Image(systemName: "display")
                Text(client.macScreens[i]).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    client.deckSplit(p.compactMap { $0 }, screen: i)
                } label: {
                    SwiftUI.Label(p.compactMap { $0 }.count == 1 ? "Fill" : "Split", systemImage: "rectangle.split.2x1")
                }
                .buttonStyle(.borderedProminent)
                .disabled(p.allSatisfy { $0 == nil })
            }
            .foregroundStyle(.white)
            .frame(width: 290)
        }
    }

    /// One half of a screen: tap to choose which open app goes there.
    func slot(_ i: Int, _ half: Int, _ pid: Int?) -> some View {
        let app = client.macWindows.first { $0.path == pid.map(String.init) }
        return Menu {
            ForEach(client.macWindows, id: \.path) { a in
                Button(a.name) { var p = picks[i] ?? [nil, nil]; p[half] = Int(a.path); picks[i] = p }
            }
            if pid != nil { Button("Empty", role: .destructive) { var p = picks[i] ?? [nil, nil]; p[half] = nil; picks[i] = p } }
            Button("Refresh list") { client.deckWindows() }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(app == nil ? 0.08 : 0.18))
                if let app {
                    VStack(spacing: 6) {
                        if let img = UIImage(data: app.icon) { Image(uiImage: img).resizable().frame(width: 48, height: 48) }
                        Text(app.name).font(.caption).lineLimit(1)
                    }
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: "plus").font(.title2)
                        Text(half == 0 ? "Left" : "Right").font(.caption)
                    }
                    .foregroundStyle(.white.opacity(0.6))
                }
            }
            .foregroundStyle(.white)
        }
    }
}
