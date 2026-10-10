import MemoryKit
import SwiftUI

/// Memory → Map: the mental map the Mac laid out (areas as anchors, topics, people, organisations,
/// projects), drawn in one Canvas. Pinch and drag; tap a node for its card (Open page, Focus); kind chips;
/// a time slider with real dates. Positions come from the Mac and never move.
struct BrainMapView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.memoryPush) private var push

    @State private var display = MapDisplay()
    @State private var camera = MapCamera()
    @State private var fitScale: CGFloat = 1
    @State private var viewSize: CGSize = .zero
    @State private var hiddenKinds: Set<MapNodeKind> = []
    @State private var focus: UUID?
    @State private var selected: UUID?
    /// Days since the first node's day; nil = now (everything).
    @State private var day: Double?
    @State private var dragBase: CGPoint?
    @State private var pinchBase: MapCamera?
    @State private var animation: Task<Void, Never>?
    @State private var didFit = false
    @State private var pendingZoom: Double?

    private static let topInset: CGFloat = 64
    private static let bottomInset: CGFloat = 132

    var body: some View {
        if let brain = model.brain, !brain.map.isEmpty {
            GeometryReader { geo in
                ZStack {
                    Color.paper
                    canvas
                        .contentShape(Rectangle())
                        .gesture(drag.simultaneously(with: magnify))
                        .onTapGesture(coordinateSpace: .local) { tap(at: $0) }
                }
                .onAppear {
                    viewSize = geo.size
                    applyDemoOptions(brain)
                    rebuild()
                    fitIfNeeded()
                }
                .onChange(of: geo.size) { _, size in viewSize = size; fit(animated: false) }
            }
            .overlay(alignment: .top) { topBar(brain) }
            .overlay(alignment: .bottom) { bottomPanel(brain) }
            .onChange(of: model.snapshot?.generatedAt) { _, _ in rebuild() }
            .onChange(of: hiddenKinds) { _, _ in rebuild() }
            .onChange(of: day) { _, _ in rebuild() }
            .onChange(of: focus) { _, _ in
                rebuild()
                fit(animated: true)
            }
        } else {
            VStack(alignment: .leading, spacing: Space.md) {
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 28)).foregroundStyle(Color.ink3)
                Text("Your map comes from your Mac").textStyle(.title3).foregroundStyle(Color.ink)
                Text("Once your Mac has organised your memory into topics, the map of how they connect shows up here.")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Space.gutter)
            .padding(.top, Space.x4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .paperBackground()
        }
    }

    // MARK: Canvas

    private var canvas: some View {
        let display = display, camera = camera, zoom = camera.scale / max(fitScale, 0.0001)
        let selected = selected, focus = focus
        let timing = model.demoMapTiming
        return Canvas(rendersAsynchronously: false) { ctx, size in
            let start = timing ? CFAbsoluteTimeGetCurrent() : 0
            MapRenderer.draw(display, camera: camera, zoom: zoom, selected: selected, focus: focus, in: &ctx, size: size)
            if timing {
                NSLog("DocketMap draw: %d nodes, %d edges, zoom %.2f, %.2f ms", display.nodes.count, display.edges.count,
                      Double(zoom), (CFAbsoluteTimeGetCurrent() - start) * 1000)
            }
        }
        .accessibilityLabel("Map of your memory")
    }

    // MARK: Gestures

    private var drag: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { v in
                guard pinchBase == nil else { return }
                animation?.cancel()
                if dragBase == nil { dragBase = CGPoint(x: camera.offset.x - v.translation.width, y: camera.offset.y - v.translation.height) }
                guard let base = dragBase else { return }
                camera.offset = CGPoint(x: base.x + v.translation.width, y: base.y + v.translation.height)
            }
            .onEnded { _ in dragBase = nil }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                animation?.cancel()
                if pinchBase == nil { pinchBase = camera }
                guard let base = pinchBase else { return }
                let s = min(max(base.scale * v.magnification, fitScale * 0.5), fitScale * 10)
                let a = v.startLocation
                let k = s / base.scale
                camera = MapCamera(scale: s, offset: CGPoint(x: a.x - (a.x - base.offset.x) * k, y: a.y - (a.y - base.offset.y) * k))
            }
            .onEnded { _ in
                pinchBase = nil
                dragBase = nil
            }
    }

    private func tap(at point: CGPoint) {
        let zoom = camera.scale / max(fitScale, 0.0001)
        let hit = MapRenderer.hit(display, camera: camera, zoom: zoom, at: point)
        withAnimation(Motion.snappy) { selected = hit }
        if hit != nil { Haptics.tap() }
    }

    // MARK: Building and fitting

    private func rebuild() {
        guard let brain = model.brain else { return }
        display = MapDisplay(brain: brain, items: model.snapshot?.items ?? [], focus: focus, asOf: asOfDate(brain),
                             hidden: hiddenKinds)
        if let selected, display.index[selected] == nil { self.selected = nil }
    }

    private func applyDemoOptions(_ brain: BrainSnapshot) {
        guard !didFit else { return }
        if let name = model.demoMapFocus { focus = model.demoEntity(name)?.id }
        if let name = model.demoMapSelect { selected = model.demoEntity(name)?.id }
        if let z = model.demoMapZoom { pendingZoom = z }
        if let back = model.demoMapDaysBack {
            let steps = daySteps(brain)
            let cutoff = Calendar.current.date(byAdding: .day, value: -back, to: brain.generatedAt) ?? brain.generatedAt
            if let i = steps.lastIndex(where: { $0 <= cutoff }), i < steps.count - 1 { day = Double(i) }
        }
    }

    private func fitIfNeeded() {
        guard !didFit, viewSize.width > 0 else { return }
        didFit = true
        fit(animated: false)
        if let z = pendingZoom {
            pendingZoom = nil
            let c = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
            let k = CGFloat(z)
            camera = MapCamera(scale: camera.scale * k, offset: CGPoint(x: c.x - (c.x - camera.offset.x) * k, y: c.y - (c.y - camera.offset.y) * k))
        }
    }

    /// Fits the visible nodes (or, focused, the neighbourhood) between the chips and the slider.
    private func fit(animated: Bool) {
        guard viewSize.width > 0, let brain = model.brain else { return }
        let whole = MapDisplay.bounds(of: brain.map.nodes.map(\.position))
        let target = MapDisplay.bounds(of: display.nodes.map(\.world))
        let area = CGRect(x: 20, y: Self.topInset + 16, width: viewSize.width - 40,
                          height: max(120, viewSize.height - Self.topInset - Self.bottomInset - 40))
        fitScale = MapCamera.fitting(whole, in: area).scale
        var cam = MapCamera.fitting(target, in: area)
        cam.scale = min(cam.scale, fitScale * 3)
        cam = MapCamera.centered(target, scale: cam.scale, in: area)
        if animated { animate(to: cam) } else { camera = cam }
    }

    private func animate(to target: MapCamera) {
        animation?.cancel()
        let from = camera
        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        animation = Task { @MainActor in
            let start = Date()
            while !Task.isCancelled {
                let t = min(1, Date().timeIntervalSince(start) / 0.38)
                camera = from.mix(target, 1 - pow(1 - t, 3), center: center)
                if t >= 1 { break }
                try? await Task.sleep(nanoseconds: 8_000_000)
            }
        }
    }

    // MARK: Time

    /// The days something first appeared on the map (oldest first), ending with the snapshot's day: the
    /// slider steps through these, so every step changes the picture.
    private func daySteps(_ brain: BrainSnapshot) -> [Date] {
        let cal = Calendar.current
        let last = cal.startOfDay(for: brain.generatedAt)
        let days = Set(brain.map.nodes.compactMap { $0.firstSeen.map { cal.startOfDay(for: $0) } }.filter { $0 < last })
        return days.sorted() + [last]
    }

    private func asOfDate(_ brain: BrainSnapshot) -> Date? {
        guard let day else { return nil }
        let steps = daySteps(brain)
        let i = Int(day)
        guard i >= 0, i < steps.count - 1 else { return nil }
        return Calendar.current.date(byAdding: DateComponents(day: 1, second: -1), to: steps[i])
    }

    // MARK: Chrome

    private func topBar(_ brain: BrainSnapshot) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if let focus, let node = brain.map.node(focus) {
                HStack(spacing: Space.sm) {
                    Image(systemName: "scope").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.ink2)
                    Text("Around \(node.name)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                    Spacer(minLength: Space.sm)
                    Button("Show all") {
                        Haptics.select()
                        self.focus = nil
                    }
                    .buttonStyle(SecondaryPill(height: 32))
                }
                .padding(.leading, Space.md)
                .padding(.trailing, 6)
                .frame(height: 44)
                .background(Capsule().fill(Color.card))
                .overlay(Capsule().strokeBorder(Color.hair, lineWidth: 1))
                .padding(.horizontal, Space.gutter)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.sm) {
                        ForEach(filterKinds(brain), id: \.self) { kind in
                            MapKindChip(title: title(kind), color: kind == .topic ? nil : Color.ink2, kind: kind,
                                        on: !hiddenKinds.contains(kind)) {
                                Haptics.select()
                                if hiddenKinds.contains(kind) { hiddenKinds.remove(kind) } else { hiddenKinds.insert(kind) }
                            }
                        }
                    }
                    .padding(.horizontal, Space.gutter)
                }
            }
        }
        .padding(.top, Space.sm)
    }

    private func filterKinds(_ brain: BrainSnapshot) -> [MapNodeKind] {
        let present = Set(brain.map.nodes.map(\.kind))
        return [.topic, .person, .organisation, .project].filter(present.contains)
    }

    private func title(_ kind: MapNodeKind) -> String {
        switch kind {
        case .topic: "Topics"
        case .person: model.vocabulary.people
        case .organisation: "Organisations"
        case .project: model.vocabulary.projects
        case .area: "Areas"
        case .item: "Memories"
        }
    }

    @ViewBuilder
    private func bottomPanel(_ brain: BrainSnapshot) -> some View {
        VStack(spacing: Space.sm) {
            if let selected, let node = display.node(selected) { NodeCard(node: node, brain: brain, focused: focus == selected,
                                                                          open: { open(node) }, focus: { focusOn(node) },
                                                                          close: { withAnimation(Motion.snappy) { self.selected = nil } })
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            timePanel(brain)
        }
        .padding(.horizontal, Space.md)
        .padding(.bottom, Space.sm)
    }

    private func timePanel(_ brain: BrainSnapshot) -> some View {
        let steps = daySteps(brain)
        let lastStep = Double(steps.count - 1)
        let value = Binding<Double>(get: { day ?? lastStep }, set: { day = $0 >= lastStep ? nil : $0.rounded() })
        let shown = steps[min(steps.count - 1, max(0, Int(value.wrappedValue)))]
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(day == nil ? "Everything up to \(PhoneFmt.day(brain.generatedAt))" : "As it was on \(PhoneFmt.day(shown))")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .contentTransition(.numericText())
                Spacer(minLength: Space.sm)
                Text(countLine(brain))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.ink3)
                    .monospacedDigit()
            }
            if steps.count > 1 {
                Slider(value: value, in: 0...lastStep, step: 1) {
                    Text("Date")
                } minimumValueLabel: {
                    Text(PhoneFmt.shortDay(steps[0])).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.ink3)
                } maximumValueLabel: {
                    Text(PhoneFmt.shortDay(brain.generatedAt)).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.ink3)
                }
                .tint(Color.ink)
                .onChange(of: day) { _, _ in Haptics.select() }
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .background(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).fill(Color.card.opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(Color.hair, lineWidth: 1))
    }

    private func countLine(_ brain: BrainSnapshot) -> String {
        let shown = display.nodes.filter { $0.kind != .area }.count
        let hidden = focus == nil && day == nil && hiddenKinds.isEmpty ? brain.map.hiddenCount : 0
        return hidden > 0 ? "\(shown) shown · \(hidden) more on your Mac" : PhoneFmt.count(shown, "thing")
    }

    private func open(_ node: MapDisplay.Node) {
        Haptics.tap()
        push(.entity(node.id))
    }

    private func focusOn(_ node: MapDisplay.Node) {
        Haptics.select()
        withAnimation(Motion.snappy) {
            selected = nil
            focus = node.id
        }
    }
}

// MARK: - Node card

/// The tapped node: name, kind, area, count, last seen; Open page (primary) and Focus.
private struct NodeCard: View {
    let node: MapDisplay.Node
    let brain: BrainSnapshot
    let focused: Bool
    let open: () -> Void
    let focus: () -> Void
    let close: () -> Void
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .top, spacing: Space.sm) {
                Circle().fill(Color(uiColor: node.color)).frame(width: 10, height: 10).padding(.top, 7)
                VStack(alignment: .leading, spacing: 3) {
                    Text(node.name)
                        .font(.system(size: 18, weight: .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(Color.ink)
                        .lineLimit(2)
                    Text(meta)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.ink3)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle(size: 30))
                    .accessibilityLabel("Close")
            }
            HStack(spacing: Space.sm) {
                Button("Open page", action: open).buttonStyle(PrimaryPill(height: 40))
                if !focused { Button("Focus", action: focus).buttonStyle(SecondaryPill(height: 40)) }
            }
        }
        .padding(Space.lg)
        .background(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).fill(Color.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(Color.hair, lineWidth: 1))
        .floatShadow()
    }

    private var meta: String {
        let entity = brain.entity(node.id)
        var parts = [entity?.kind.label(model.vocabulary) ?? node.kind.rawValue.capitalized]
        if node.kind != .area, let area = node.areaID.flatMap(brain.entity) { parts.append(area.name) }
        parts.append(BrainText.memories(entity?.itemCount ?? node.size))
        if let last = entity?.lastSeen { parts.append("last seen \(PhoneFmt.day(last))") }
        return parts.joined(separator: " · ")
    }
}

/// A map filter chip: on = filled ink, off = outline; shows the kind's mark.
private struct MapKindChip: View {
    let title: String
    let color: Color?
    let kind: MapNodeKind
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                MapKindMark(kind: kind).frame(width: 9, height: 9).foregroundStyle(on ? Color.ink : Color.ink3)
                Text(title).lineLimit(1).strikethrough(!on, color: Color.ink3)
            }
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(on ? Color.ink : Color.ink3)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Capsule().fill(on ? Color.fill : Color.paper.opacity(0.9)))
            .overlay(Capsule().strokeBorder(on ? Color.clear : Color.hairStrong, lineWidth: 1))
            .fixedSize()
        }
        .buttonStyle(PressScale(scale: 0.95))
    }
}

/// The shape a kind has on the map (topic: dot, person: ring, organisation: square, project: diamond).
private struct MapKindMark: View {
    let kind: MapNodeKind

    var body: some View {
        switch kind {
        case .person: Circle().strokeBorder(lineWidth: 1.6)
        case .organisation: RoundedRectangle(cornerRadius: 2).strokeBorder(lineWidth: 1.6)
        case .project: Rectangle().strokeBorder(lineWidth: 1.6).rotationEffect(.degrees(45)).scaleEffect(0.8)
        default: Circle()
        }
    }
}

// MARK: - Camera

/// screen = world × scale + offset.
struct MapCamera: Equatable {
    var scale: CGFloat = 1
    var offset: CGPoint = .zero

    func screen(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: CGFloat(x) * scale + offset.x, y: CGFloat(y) * scale + offset.y)
    }

    /// Part way to `other`: scale geometrically, the world point under `center` linearly.
    func mix(_ other: MapCamera, _ t: CGFloat, center c: CGPoint) -> MapCamera {
        let s = scale * pow(other.scale / scale, t)
        let a = CGPoint(x: (c.x - offset.x) / scale, y: (c.y - offset.y) / scale)
        let b = CGPoint(x: (c.x - other.offset.x) / other.scale, y: (c.y - other.offset.y) / other.scale)
        let w = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        return MapCamera(scale: s, offset: CGPoint(x: c.x - w.x * s, y: c.y - w.y * s))
    }

    static func fitting(_ b: CGRect, in area: CGRect) -> MapCamera {
        let w = max(b.width, 0.5), h = max(b.height, 0.5)
        let s = min(area.width / w, area.height / h)
        return centered(b, scale: s, in: area)
    }

    static func centered(_ b: CGRect, scale s: CGFloat, in area: CGRect) -> MapCamera {
        MapCamera(scale: s, offset: CGPoint(x: area.midX - b.midX * s, y: area.midY - b.midY * s))
    }
}

// MARK: - What's drawn

/// The graph as drawn: filtered by focus, date and kind, sizes recounted as of the date, colours resolved.
struct MapDisplay {
    struct Node: Identifiable {
        var id: UUID
        var kind: MapNodeKind
        var name: String
        var size: Int
        var areaID: UUID?
        var world: CGPoint
        var color: UIColor
        /// Palette slot (AreaColors), or -1 for no area.
        var slot: Int
        /// Radius at fit zoom, in points.
        var radius: CGFloat
    }

    struct Edge {
        var a: Int
        var b: Int
        var weight: Double
        var kind: MapEdge.Kind
    }

    var nodes: [Node] = []
    var edges: [Edge] = []
    var index: [UUID: Int] = [:]
    /// Drawing order: biggest first, so small nodes sit on top.
    var drawOrder: [Int] = []
    /// Label order: areas, then biggest first.
    var labelOrder: [Int] = []

    func node(_ id: UUID) -> Node? { index[id].map { nodes[$0] } }

    init() {}

    init(brain: BrainSnapshot, items: [MemoryItem], focus: UUID?, asOf: Date?, hidden: Set<MapNodeKind>) {
        let graph = brain.map(asOf: asOf, focus: focus, hops: 1)
        let colors = AreaColors.indices(brain)
        var created: [UUID: Date] = [:]
        if asOf != nil { for item in items { created[item.id] = item.createdAt } }
        // Areas stay as landmarks whatever the filter.
        for n in graph.nodes where n.kind == .area || n.id == focus || !hidden.contains(n.kind) {
            var size = n.size
            if let asOf, n.kind != .area {
                // Published sizes are as of now: scale by the share of its listed memories that existed then.
                let ids = brain.itemIDs(for: n.id)
                let known = ids.compactMap { created[$0] }
                if !known.isEmpty {
                    let then = known.filter { $0 <= asOf }.count
                    size = max(1, Int((Double(n.size) * Double(then) / Double(known.count)).rounded()))
                }
            }
            let areaID = n.kind == .area ? n.id : n.areaID
            let base: CGFloat = n.kind == .area ? 7 : (n.kind == .topic ? 4 : 3.2)
            let radius = min(n.kind == .area ? 22 : 18, base + 2.3 * CGFloat(Double(size).squareRoot()))
            index[n.id] = nodes.count
            nodes.append(Node(id: n.id, kind: n.kind, name: n.name, size: size, areaID: areaID,
                              world: CGPoint(x: n.position.x, y: n.position.y),
                              color: AreaColors.uiColor(for: areaID, in: colors), slot: areaID.flatMap { colors[$0] } ?? -1,
                              radius: radius))
        }
        // Areas recount from their topics when the date moves.
        if asOf != nil {
            for i in nodes.indices where nodes[i].kind == .area {
                let id = nodes[i].id
                let sum = nodes.filter { $0.kind == .topic && $0.areaID == id }.reduce(0) { $0 + $1.size }
                if sum > 0 { nodes[i].size = sum; nodes[i].radius = min(22, 7 + 2.3 * CGFloat(Double(sum).squareRoot())) }
            }
        }
        for e in graph.edges {
            guard let a = index[e.a], let b = index[e.b] else { continue }
            edges.append(Edge(a: a, b: b, weight: e.weight, kind: e.kind))
        }
        drawOrder = nodes.indices.sorted { (nodes[$0].kind == .area ? 1 : 0, nodes[$0].radius) > (nodes[$1].kind == .area ? 1 : 0, nodes[$1].radius) }
        labelOrder = nodes.indices.sorted {
            (nodes[$0].id == focus ? 2 : (nodes[$0].kind == .area ? 1 : 0), nodes[$0].size, nodes[$1].name)
                > (nodes[$1].id == focus ? 2 : (nodes[$1].kind == .area ? 1 : 0), nodes[$1].size, nodes[$0].name)
        }
    }

    static func bounds(of points: [MapPoint]) -> CGRect {
        bounds(of: points.map { CGPoint(x: $0.x, y: $0.y) })
    }

    static func bounds(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return CGRect(x: -1, y: -1, width: 2, height: 2) }
        var r = CGRect(origin: first, size: .zero)
        for p in points { r = r.union(CGRect(origin: p, size: .zero)) }
        return r.insetBy(dx: -0.35, dy: -0.35)
    }
}

// MARK: - Drawing

enum MapRenderer {
    /// A node's radius on screen: grows gently with zoom.
    static func radius(_ n: MapDisplay.Node, zoom: CGFloat) -> CGFloat {
        n.radius * min(max(pow(zoom, 0.45), 0.7), 2.4)
    }

    static func draw(_ d: MapDisplay, camera: MapCamera, zoom: CGFloat, selected: UUID?, focus: UUID?,
                     in ctx: inout GraphicsContext, size: CGSize) {
        guard !d.nodes.isEmpty else { return }
        let view = CGRect(origin: .zero, size: size).insetBy(dx: -40, dy: -40)
        let points = d.nodes.map { camera.screen($0.world.x, $0.world.y) }
        let highlight = selected ?? focus
        let highlightIndex = highlight.flatMap { d.index[$0] }

        let palette = AreaColors.uiColors.map { Color(uiColor: $0) } + [Color(uiColor: AreaColors.none)]
        func color(_ n: MapDisplay.Node) -> Color { palette[n.slot >= 0 ? n.slot : palette.count - 1] }

        // Area halos underneath everything.
        for i in d.drawOrder where d.nodes[i].kind == .area {
            let r = radius(d.nodes[i], zoom: zoom) * 2.6
            let p = points[i]
            guard view.insetBy(dx: -r, dy: -r).contains(p) else { continue }
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)), with: .color(color(d.nodes[i]).opacity(0.10)))
        }

        // Edges: batched by look.
        var hierarchy = Path(), light = Path(), strong = Path(), lit = Path()
        for e in d.edges {
            let a = points[e.a], b = points[e.b]
            if !view.contains(a) && !view.contains(b) && !view.intersects(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x) + 1, height: abs(a.y - b.y) + 1)) { continue }
            if let h = highlightIndex, e.a == h || e.b == h {
                lit.move(to: a); lit.addLine(to: b)
            } else if e.kind == .hierarchy {
                hierarchy.move(to: a); hierarchy.addLine(to: b)
            } else if e.weight >= 0.35 {
                strong.move(to: a); strong.addLine(to: b)
            } else {
                light.move(to: a); light.addLine(to: b)
            }
        }
        let dim = highlightIndex == nil ? 1.0 : 0.55
        ctx.stroke(light, with: .color(Color.ink3.opacity(0.22 * dim)), lineWidth: 0.6)
        ctx.stroke(strong, with: .color(Color.ink3.opacity(0.36 * dim)), lineWidth: 1.1)
        ctx.stroke(hierarchy, with: .color(Color.ink3.opacity(0.42 * dim)), lineWidth: 1)
        ctx.stroke(lit, with: .color(Color.ink.opacity(0.55)), lineWidth: 1.4)

        // Nodes, batched by colour: filled topics, then hollow people / organisations / projects on top.
        var filled = Array(repeating: Path(), count: palette.count)
        var hollow = Array(repeating: Path(), count: palette.count)
        var paper = Path()
        for i in d.drawOrder {
            let n = d.nodes[i], p = points[i], r = radius(n, zoom: zoom)
            guard view.insetBy(dx: -r, dy: -r).contains(p) else { continue }
            let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
            let slot = n.slot >= 0 ? n.slot : palette.count - 1
            switch n.kind {
            case .area:
                ctx.fill(Path(ellipseIn: rect), with: .color(color(n).opacity(0.9)))
                ctx.stroke(Path(ellipseIn: rect.insetBy(dx: -2.5, dy: -2.5)), with: .color(color(n).opacity(0.35)), lineWidth: 1.5)
            case .topic, .item:
                filled[slot].addEllipse(in: rect)
            case .person:
                let c = rect.insetBy(dx: 0.9, dy: 0.9)
                paper.addEllipse(in: c)
                hollow[slot].addEllipse(in: c)
            case .organisation:
                let sq = rect.insetBy(dx: r * 0.1, dy: r * 0.1)
                paper.addRoundedRect(in: sq, cornerSize: CGSize(width: r * 0.3, height: r * 0.3))
                hollow[slot].addRoundedRect(in: sq, cornerSize: CGSize(width: r * 0.3, height: r * 0.3))
            case .project:
                let diamond = [CGPoint(x: p.x, y: p.y - r), CGPoint(x: p.x + r, y: p.y), CGPoint(x: p.x, y: p.y + r), CGPoint(x: p.x - r, y: p.y)]
                paper.addLines(diamond); paper.closeSubpath()
                hollow[slot].addLines(diamond); hollow[slot].closeSubpath()
            }
        }
        for slot in palette.indices where !filled[slot].isEmpty { ctx.fill(filled[slot], with: .color(palette[slot])) }
        ctx.fill(paper, with: .color(Color.paper))
        for slot in palette.indices where !hollow[slot].isEmpty { ctx.stroke(hollow[slot], with: .color(palette[slot]), lineWidth: 1.8) }
        if let h = highlightIndex {
            let p = points[h], r = radius(d.nodes[h], zoom: zoom) + 4
            ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)), with: .color(Color.ink), lineWidth: 2)
        }

        // Labels: areas, then biggest first; more as you zoom; never over another label or a node. Sizes are
        // estimated for placement, so only the labels drawn get laid out as text.
        let budget = Int(min(400, 6 + 9 * zoom * zoom))
        let cell: CGFloat = 48
        struct Key: Hashable { var x: Int; var y: Int }
        var grid: [Key: [(CGRect, Int)]] = [:]
        func keys(_ r: CGRect) -> [Key] {
            var out: [Key] = []
            for x in Int((r.minX / cell).rounded(.down))...Int((r.maxX / cell).rounded(.down)) {
                for y in Int((r.minY / cell).rounded(.down))...Int((r.maxY / cell).rounded(.down)) { out.append(Key(x: x, y: y)) }
            }
            return out
        }
        func blocked(_ box: CGRect, except i: Int) -> Bool {
            keys(box).contains { k in grid[k]?.contains { $0.1 != i && $0.0.intersects(box) } ?? false }
        }
        func occupy(_ box: CGRect, _ i: Int) { for k in keys(box) { grid[k, default: []].append((box, i)) } }
        for i in d.nodes.indices where view.contains(points[i]) {
            let r = radius(d.nodes[i], zoom: zoom) + 1
            occupy(CGRect(x: points[i].x - r, y: points[i].y - r, width: 2 * r, height: 2 * r), i)
        }
        var shown = 0, attempts = 0
        let screen = CGRect(origin: .zero, size: size).insetBy(dx: 6, dy: 6)
        for i in d.labelOrder {
            let n = d.nodes[i]
            let important = n.kind == .area || n.id == highlight
            if !important && (shown >= budget || attempts > budget * 4 + 24) { continue }
            let p = points[i], r = radius(n, zoom: zoom)
            guard screen.contains(p) else { continue }
            if !important { attempts += 1 }
            let fontSize: CGFloat = n.kind == .area ? 11.5 : (n.kind == .topic ? 12.5 : 11.5)
            let perChar: CGFloat = n.kind == .area ? fontSize * 0.68 + 1.1 : fontSize * 0.56
            let s = CGSize(width: min(150, CGFloat(n.name.count) * perChar + 2), height: ceil(fontSize * 1.25))
            // Below, right, left, above (areas try above first).
            let below = CGRect(x: p.x - s.width / 2, y: p.y + r + (n.id == highlight ? 6 : 3), width: s.width, height: s.height)
            let above = CGRect(x: p.x - s.width / 2, y: p.y - r - 4 - s.height, width: s.width, height: s.height)
            let right = CGRect(x: p.x + r + 5, y: p.y - s.height / 2, width: s.width, height: s.height)
            let left = CGRect(x: p.x - r - 5 - s.width, y: p.y - s.height / 2, width: s.width, height: s.height)
            let candidates = n.kind == .area ? [above, below, right, left] : [below, right, left, above]
            var chosen = candidates.first { rect in
                let box = rect.insetBy(dx: -3, dy: -1)
                return screen.contains(box) && !blocked(box, except: i)
            }
            if chosen == nil && n.id == highlight { chosen = candidates[0] }
            guard let rect = chosen else { continue }
            let text: Text
            if n.kind == .area {
                text = Text(n.name.uppercased()).font(.system(size: fontSize, weight: .bold)).tracking(1.1).foregroundStyle(Color.ink2)
            } else {
                text = Text(n.name).font(.system(size: fontSize, weight: n.kind == .topic ? .semibold : .medium))
                    .foregroundStyle(n.kind == .topic ? Color.ink : Color.ink2)
            }
            let resolved = ctx.resolve(text)
            let actual = resolved.measure(in: CGSize(width: 150, height: 40))
            let drawn = CGRect(x: rect.midX - actual.width / 2, y: rect.midY - actual.height / 2, width: actual.width, height: actual.height)
            let box = drawn.union(rect).insetBy(dx: -3, dy: -1)
            occupy(box, -1)
            ctx.fill(Path(roundedRect: drawn.insetBy(dx: -3, dy: -1), cornerRadius: 4), with: .color(Color.paper.opacity(0.78)))
            ctx.draw(resolved, in: drawn)
            if !important { shown += 1 }
        }
    }

    /// The node under a tap (generous for small ones), smallest distance first.
    static func hit(_ d: MapDisplay, camera: MapCamera, zoom: CGFloat, at point: CGPoint) -> UUID? {
        var best: (UUID, CGFloat)?
        for n in d.nodes {
            let p = camera.screen(n.world.x, n.world.y)
            let r = max(radius(n, zoom: zoom), 10) + 8
            let dist = hypot(p.x - point.x, p.y - point.y)
            // Areas only by their dot, so taps in a halo reach the topics inside it.
            if dist <= r, best == nil || dist < best!.1 { best = (n.id, dist) }
        }
        return best?.0
    }
}
