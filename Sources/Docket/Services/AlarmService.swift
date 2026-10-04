import AppKit
import SwiftUI

enum SoundPlayer {
    static func make(_ sound: AlarmSound) -> NSSound? {
        if sound == .docket {
            if let url = Bundle.main.url(forResource: "DocketAlarm", withExtension: "wav"),
               let s = NSSound(contentsOf: url, byReference: true) {
                return s
            }
            return (NSSound(named: "Sosumi")?.copy() as? NSSound)
        }
        return NSSound(named: sound.rawValue)?.copy() as? NSSound
    }

    private static var preview: NSSound?

    static func playPreview(_ sound: AlarmSound) {
        preview?.stop()
        preview = make(sound)
        preview?.volume = 1
        preview?.play()
    }
}

/// Watches alarm reminders while Docket runs and rings them in a window that floats above everything
/// (including full-screen apps) until it's snoozed, completed or dismissed.
@MainActor
final class AlarmService: ObservableObject {
    struct Ringing: Identifiable, Equatable {
        enum Kind: Equatable { case alarm, focusDone }
        let id = UUID()
        var taskID: UUID?
        var title: String
        var detail: String
        var kind: Kind
        var firedAt = Date()
    }

    @Published private(set) var current: Ringing?
    @Published private(set) var queued: [Ringing] = []

    weak var store: Store?
    weak var app: AppState?
    weak var focus: FocusTimer?

    private var timer: Timer?
    private var lastCheck: Date
    private var lastPersisted = Date.distantPast
    private var panel: NSPanel?
    private var sound: NSSound?
    private var silenceWork: DispatchWorkItem?
    private static let lastCheckKey = "alarmLastCheck"

    init() {
        lastCheck = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? Date()
    }

    func start() {
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    /// Saves the checkpoint so alarms that already rang don't ring again after a relaunch.
    func persist() {
        UserDefaults.standard.set(lastCheck, forKey: Self.lastCheckKey)
    }

    func tick(now: Date = Date()) {
        defer {
            lastCheck = now
            if now.timeIntervalSince(lastPersisted) > 30 {
                UserDefaults.standard.set(now, forKey: Self.lastCheckKey)
                lastPersisted = now
            }
        }
        guard let store, now > lastCheck else { return }
        for t in store.tasks where !t.isCompleted {
            for r in t.reminders where r.isAlarm {
                guard let fire = r.fireDate(for: t, allDayHour: Prefs.allDayHour),
                      fire > lastCheck, fire <= now,
                      now.timeIntervalSince(fire) < 3 * 3600 else { continue }
                enqueue(Ringing(taskID: t.id, title: t.title, detail: detail(for: t), kind: .alarm))
            }
        }
    }

    private func detail(for t: TaskItem) -> String {
        var parts: [String] = []
        if let due = t.dueDate { parts.append("Due \(Fmt.absoluteDay(due))" + (t.dueHasTime ? " at \(Fmt.time(due))" : "")) }
        if let est = t.estimateMinutes { parts.append("~\(Fmt.duration(minutes: est))") }
        if let list = store?.list(t.listID) { parts.append(list.name) }
        return parts.joined(separator: " · ")
    }

    func enqueue(_ ringing: Ringing) {
        if let taskID = ringing.taskID, ringing.kind == .alarm,
           current?.taskID == taskID || queued.contains(where: { $0.taskID == taskID }) { return }
        if current == nil { present(ringing) } else { queued.append(ringing) }
    }

    func presentFocusDone(taskID: UUID?, title: String, minutes: Int) {
        enqueue(Ringing(taskID: taskID, title: title, detail: "Focus session complete · \(Fmt.duration(minutes: minutes))", kind: .focusDone))
    }

    /// Rings a sample alarm (Settings → Test alarm).
    func test() {
        enqueue(Ringing(taskID: nil, title: "This is what an alarm looks like", detail: "Snooze, complete or dismiss it", kind: .alarm))
    }

    private func present(_ ringing: Ringing) {
        current = ringing
        showPanel()
        startSound(kind: ringing.kind)
        NSApp.requestUserAttention(.criticalRequest)
        if let id = ringing.taskID {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NotificationService.shared.removeDelivered(forTask: id) }
        }
    }

    private func showPanel() {
        if panel == nil {
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
                styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            p.titlebarAppearsTransparent = true
            p.titleVisibility = .hidden
            p.standardWindowButton(.closeButton)?.isHidden = true
            p.standardWindowButton(.miniaturizeButton)?.isHidden = true
            p.standardWindowButton(.zoomButton)?.isHidden = true
            p.isMovableByWindowBackground = true
            p.becomesKeyOnlyIfNeeded = true
            p.backgroundColor = Palette.raised
            p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.contentView = NSHostingView(rootView: AlarmView().environmentObject(self))
            panel = p
        }
        guard let panel else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2 + frame.height * 0.12))
        }
        // Shown on top of everything, but it never takes the keyboard: a Return meant for another app
        // must not dismiss the alarm or complete the task. Its buttons still work on the first click.
        panel.orderFrontRegardless()
    }

    private func startSound(kind: Ringing.Kind) {
        stopSound()
        sound = SoundPlayer.make(kind == .focusDone ? .glass : Prefs.alarmSound)
        sound?.volume = 1
        sound?.loops = kind == .alarm
        sound?.play()
        // Don't ring forever if nobody is at the desk; the window stays up.
        let work = DispatchWorkItem { [weak self] in self?.stopSound() }
        silenceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (kind == .alarm ? 300 : 10), execute: work)
    }

    private func stopSound() {
        silenceWork?.cancel()
        sound?.stop()
        sound = nil
    }

    // MARK: Actions from the window

    func dismiss() {
        stopSound()
        if queued.isEmpty {
            current = nil
            panel?.orderOut(nil)
        } else {
            present(queued.removeFirst())
        }
    }

    func snooze(minutes: Int) {
        if let r = current, let id = r.taskID, r.kind == .alarm {
            store?.snooze(id, minutes: minutes, isAlarm: true)
        }
        dismiss()
    }

    func complete() {
        guard let r = current else { return }
        if r.kind == .focusDone {
            focus?.stop(markDone: true)
        } else if let id = r.taskID {
            store?.setCompleted(id, true)
        }
        dismiss()
    }

    func startFocus() {
        if let r = current, let id = r.taskID, let t = store?.task(id) {
            focus?.start(taskID: id, minutes: t.remainingMinutes > 0 ? t.remainingMinutes : Prefs.focusMinutes)
        }
        dismiss()
    }

    func extendFocus(minutes: Int) {
        focus?.extend(minutes: minutes)
        dismiss()
    }

    func keepGoing() {
        focus?.continueAsStopwatch()
        dismiss()
    }

    func stopFocus() {
        focus?.stop(markDone: false)
        dismiss()
    }

    func open() {
        if let id = current?.taskID, let store { app?.reveal(task: id, in: store) }
        NSApp.activate(ignoringOtherApps: true)
        stopSound()
    }
}

// MARK: - Alarm window

struct AlarmView: View {
    @EnvironmentObject var alarms: AlarmService
    @State private var pulse = false
    @State private var wiggle = false

    var body: some View {
        let ringing = alarms.current
        let isFocus = ringing?.kind == .focusDone
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .strokeBorder(Color.ink.opacity(0.18), lineWidth: 2)
                    .frame(width: 92, height: 92)
                    .scaleEffect(pulse ? 1.18 : 0.9)
                    .opacity(pulse ? 0 : 1)
                Circle()
                    .fill(Color.primaryFill)
                    .frame(width: 64, height: 64)
                Image(systemName: isFocus ? "checkmark" : "alarm.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Color.onPrimary)
                    .rotationEffect(.degrees(isFocus ? 0 : (wiggle ? 10 : -10)))
            }
            .frame(height: 96)
            .padding(.top, Space.xxl)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: false)) { pulse = true }
                withAnimation(.easeInOut(duration: 0.15).repeatForever(autoreverses: true)) { wiggle = true }
            }

            VStack(spacing: 6) {
                Eyebrow(text: isFocus ? "Time's up" : "Alarm", color: .ink2)
                if !isFocus {
                    BigTime(date: ringing?.firedAt ?? Date(), size: 44)
                }
                Text(ringing?.title ?? "")
                    .font(.system(size: 20, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(Color.ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, Space.xxl)
                if let detail = ringing?.detail, !detail.isEmpty {
                    Text(detail)
                        .textStyle(.callout)
                        .foregroundStyle(Color.ink2)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, Space.xxl)
                }
            }
            .padding(.top, Space.md)

            Spacer(minLength: Space.lg)

            if isFocus {
                HStack(spacing: Space.sm) {
                    Button("+10 min") { alarms.extendFocus(minutes: 10) }.buttonStyle(SecondaryPill(height: 40))
                    Button("Keep going") { alarms.keepGoing() }.buttonStyle(SecondaryPill(height: 40))
                    Button("Stop") { alarms.stopFocus() }.buttonStyle(SecondaryPill(height: 40))
                    if ringing?.taskID != nil {
                        Button("Mark done") { alarms.complete() }
                            .buttonStyle(PrimaryPill(height: 40))
                    }
                }
            } else {
                HStack(spacing: Space.sm) {
                    Menu {
                        ForEach([5, 10, 15, 30, 60], id: \.self) { m in
                            Button(m < 60 ? "\(m) minutes" : "1 hour") { alarms.snooze(minutes: m) }
                        }
                    } label: {
                        Text("Snooze")
                            .textStyle(.button)
                            .foregroundStyle(Color.ink)
                            .padding(.horizontal, 16)
                            .frame(height: 40)
                    } primaryAction: {
                        alarms.snooze(minutes: 10)
                    }
                    .menuChrome(Capsule())
                    .disabled(ringing?.taskID == nil)
                    .help("Snooze 10 minutes (hold for more)")
                    Button("Start focus") { alarms.startFocus() }
                        .buttonStyle(SecondaryPill(height: 40))
                        .disabled(ringing?.taskID == nil)
                    Button("Mark done") { alarms.complete() }
                        .buttonStyle(SecondaryPill(height: 40))
                        .disabled(ringing?.taskID == nil)
                    Button("Dismiss") { alarms.dismiss() }
                        .buttonStyle(PrimaryPill(height: 40))
                        .keyboardShortcut(.defaultAction)
                }
            }

            HStack {
                if !alarms.queued.isEmpty {
                    Text("\(alarms.queued.count) more waiting")
                        .textStyle(.caption)
                        .foregroundStyle(Color.ink3)
                }
                Spacer()
                if ringing?.taskID != nil {
                    Button("Open in Docket") { alarms.open() }
                        .buttonStyle(PressScale())
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.ink2)
                }
            }
            .padding(.horizontal, Space.xl)
            .padding(.vertical, Space.md)
        }
        .frame(width: 480, height: 400)
        .background(Color.raised.ignoresSafeArea())
        .tint(Color.ink)
    }
}
