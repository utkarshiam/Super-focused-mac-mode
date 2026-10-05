import Foundation

/// A focus session on one task: counts down the estimate (or a Pomodoro), or runs as a stopwatch.
/// Time spent is logged to the task when the session stops.
///
/// Only start/pause/stop publish changes; views that show the running clock use `TimelineView`,
/// so the rest of the UI isn't re-rendered every second.
@MainActor
final class FocusTimer: ObservableObject {
    @Published private(set) var taskID: UUID?
    @Published private(set) var title = ""
    @Published private(set) var target: TimeInterval?
    @Published private(set) var isPaused = false
    @Published private(set) var sessionStart: Date?

    weak var store: Store?
    weak var alarms: AlarmService?

    private var accumulated: TimeInterval = 0
    private var runningSince: Date?
    private var timer: Timer?
    private var finishHandled = false

    var isActive: Bool { sessionStart != nil }

    func elapsed(at now: Date = Date()) -> TimeInterval {
        accumulated + (runningSince.map { now.timeIntervalSince($0) } ?? 0)
    }

    func remaining(at now: Date = Date()) -> TimeInterval? {
        target.map { max(0, $0 - elapsed(at: now)) }
    }

    func progress(at now: Date = Date()) -> Double {
        guard let target, target > 0 else { return 0 }
        return min(1, elapsed(at: now) / target)
    }

    /// "24:13" counting down, or elapsed time for a stopwatch.
    func clock(at now: Date = Date()) -> String {
        Fmt.clock(remaining(at: now) ?? elapsed(at: now))
    }

    func start(taskID: UUID?, minutes: Int?) {
        if isActive { stop(markDone: false) }
        self.taskID = taskID
        title = store?.task(taskID)?.title ?? "Focus session"
        target = minutes.map { TimeInterval(max(1, $0) * 60) }
        accumulated = 0
        runningSince = Date()
        sessionStart = Date()
        isPaused = false
        finishHandled = false

        timer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Integrations.shared.focusStarted(until: target.map { Date().addingTimeInterval($0) }, taskTitle: title)
    }

    func pause() {
        guard let since = runningSince else { return }
        accumulated += Date().timeIntervalSince(since)
        runningSince = nil
        isPaused = true
    }

    func resume() {
        guard isActive, isPaused else { return }
        runningSince = Date()
        isPaused = false
    }

    func togglePause() { isPaused ? resume() : pause() }

    func extend(minutes: Int) {
        guard isActive else { return }
        target = max(target ?? 0, elapsed()) + TimeInterval(minutes * 60)
        finishHandled = false
        resume()
    }

    func continueAsStopwatch() {
        target = nil
        finishHandled = false
        resume()
    }

    func stop(markDone: Bool) {
        guard let start = sessionStart else { return }
        let seconds = Int(elapsed())
        let id = taskID
        timer?.invalidate()
        timer = nil
        taskID = nil
        title = ""
        target = nil
        accumulated = 0
        runningSince = nil
        sessionStart = nil
        isPaused = false
        store?.logFocus(taskID: id, start: start, seconds: seconds)
        if markDone, let id { store?.setCompleted(id, true) }
        Integrations.shared.focusEnded()
    }

    private func tick() {
        guard isActive, !finishHandled, let remaining = remaining(), remaining <= 0 else { return }
        finishHandled = true
        pause()
        let minutes = Int((target ?? 0) / 60)
        alarms?.presentFocusDone(taskID: taskID, title: title, minutes: minutes)
        NotificationService.shared.deliver(title: "Time's up: \(title)", body: "Your \(Fmt.duration(minutes: minutes)) focus session is done.", taskID: taskID)
    }
}
