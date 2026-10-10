import AppKit
import MemoryKit
import SwiftUI

/// The map's state: what it shows (focus, date, kinds), where it looks (viewport), what's under the pointer,
/// and the gentle animations. Lives on `AppState`, so the map is where it was after a detour.
///
/// Drawing happens in one Canvas from cached values (no view per node), so a thousand nodes stay smooth: the
/// graph is cached per brain revision, date, focus and kinds; positions come from the brain's cached layout.
@MainActor
final class BrainMapModel: ObservableObject {
    /// Double-clicked node: only its neighbourhood (2 hops) shows.
    @Published var focusID: UUID?
    /// The time slider: the map as it was at the end of that day (nil = now).
    @Published var asOf: Date?
    @Published var kinds: Set<MapNodeKind> = Set(MapFilter.switchable)
    @Published private(set) var viewport = MapViewport()
    @Published private(set) var hoveredID: UUID?
    @Published private(set) var hoverPoint: CGPoint = .zero
    /// The pointer is over the map (⌘-scroll zooms only then).
    private(set) var pointerInside = false
    /// Bumped when an animation ends, so the timeline pauses.
    @Published private(set) var tick = 0

    private(set) var size: CGSize = .zero
    /// The scale that fits the whole map (zoom 1).
    private(set) var fitScale: Double = 40
    private var fitted = false
    /// The user moved or zoomed the map: a new window size keeps their view instead of fitting again.
    private var userMoved = false
    /// Room the controls take at the top and bottom (fitting keeps nodes out from under them).
    static let topInset: CGFloat = 44, bottomInset: CGFloat = 70
    private var viewportAnimation: (from: MapViewport, to: MapViewport, start: Date)?
    /// When each node started fading in, and nodes that just left (drawn fading out).
    private(set) var appearing: [UUID: Date] = [:]
    private(set) var vanishing: [UUID: (node: MapNode, start: Date)] = [:]
    private var shown: [UUID: MapNode] = [:]
    private var cache: (key: String, graph: MapGraph)?
    private var firstDateCache: (revision: Int, date: Date?)?
    private var animationEnds = Date.distantPast
    /// The graph last drawn (for hit testing in event handlers).
    private(set) var current = MapGraph()

    // MARK: The graph

    /// The graph to draw now (cached), and the nodes that came or went since the last one.
    func graph(_ brain: MemoryBrain) -> MapGraph {
        let kindsKey = kinds.map(\.rawValue).sorted().joined(separator: ",")
        let key = "\(brain.revision)|\(asOf?.timeIntervalSince1970 ?? 0)|\(focusID?.uuidString ?? "-")|\(kindsKey)"
        if let cache, cache.key == key { return cache.graph }
        let raw = brain.map(asOf: asOf, focus: focusID, hops: 2)
        let g = MapFilter.apply(raw, kinds: kinds)
        let now = Date()
        let next = Dictionary(g.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, node) in shown where next[id] == nil { vanishing[id] = (node, now) }
        for id in next.keys where shown[id] == nil {
            appearing[id] = now
            vanishing[id] = nil
        }
        if shown.keys.count != next.keys.count || shown.keys.contains(where: { next[$0] == nil }) || next.keys.contains(where: { shown[$0] == nil }) {
            startAnimation(now)
        }
        shown = next
        cache = (key, g)
        current = g
        // The graph has hiddenByKind for every kind; keep the raw one's (the filter keeps it too).
        return g
    }

    /// The first memory's date (the slider's left end).
    func firstDate(_ library: MemoryLibrary) -> Date? {
        if let c = firstDateCache, c.revision == library.revision { return c.date }
        let d = library.items.map(\.createdAt).min()
        firstDateCache = (library.revision, d)
        return d
    }

    // MARK: Animation

    var isAnimating: Bool { Date() < animationEnds }

    private func startAnimation(_ now: Date) {
        animationEnds = max(animationEnds, now.addingTimeInterval(MapMotion.duration + 0.05))
        DispatchQueue.main.asyncAfter(deadline: .now() + MapMotion.duration + 0.1) { [weak self] in
            guard let self else { return }
            let now = Date()
            self.appearing = self.appearing.filter { now.timeIntervalSince($0.value) < MapMotion.duration }
            self.vanishing = self.vanishing.filter { now.timeIntervalSince($0.value.start) < MapMotion.duration }
            if let a = self.viewportAnimation, now.timeIntervalSince(a.start) >= MapMotion.duration {
                self.viewport = a.to
                self.viewportAnimation = nil
            }
            self.tick &+= 1
        }
    }

    /// The viewport at this moment (mid-animation or settled).
    func viewport(at now: Date) -> MapViewport {
        guard let a = viewportAnimation else { return viewport }
        let t = MapMotion.spring(now.timeIntervalSince(a.start))
        return MapViewport.interpolate(a.from, a.to, t)
    }

    /// How far a node has come in (0…1) and, for one leaving, how far it has gone.
    func presence(_ id: UUID, at now: Date) -> Double {
        if let start = appearing[id] { return MapMotion.spring(now.timeIntervalSince(start)) }
        return 1
    }

    // MARK: Viewport

    var zoom: Double { viewport.scale / max(0.0001, fitScale) }
    private var scaleRange: ClosedRange<Double> { (fitScale * 0.35)...(fitScale * 14) }

    /// The view's size: the first time, fit the map; after that keep the middle where it was.
    func resize(_ new: CGSize, brain: MemoryBrain) {
        guard new.width > 10, new.height > 10 else { return }
        let old = size
        size = new
        if !fitted {
            fitted = true
            fit(brain: brain, animated: false)
        } else if old != new && !userMoved {
            fit(brain: brain, animated: true)
        } else if old != new {
            viewport = viewport.panned(by: CGSize(width: (new.width - old.width) / 2, height: (new.height - old.height) / 2))
            fitScale = MapViewport.fit(brain.map().bounds, in: new, top: Self.topInset, bottom: Self.bottomInset).scale
        }
    }

    /// Everything shown (or the focus's neighbourhood) in view.
    func fit(brain: MemoryBrain, animated: Bool = true) {
        guard size.width > 10 else { return }
        let all = brain.map()
        fitScale = MapViewport.fit(all.bounds, in: size, top: Self.topInset, bottom: Self.bottomInset).scale
        let target = focusID != nil ? graph(brain) : all
        guard !target.isEmpty else { return }
        userMoved = false
        set(MapViewport.fit(target.bounds, in: size, padding: focusID != nil ? 90 : 56, top: Self.topInset, bottom: Self.bottomInset),
            animated: animated)
    }

    func zoom(by factor: Double, about anchor: CGPoint? = nil, animated: Bool = false) {
        let point = anchor ?? CGPoint(x: size.width / 2, y: size.height / 2)
        userMoved = true
        set(viewport(at: Date()).zoomed(by: factor, about: point, range: scaleRange), animated: animated)
    }

    func pan(to v: MapViewport) {
        userMoved = true
        set(v, animated: false)
    }

    private func set(_ v: MapViewport, animated: Bool) {
        if animated {
            viewportAnimation = (viewport(at: Date()), v, Date())
            viewport = v
            startAnimation(Date())
        } else {
            viewportAnimation = nil
            viewport = v
        }
    }

    // MARK: Focus and hover

    func focus(_ id: UUID, brain: MemoryBrain) {
        focusID = id
        hoveredID = nil
        fit(brain: brain)
    }

    func showAll(brain: MemoryBrain) {
        focusID = nil
        fit(brain: brain)
    }

    /// Where the pointer is (nil when it left); finds the node under it.
    func hover(_ point: CGPoint?) {
        pointerInside = point != nil
        guard let point else {
            if hoveredID != nil { hoveredID = nil }
            return
        }
        hoverPoint = point
        let id = node(at: point)
        if id != hoveredID { hoveredID = id }
    }

    func node(at point: CGPoint) -> UUID? {
        let v = viewport(at: Date())
        let z = zoom
        return MapGeometry.hit(point, nodes: current.nodes.map { n in
            (n.id, v.toScreen(n.position), MapGeometry.radius(kind: n.kind, size: n.size, zoom: z))
        })
    }

    /// Screenshots: the map fitted again for a new window size.
    func refit() { fitted = false }
}

// MARK: - The map

/// The mental map: areas, topics, people, organisations and projects as dots coloured by area and sized by
/// how much is behind them, linked by hairlines. Drag to move, pinch or ⌘-scroll to zoom; hover shows a node's
/// neighbours, a click opens its page on the right, a double-click shows only its neighbourhood. The slider
/// at the bottom goes back in time (nodes keep their places).
struct BrainMapView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var brain = MemoryCenter.shared.brain
    @ObservedObject private var library = MemoryCenter.shared.library
    @ObservedObject var model: BrainMapModel
    @Environment(\.colorScheme) private var scheme
    @State private var dragStart: MapViewport?
    @State private var pinchStart: MapViewport?
    @State private var scrollMonitor: Any?

    var body: some View {
        let graph = model.graph(brain)
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if graph.isEmpty && model.vanishing.isEmpty {
                    EmptyState(icon: "point.3.connected.trianglepath.dotted", title: emptyTitle,
                               message: "Topics, people and \(library.vocabulary.projects.lowercased()) show up here once Docket has organised your memory.")
                } else {
                    canvas(graph)
                        .gesture(dragGesture)
                        .simultaneousGesture(pinchGesture)
                        .simultaneousGesture(tapGesture)
                        .onContinuousHover(coordinateSpace: .local) { phase in
                            switch phase {
                            case .active(let p): model.hover(p)
                            case .ended: model.hover(nil)
                            }
                        }
                    tooltip(in: geo.size)
                }
                VStack(spacing: 0) {
                    topBar(graph)
                    Spacer(minLength: 0)
                    bottomBar
                }
            }
            .onAppear {
                model.resize(geo.size, brain: brain)
                installScrollMonitor()
            }
            .onDisappear(perform: removeScrollMonitor)
            .onChange(of: geo.size) { model.resize($0, brain: brain) }
        }
        .background(Color.paper)
        .clipped()
    }

    private var emptyTitle: String { model.asOf != nil ? "Nothing yet by then" : "Nothing on the map yet" }

    // MARK: Drawing

    private func canvas(_ graph: MapGraph) -> some View {
        let ink = MapInk(dark: scheme == .dark)
        let slots = BrainPalette.slots(for: brain.areas().map(\.id))
        let hovered = model.hoveredID
        let neighbours: Set<UUID> = hovered.map { graph.neighbourhood(of: $0, hops: 1) } ?? []
        let selected = app.selectedEntityID
        let animating = model.isAnimating
        return TimelineView(.animation(minimumInterval: 1 / 60, paused: !animating)) { timeline in
            Canvas(rendersAsynchronously: false) { ctx, size in
                let now = timeline.date
                let v = model.viewport(at: now)
                let zoom = v.scale / max(0.0001, model.fitScale)
                func color(_ n: MapNode) -> Color {
                    guard let area = n.areaID, let slot = slots[area] else { return ink.ink3 }
                    return Color(nsColor: NSColor(hex: BrainPalette.hex(slot: slot, dark: ink.dark)))
                }
                var points: [UUID: CGPoint] = [:]
                var presence: [UUID: Double] = [:]
                for n in graph.nodes {
                    points[n.id] = v.toScreen(n.position)
                    presence[n.id] = model.presence(n.id, at: now)
                }
                let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -40, dy: -40)

                // Edges: hairlines, stronger links darker; batched into a few paths by opacity.
                var buckets = [Path](repeating: Path(), count: 6)
                var lit = Path()
                for e in graph.edges {
                    guard let a = points[e.a], let b = points[e.b] else { continue }
                    guard bounds.contains(a) || bounds.contains(b) else { continue }
                    if hovered != nil && (e.a == hovered || e.b == hovered) {
                        lit.move(to: a); lit.addLine(to: b)
                        continue
                    }
                    let w = e.kind == .hierarchy ? 0.55 : e.weight
                    let k = min(5, Int((w * 6).rounded(.down)))
                    buckets[k].move(to: a); buckets[k].addLine(to: b)
                }
                let edgeDim = hovered == nil ? 1.0 : 0.35
                for (k, path) in buckets.enumerated() where !path.isEmpty {
                    let alpha = (0.10 + Double(k) * 0.07) * edgeDim
                    ctx.stroke(path, with: .color(ink.ink.opacity(alpha)), lineWidth: 0.75)
                }
                if !lit.isEmpty { ctx.stroke(lit, with: .color(ink.ink.opacity(0.55)), lineWidth: 1.1) }

                // Nodes leaving fade out where they were.
                for (_, gone) in model.vanishing {
                    let t = 1 - MapMotion.spring(now.timeIntervalSince(gone.start))
                    guard t > 0.01 else { continue }
                    let p = v.toScreen(gone.node.position)
                    let r = MapGeometry.radius(kind: gone.node.kind, size: gone.node.size, zoom: zoom) * CGFloat(0.6 + 0.4 * t)
                    drawNode(&ctx, gone.node, at: p, radius: r, color: color(gone.node), ink: ink, alpha: t * 0.8)
                }

                // Nodes: big ones first, so small ones sit on top.
                let order = graph.nodes.sorted { a, b in
                    let ra = MapGeometry.radius(kind: a.kind, size: a.size, zoom: 1), rb = MapGeometry.radius(kind: b.kind, size: b.size, zoom: 1)
                    return ra != rb ? ra > rb : a.id.uuidString < b.id.uuidString
                }
                var candidates: [MapLabels.Candidate] = []
                for n in order {
                    guard let p = points[n.id] else { continue }
                    let s = presence[n.id] ?? 1
                    let r = MapGeometry.radius(kind: n.kind, size: n.size, zoom: zoom) * CGFloat(0.4 + 0.6 * s)
                    guard bounds.insetBy(dx: -r, dy: -r).contains(p) else { continue }
                    let dim = hovered != nil && !neighbours.contains(n.id)
                    drawNode(&ctx, n, at: p, radius: r, color: color(n), ink: ink, alpha: s * (dim ? 0.25 : 1))
                    if n.id == selected || n.id == graph.focus {
                        let ring = CGRect(x: p.x - r - 3.5, y: p.y - r - 3.5, width: (r + 3.5) * 2, height: (r + 3.5) * 2)
                        ctx.stroke(Circle().path(in: ring), with: .color(ink.ink.opacity(0.85 * s)), lineWidth: 1.5)
                    }
                    let font = MapInk.labelSize(n.kind)
                    let text = n.kind == .area ? n.name.uppercased() : n.name
                    let priority = (n.kind == .area ? 10_000 : n.kind == .topic ? 1_000 : 0) + Double(n.size)
                    candidates.append(.init(id: n.id, center: p, radius: r,
                                            size: CGSize(width: MapLabels.estimatedWidth(text, fontSize: font) * (n.kind == .area ? 1.15 : 1),
                                                         height: font + 4),
                                            priority: priority))
                }

                // Labels that fit (the hovered node and its neighbours first).
                var always: Set<UUID> = []
                if let hovered { always = neighbours.count <= 12 ? neighbours : [hovered] }
                if let selected { always.insert(selected) }
                if let f = graph.focus { always.insert(f) }
                let shown = MapLabels.visible(candidates, in: CGRect(origin: .zero, size: size), always: always,
                                              limit: MapLabels.limit(for: size, zoom: zoom))
                let byID = Dictionary(graph.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                for c in candidates where shown.contains(c.id) {
                    guard let n = byID[c.id] else { continue }
                    let dim = hovered != nil && !neighbours.contains(n.id)
                    let s = presence[n.id] ?? 1
                    let label = Text(n.kind == .area ? n.name.uppercased() : n.name)
                        .font(.system(size: MapInk.labelSize(n.kind), weight: n.kind == .area ? .bold : n.kind == .topic ? .semibold : .medium))
                        .tracking(n.kind == .area ? 1.2 : 0)
                        .foregroundColor(n.kind == .topic || n.id == hovered ? ink.ink : ink.ink2)
                    let rect = MapLabels.rect(c)
                    var layer = ctx
                    layer.opacity = s * (dim ? 0.3 : 1)
                    let resolved = layer.resolve(label)
                    let measured = resolved.measure(in: CGSize(width: 220, height: 40))
                    let halo = CGRect(x: c.center.x - measured.width / 2 - 3, y: rect.minY - 1, width: measured.width + 6, height: measured.height + 2)
                    layer.fill(RoundedRectangle(cornerRadius: 4, style: .continuous).path(in: halo), with: .color(ink.paper.opacity(0.78)))
                    layer.draw(resolved, at: CGPoint(x: c.center.x, y: rect.minY), anchor: .top)
                }
            }
        }
    }

    /// One node: topics and areas filled with their area's colour, people as rings, organisations as rounded
    /// squares, projects as diamonds (all in the area's colour).
    private func drawNode(_ ctx: inout GraphicsContext, _ n: MapNode, at p: CGPoint, radius r: CGFloat, color: Color,
                          ink: MapInk, alpha: Double) {
        let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
        switch n.kind {
        case .area:
            ctx.fill(Circle().path(in: rect), with: .color(color.opacity(0.18 * alpha)))
            ctx.stroke(Circle().path(in: rect), with: .color(color.opacity(0.9 * alpha)), lineWidth: 1.25)
        case .topic, .item:
            ctx.fill(Circle().path(in: rect), with: .color(color.opacity(0.92 * alpha)))
        case .person:
            ctx.fill(Circle().path(in: rect), with: .color(ink.paper.opacity(alpha)))
            ctx.stroke(Circle().path(in: rect.insetBy(dx: 0.75, dy: 0.75)), with: .color(color.opacity(alpha)), lineWidth: 1.5)
        case .organisation:
            let path = RoundedRectangle(cornerRadius: r * 0.35, style: .continuous).path(in: rect.insetBy(dx: r * 0.08, dy: r * 0.08))
            ctx.fill(path, with: .color(ink.paper.opacity(alpha)))
            ctx.stroke(path, with: .color(color.opacity(alpha)), lineWidth: 1.5)
        case .project:
            var d = Path()
            d.move(to: CGPoint(x: p.x, y: p.y - r * 1.1))
            d.addLine(to: CGPoint(x: p.x + r * 1.1, y: p.y))
            d.addLine(to: CGPoint(x: p.x, y: p.y + r * 1.1))
            d.addLine(to: CGPoint(x: p.x - r * 1.1, y: p.y))
            d.closeSubpath()
            ctx.fill(d, with: .color(ink.paper.opacity(alpha)))
            ctx.stroke(d, with: .color(color.opacity(alpha)), lineWidth: 1.5)
        }
    }

    // MARK: Hover

    @ViewBuilder
    private func tooltip(in size: CGSize) -> some View {
        if let id = model.hoveredID, let n = model.current.node(id) {
            let p = model.hoverPoint
            let leftSide = p.x > size.width - 220
            VStack(alignment: .leading, spacing: 2) {
                Text(n.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                Text(tooltipLine(n))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.ink2)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Color.raised))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).strokeBorder(Color.hairStrong))
            .fixedSize()
            .offset(x: leftSide ? -(size.width - p.x + 14) : p.x + 14, y: p.y + 14)
            .frame(width: size.width, height: size.height, alignment: leftSide ? .topTrailing : .topLeading)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    /// "Topic · 12 memories" (in the lens's words).
    private func tooltipLine(_ n: MapNode) -> String {
        let kind = brain.entity(n.id)?.kind.label(library.vocabulary) ?? "Memory"
        return "\(kind) · \(BrainText.memories(n.size))"
    }

    // MARK: Gestures

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                let start = dragStart ?? model.viewport(at: Date())
                if dragStart == nil { dragStart = start }
                model.pan(to: start.panned(by: value.translation))
                model.hover(value.location)
            }
            .onEnded { _ in dragStart = nil }
    }

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let start = pinchStart ?? model.viewport(at: Date())
                if pinchStart == nil { pinchStart = start }
                let anchor = model.pointerInside ? model.hoverPoint : CGPoint(x: model.size.width / 2, y: model.size.height / 2)
                let range = (model.fitScale * 0.35)...(model.fitScale * 14)
                model.pan(to: start.zoomed(by: Double(value), about: anchor, range: range))
            }
            .onEnded { _ in pinchStart = nil }
    }

    private var tapGesture: some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { value in
                guard let id = model.node(at: value.location) else { return }
                withAnimation(Motion.gentle) { model.focus(id, brain: brain) }
            }
            .exclusively(before: SpatialTapGesture(count: 1).onEnded { value in
                let id = model.node(at: value.location)
                withAnimation(Motion.sheet) { app.selectedEntityID = id.flatMap { brain.entity($0) != nil ? $0 : nil } }
            })
    }

    /// Two-finger scrolling moves the map; with ⌘ (or a mouse wheel with ⌘) it zooms about the pointer.
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        let model = model
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard model.pointerInside, event.window?.isKeyWindow ?? true else { return event }
            let dy = Double(event.scrollingDeltaY), dx = Double(event.scrollingDeltaX)
            let scale: Double = event.hasPreciseScrollingDeltas ? 1 : 8
            if event.modifierFlags.contains(.command) {
                model.zoom(by: exp(dy * scale * 0.006), about: model.hoverPoint)
            } else {
                let v = model.viewport(at: Date())
                model.pan(to: v.panned(by: CGSize(width: dx * scale, height: dy * scale)))
            }
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }

    // MARK: Controls

    /// Kinds to show (lens words), "+ N more", and the way back from a focus.
    private func topBar(_ graph: MapGraph) -> some View {
        let vocabulary = library.vocabulary
        return HStack(spacing: 6) {
            ForEach(MapFilter.switchable, id: \.self) { kind in
                let on = model.kinds.contains(kind)
                MemoryChip(title: MapFilter.label(kind, vocabulary), isOn: on,
                           help: on ? "Hide \(MapFilter.label(kind, vocabulary).lowercased())" : "Show \(MapFilter.label(kind, vocabulary).lowercased())") {
                    withAnimation(Motion.snappy) {
                        if on { model.kinds.remove(kind) } else { model.kinds.insert(kind) }
                    }
                }
            }
            let more = MapFilter.hiddenCount(graph, kinds: model.kinds)
            if more > 0 && model.focusID == nil {
                Text("+ \(more) more")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.ink3)
                    .padding(.leading, 4)
                    .help("The smallest ones are left out to keep the map readable. Zoom into a page from Topics to see them.")
            }
            Spacer(minLength: Space.sm)
            if let id = model.focusID, let e = brain.entity(id) {
                Text("Around \(e.name)")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.ink2)
                    .lineLimit(1)
                MemoryChip(title: "Show all", icon: "arrow.up.left.and.arrow.down.right", isOn: true, help: "Show the whole map again") {
                    withAnimation(Motion.gentle) { model.showAll(brain: brain) }
                }
            }
        }
        .padding(.horizontal, Space.gutter)
        .padding(.top, Space.xs)
        .padding(.bottom, Space.sm)
        .background(LinearGradient(colors: [Color.paper, Color.paper.opacity(0)], startPoint: .top, endPoint: .bottom).allowsHitTesting(false))
    }

    /// The time slider (first memory … now, real dates) and zoom.
    private var bottomBar: some View {
        HStack(spacing: Space.md) {
            if let first = model.firstDate(library), first < app.clock.addingTimeInterval(-86_400) {
                timeSlider(first: first)
            } else {
                Spacer(minLength: 0)
            }
            HStack(spacing: 2) {
                Button { model.zoom(by: 1 / 1.4, animated: true) } label: { Image(systemName: "minus") }
                    .buttonStyle(IconButtonStyle(size: 28))
                    .help("Zoom out (⌘-scroll or pinch)")
                Button { model.zoom(by: 1.4, animated: true) } label: { Image(systemName: "plus") }
                    .buttonStyle(IconButtonStyle(size: 28))
                    .help("Zoom in")
                Button { model.fit(brain: brain) } label: { Image(systemName: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left") }
                    .buttonStyle(IconButtonStyle(size: 28))
                    .help("Fit the map")
            }
        }
        .padding(.horizontal, Space.md)
        .frame(height: 44)
        .background(Capsule().fill(Color.card))
        .overlay(Capsule().strokeBorder(Color.hair))
        .padding(.horizontal, Space.gutter)
        .padding(.bottom, Space.lg)
    }

    private func timeSlider(first: Date) -> some View {
        let now = app.clock
        let fraction = Binding<Double>(
            get: { MapTime.fraction(of: model.asOf, first: first, now: now) },
            set: { model.asOf = MapTime.date(at: $0, first: first, now: now) }
        )
        return HStack(spacing: Space.sm) {
            Text(MemoryText.date(first, now: now))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.ink3)
                .monospacedDigit()
                .fixedSize()
            Slider(value: fraction, in: 0...1)
                .controlSize(.small)
                .tint(Color.ink)
                .help("Go back in time: the map as it was then")
            if let asOf = model.asOf {
                Text(MemoryText.date(asOf, now: now))
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(Color.ink)
                    .monospacedDigit()
                    .fixedSize()
                Button("Today") { withAnimation(Motion.gentle) { model.asOf = nil } }
                    .buttonStyle(SecondaryPill(height: 24))
                    .help("Back to now")
            } else {
                Text(MemoryText.date(now, now: now))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.ink3)
                    .monospacedDigit()
                    .fixedSize()
            }
        }
    }
}

/// The map's ink and paper for the current appearance (Canvas draws with fixed colours, so it picks them here).
struct MapInk {
    let dark: Bool

    var paper: Color { Color(nsColor: NSColor(hex: dark ? 0x0E0E0C : 0xFBFBF9)) }
    var ink: Color { Color(nsColor: NSColor(hex: dark ? 0xE3E3E2 : 0x0E0E0C)) }
    var ink2: Color { Color(nsColor: NSColor(hex: dark ? 0x9A9A99 : 0x5B5B56)) }
    var ink3: Color { Color(nsColor: NSColor(hex: dark ? 0x6E6E6B : 0xA3A39E)) }

    static func labelSize(_ kind: MapNodeKind) -> CGFloat {
        switch kind {
        case .area: 10
        case .topic: 11.5
        default: 10.5
        }
    }
}
