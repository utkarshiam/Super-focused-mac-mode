import AppKit
import Combine
import SwiftUI

// Small extras with some personality: delegation ("Waiting on Sam"), slipping tasks ("This has slipped
// 4 times"), one-click overdue rollover, and a burst of confetti when the day is cleared.
// The rules behind them live in Store/ExtrasLogic.swift.

// MARK: - Row badges

/// Small extras in a task row's meta line: who it's waiting on, and how often it was pushed back.
/// Takes the meta line's font and colour, so it suits the regular and the compact row alike.
struct TaskRowBadges: View {
    let task: TaskItem

    init(task: TaskItem) {
        self.task = task
    }

    var body: some View {
        let person = Delegation.normalized(task.waitingOn)
        let pushes = task.postponeCount
        if person != nil || pushes >= Slipping.threshold {
            // Between the regular row's meta spacing (10) and the compact row's (6).
            HStack(spacing: 8) {
                if let person {
                    HStack(spacing: 4) {
                        Image(systemName: "hourglass")
                            .font(.system(size: 10, weight: .semibold))
                        // A long name ends in "…" (the tooltip has it whole) rather than squeezing the list
                        // name beside it down to a letter in a narrow list.
                        WidthLimit(limit: 100) {
                            Text(person)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .help("Waiting on \(person)")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Waiting on \(person)")
                }
                if pushes >= Slipping.threshold {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .bold))
                        Text("\(pushes)×")
                            .monospacedDigit()
                    }
                    .fixedSize()
                    .help("Pushed back \(pushes) times")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Pushed back \(pushes) times")
                }
            }
        }
    }
}

/// Its content at its own width, but never wider than `limit`. (`.frame(maxWidth:)` would pad a short
/// name out to the limit.)
private struct WidthLimit: Layout {
    var limit: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        return content.sizeThatFits(ProposedViewSize(width: min(proposal.width ?? limit, limit), height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

// MARK: - Waiting on

/// "Waiting on" in the task detail's Details card: who's doing it. Return saves, Esc puts it back,
/// ✕ clears, and the menu offers the people used before.
struct DelegateRow: View {
    @EnvironmentObject var store: Store
    let taskID: UUID
    @State private var draft = ""
    /// Set once the stored name is in `draft`, so an empty field can never be saved over it by accident.
    @State private var loaded = false
    @FocusState private var editing: Bool

    init(taskID: UUID) {
        self.taskID = taskID
    }

    var body: some View {
        let current = Delegation.normalized(store.task(taskID)?.waitingOn)
        let people = Delegation.recentPeople(in: store.tasks)
        HStack(spacing: Space.md) {
            Image(systemName: "hourglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.ink2)
                .frame(width: 18)
            Text("Waiting on")
                .textStyle(.subhead)
                .foregroundStyle(Color.ink2)
                .lineLimit(1)
                .fixedSize()
            TextField("Nobody", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.trailing)
                // A long name ends in "…" until it's clicked into, instead of being cut off mid-letter.
                .lineLimit(1)
                .truncationMode(.tail)
                .focused($editing)
                .onSubmit {
                    save(draft)
                    editing = false
                }
                .onExitCommand {
                    draft = current ?? ""
                    editing = false
                }
                .accessibilityLabel("Waiting on")
                .help("Who's doing it. Tasks you're waiting on are listed under Waiting.")
            if !people.isEmpty {
                Menu {
                    Section("People you've waited on") {
                        ForEach(people, id: \.self) { person in
                            Button { save(person) } label: {
                                if person == current { Label(person, systemImage: "checkmark") } else { Text(person) }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Color.ink2)
                        .frame(width: 22, height: 26)
                }
                .menuChrome(RoundedRectangle(cornerRadius: Radius.xs, style: .continuous), fill: .clear, hoverFill: .pressedTint)
                .help("Pick someone you've waited on before")
            }
            if current != nil {
                Button { save(nil) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(Color.ink2)
                }
                .buttonStyle(IconButtonStyle(size: 24))
                .help("Not waiting on anyone")
            }
        }
        .padding(.horizontal, Space.md)
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.hair).frame(height: 1).padding(.leading, 42)
        }
        .onAppear {
            draft = current ?? ""
            loaded = true
        }
        .onChange(of: current) { value in
            // Changed elsewhere (the slip nudge, bulk edit, undo): show it, unless it's being typed over.
            if !editing { draft = value ?? "" }
        }
        .onChange(of: editing) { isEditing in
            if !isEditing { save(draft) }
        }
        // Clicking another task replaces this view: keep what was typed.
        .onDisappear { save(draft) }
    }

    private func save(_ name: String?) {
        guard loaded else { return }
        let value = Delegation.normalized(name)
        draft = value ?? ""
        guard let task = store.task(taskID), Delegation.normalized(task.waitingOn) != value else { return }
        withAnimation(Motion.base) {
            store.mutateTask(taskID, undo: value == nil ? "Clear Waiting On" : "Delegate") { $0.waitingOn = value }
        }
    }
}

// MARK: - Slipping tasks

/// Under the deadline in the task detail once a task keeps slipping:
/// "This has slipped 4 times. Do it, delegate it, or drop it." Renders nothing otherwise.
struct SlipNudge: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    @EnvironmentObject var focus: FocusTimer
    let taskID: UUID
    @State private var delegating = false

    init(taskID: UUID) {
        self.taskID = taskID
    }

    var body: some View {
        // Hidden while it's being worked on: that's the answer to "do it".
        if let task = store.task(taskID), Slipping.needsNudge(task), focus.taskID != taskID {
            VStack(alignment: .leading, spacing: Space.md) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Tone.warning.fg)
                        Text("This has slipped \(task.postponeCount) times.")
                            .textStyle(.subheadStrong)
                            .foregroundStyle(Color.ink)
                    }
                    Text("Do it, delegate it, or drop it.")
                        .textStyle(.subhead)
                        .foregroundStyle(Color.ink2)
                }
                // Wraps instead of overflowing if the panel is ever narrower.
                FlowLayout(spacing: Space.sm, lineSpacing: Space.sm) {
                    Button("Do it now") { doItNow(task) }
                        .buttonStyle(SecondaryPill(height: 30))
                        .help("Start a focus session on it now")
                    Button("Delegate…") { delegating = true }
                        .buttonStyle(SecondaryPill(height: 30))
                        .help("Hand it to someone. It moves to Waiting.")
                        .popover(isPresented: $delegating, arrowEdge: .bottom) {
                            DelegatePopover(people: Delegation.recentPeople(in: store.tasks)) { delegate(task.id, to: $0) }
                        }
                    Button("Drop it") { drop(task) }
                        .buttonStyle(SecondaryPill(height: 30))
                        .help("Delete it (⌘Z brings it back)")
                }
            }
            .padding(Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hairlineCard(radius: Radius.lg)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private func doItNow(_ task: TaskItem) {
        let minutes = task.remainingMinutes > 0 ? task.remainingMinutes : Prefs.focusMinutes
        withAnimation(Motion.gentle) { focus.start(taskID: task.id, minutes: minutes) }
        Haptics.success()
        app.showToast("Focusing on it for \(Fmt.duration(minutes: minutes))")
    }

    private func delegate(_ id: UUID, to name: String) {
        guard let person = Delegation.normalized(name) else { return }
        delegating = false
        // Let the popover finish closing before the nudge (its anchor) folds away.
        let store = store, app = app
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard store.task(id) != nil else { return }
            withAnimation(Motion.gentle) {
                store.mutateTask(id, undo: "Delegate") { $0.waitingOn = person }
            }
            app.showToast("Delegated to \(Extras.shortTitle(person, limit: 32)). It's in Waiting.")
        }
    }

    private func drop(_ task: TaskItem) {
        withAnimation(Motion.sheet) {
            if app.selectedTaskID == task.id { app.selectedTaskID = nil }
            app.selectedTaskIDs.remove(task.id)
        }
        withAnimation(Motion.base) { store.deleteTasks([task.id]) }
        app.showToast("Dropped “\(Extras.shortTitle(task.title))”. ⌘Z brings it back.")
    }
}

/// "Who's doing it?": a name field, plus the people used before.
private struct DelegatePopover: View {
    let people: [String]
    let onDelegate: (String) -> Void
    @State private var name = ""
    @State private var sent = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Who's doing it?")
                .font(.system(size: 17, weight: .bold))
                .tracking(-0.2)
                .foregroundStyle(Color.ink)
            TextField("Name", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium))
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Color.fill))
                .focused($focused)
                .onSubmit { send(name) }
                .help("Who's doing it")
            if !people.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(people.prefix(8), id: \.self) { person in
                        Button(person) { send(person) }
                            .buttonStyle(PersonChipStyle())
                            .help("Waiting on \(person)")
                    }
                }
            }
            HStack(spacing: Space.sm) {
                Text("It moves to Waiting.")
                    .textStyle(.caption)
                    .foregroundStyle(Color.ink3)
                Spacer(minLength: 0)
                Button("Delegate") { send(name) }
                    .buttonStyle(PrimaryPill(height: 32))
                    .keyboardShortcut(.defaultAction)
                    .disabled(Delegation.normalized(name) == nil)
                    .help("Hand it over (Return)")
            }
        }
        .padding(Space.lg)
        .frame(width: 280)
        .background(Color.raised)
        .tint(Color.ink)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    /// Return can reach both the field and the default button: only the first one counts.
    private func send(_ name: String) {
        guard !sent, let person = Delegation.normalized(name) else { return }
        sent = true
        onDelegate(person)
    }
}

/// A person's name as a small fill pill.
private struct PersonChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PersonChip(configuration: configuration)
    }
}

private struct PersonChip: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Color.ink)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(hovering || pressed ? Color.fillStrong : Color.fill))
            .contentShape(Capsule())
            .scaleEffect(pressed ? 0.95 : 1)
            .animation(pressed ? Motion.instant : Motion.press, value: pressed)
            .onHover { h in withAnimation(Motion.fast) { hovering = h } }
    }
}

// MARK: - Overdue rollover

/// Under the Calendar header when anything is overdue: "3 overdue · Move all to today".
/// Renders nothing when nothing is overdue.
struct OverdueRollover: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState

    var body: some View {
        let count = store.rolloverCandidates(now: app.clock).count
        if count > 0 {
            HStack(spacing: Space.md) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text("\(count) overdue")
                        .font(.system(size: 13.5, weight: .semibold))
                        .monospacedDigit()
                }
                .foregroundStyle(Color.dangerText)
                .accessibilityElement(children: .combine)
                Button("Move all to today", action: moveAll)
                    .buttonStyle(SecondaryPill(height: 28))
                    .help("Move every overdue task to \(Fmt.absoluteDay(app.clock)), keeping its time")
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private func moveAll() {
        let now = Date()
        let moved = withAnimation(Motion.gentle) { store.rollOverdueToToday(now: now) }
        guard moved > 0 else { return }
        Haptics.success()
        app.showToast("Moved \(Fmt.plural(moved, "task")) to \(Fmt.absoluteDay(now))")
    }
}

// MARK: - Day cleared

/// Confetti when the day is cleared. Purely decorative: it never takes a click.
/// It sits over the main window for as long as the app runs, so it's also where the window's store is
/// watched for tasks ticked off away from a checkbox (see `Celebration.watch`).
struct CelebrationOverlay: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var app: AppState
    @ObservedObject private var celebration = Celebration.shared

    var body: some View {
        ZStack {
            // Always there, so the overlay appears (and starts watching) before any confetti does.
            Color.clear
            if let burst = celebration.burst {
                ConfettiView(burst: burst)
                    .id(burst.id)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { celebration.watch(store, app: app) }
    }
}

/// The day-cleared moment: a toast, a chime and a short burst of confetti, at most once a day.
@MainActor
final class Celebration: ObservableObject {
    static let shared = Celebration()

    struct Burst: Equatable {
        let id = UUID()
        let seed: UInt64
        let start: Date
    }

    /// Set while the confetti falls.
    @Published private(set) var burst: Burst?

    /// Remembers the day it last played. Tests swap in their own suite.
    var defaults: UserDefaults = .standard
    /// Off under unit tests.
    var playsSound = NSClassFromString("XCTestCase") == nil
    /// With Reduce Motion on, the day-cleared moment is the toast alone.
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private var watching: AnyCancellable?
    private weak var watchedStore: Store?

    /// Checkboxes and keyboard triage report completions through `Extras.didComplete`. This catches the
    /// rest: a focus session's Done, Done on an alarm or a notification, a box ticked in a note. A task
    /// ticked off twice over (by the hook and here) is fine: the moment plays once a day.
    func watch(_ store: Store, app: AppState) {
        guard watchedStore !== store else { return }
        watchedStore = store
        watching = store.$tasks.sink { [weak store, weak app] tasks in
            // @Published sends before it stores, so `store.tasks` is still the list from before the change.
            guard let store, let app else { return }
            let finished = DayClear.justFinished(from: store.tasks, to: tasks, now: Date())
            guard !finished.isEmpty else { return }
            // Once the change has landed and whoever made it has had their say ("Marked 3 tasks as done"),
            // so "Day cleared" is the last word.
            DispatchQueue.main.async {
                for id in finished { Extras.didComplete(id, store: store, app: app) }
            }
        }
    }

    func dayCleared(app: AppState, now: Date = Date()) {
        guard DayClear.shouldCelebrate(lastCelebrated: defaults.string(forKey: DayClear.lastCelebratedKey), now: now) else { return }
        defaults.set(Fmt.dayKey(now), forKey: DayClear.lastCelebratedKey)
        app.showToast("Day cleared. Nice work.")
        guard !reduceMotion() else { return }
        if playsSound {
            // Just after the completion "pop", so the two don't land on top of each other.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { NSSound(named: "Glass")?.play() }
        }
        let burst = Burst(seed: UInt64.random(in: 1...UInt64.max), start: Date())
        self.burst = burst
        DispatchQueue.main.asyncAfter(deadline: .now() + Confetti.duration + 0.1) { [weak self] in
            if self?.burst == burst { self?.burst = nil }
        }
    }
}

private struct ConfettiView: View {
    let burst: Celebration.Burst
    private let pieces: [Confetti.Piece]

    init(burst: Celebration.Burst) {
        self.burst = burst
        pieces = Confetti.pieces(seed: burst.seed)
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                Confetti.draw(pieces, in: &context, size: size, at: timeline.date.timeIntervalSince(burst.start))
            }
        }
        .ignoresSafeArea()
    }
}

/// A short, tasteful burst from the top edge: ink and one accent, shot down, fluttering, then fading out.
enum Confetti {
    static let duration: TimeInterval = 1.25

    enum Shape { case rect, dot, streamer }

    struct Piece {
        /// Start across the width (0…1) and above the top edge (points).
        var x: Double, y: Double
        var delay: Double
        /// The burst: initial downward and sideways speed (pt/s), slowing at `drag` (1/s) to a `fall` flutter.
        var speed: Double, drift: Double, fall: Double, drag: Double
        /// Side-to-side sway and tumbling.
        var sway: Double, swayRate: Double, phase: Double
        var angle: Double, spin: Double, flipRate: Double
        var shape: Shape
        var width: Double, height: Double
        /// 0 ink, 1 ink2, 2 accent.
        var tint: Int

        struct State {
            var x: Double, y: Double, angle: Double, flip: Double, opacity: Double
        }

        /// Where the piece is `t` seconds into the burst; nil before it starts and once the burst is over.
        func state(at t: Double, width: Double) -> State? {
            let local = t - delay
            guard local >= 0, t < Confetti.duration else { return nil }
            let slowed = (1 - exp(-drag * local)) / drag
            let fadeIn = min(1, local / 0.08)
            let fadeOut = min(1, max(0, (Confetti.duration - t) / (Confetti.duration * 0.35)))
            return State(x: x * width + drift * slowed + sway * sin(swayRate * local + phase),
                         y: y + fall * local + (speed - fall) * slowed,
                         angle: angle + spin * local,
                         flip: abs(cos(flipRate * local + phase)),
                         opacity: fadeIn * fadeOut)
        }
    }

    static func pieces(seed: UInt64, count: Int = 90) -> [Piece] {
        var rng = SplitMix64(seed: seed)
        func r(_ range: ClosedRange<Double>) -> Double { Double.random(in: range, using: &rng) }
        return (0..<count).map { _ in
            let roll = r(0...1)
            let shape: Shape = roll < 0.6 ? .rect : (roll < 0.8 ? .dot : .streamer)
            let dot = r(5...6.5)
            let size: (Double, Double) = switch shape {
            case .rect: (r(5.5...7.5), r(9...12))
            case .dot: (dot, dot)
            case .streamer: (2.5, r(12...16))
            }
            let tint = r(0...1)
            return Piece(x: r(0.03...0.97), y: r(-40 ... -8), delay: r(0...0.2),
                         speed: r(500...1400), drift: r(-240...240), fall: r(140...230), drag: r(3.2...4.4),
                         sway: r(5...15), swayRate: r(5...9), phase: r(0...(2 * .pi)),
                         angle: r(0...(2 * .pi)), spin: r(-7...7), flipRate: r(6...12),
                         shape: shape, width: size.0, height: size.1,
                         tint: tint < 0.45 ? 0 : (tint < 0.6 ? 1 : 2))
        }
    }

    static func draw(_ pieces: [Piece], in context: inout GraphicsContext, size: CGSize, at t: Double) {
        let tints: [Color] = [.ink, .ink2, .success]
        for piece in pieces {
            guard let s = piece.state(at: t, width: size.width) else { continue }
            var ctx = context
            ctx.opacity = s.opacity
            ctx.translateBy(x: s.x, y: s.y)
            ctx.rotate(by: .radians(s.angle))
            ctx.scaleBy(x: 1, y: max(0.12, s.flip))
            let rect = CGRect(x: -piece.width / 2, y: -piece.height / 2, width: piece.width, height: piece.height)
            let path = piece.shape == .dot ? Path(ellipseIn: rect) : Path(roundedRect: rect, cornerRadius: min(piece.width, piece.height) * 0.3)
            ctx.fill(path, with: .color(tints[piece.tint]))
        }
    }
}

/// Small, fast, seedable random numbers, so each burst can be drawn the same way every frame.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Hooks

enum Extras {
    /// Called after a (non-repeating) task is ticked off. If that cleared the day, celebrate (once a day).
    @MainActor
    static func didComplete(_ id: UUID, store: Store, app: AppState) {
        guard let task = store.task(id) else { return }
        let now = Date()
        guard DayClear.didClearDay(completing: task, in: store.tasks, now: now, calendar: store.calendar) else { return }
        Celebration.shared.dayCleared(app: app, now: now)
    }

    /// A task title (or a name) short enough for a one-line toast.
    static func shortTitle(_ title: String, limit: Int = 40) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Untitled" }
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
