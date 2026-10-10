import AppKit
import MemoryKit
import SwiftUI
import UniformTypeIdentifiers

/// Spotlight-style capture panel opened by the global shortcut: a task, a note, or something to remember
/// (text, a link, or files dropped on it). ⇥ switches between them; the last one used comes back next time.
/// The mic records a voice note (any mode): the panel grows for the recording and its result.
struct CapturePanelView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    @ObservedObject var voice: VoiceCaptureModel
    var close: () -> Void
    /// The panel's height changed (recording, a result).
    var resize: (CGFloat) -> Void = { _ in }

    enum Mode: String, CaseIterable { case task = "Task", note = "Note", memory = "Memory" }
    @State private var mode: Mode = CapturePanelView.lastMode
    @State private var text = ""
    /// The Date, Time, List and More dropdowns (menus only: a popover would close the panel).
    @State private var options = AddOptions()
    @State private var confirmation: String?
    @State private var confirmationDetail = ""
    @State private var dropTargeted = false
    @State private var monitor: Any?
    @FocusState private var focused: Bool

    /// The mode used last (screenshot mode always starts on Task).
    static var lastMode: Mode {
        guard !DebugSnapshot.isActive else { return .task }
        return Mode(rawValue: UserDefaults.standard.string(forKey: Prefs.Key.captureMode) ?? "") ?? .task
    }

    var body: some View {
        Group {
            if voice.isActive {
                VoiceCaptureCard(model: voice, close: close)
            } else {
                typing
            }
        }
        .padding(.horizontal, Space.xxl)
        .padding(.vertical, Space.xl)
        .frame(width: 640, height: voice.panelHeight, alignment: .topLeading)
        .floatingPanelChrome()
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                    .strokeBorder(Color.ink.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: drop)
        .onChange(of: mode) { m in
            if !DebugSnapshot.isActive { UserDefaults.standard.set(m.rawValue, forKey: Prefs.Key.captureMode) }
        }
        .onChange(of: voice.panelHeight) { h in resize(h) }
        .onChange(of: voice.isActive) { active in
            if !active { DispatchQueue.main.async { focused = true } }
        }
        .onAppear {
            resize(voice.panelHeight)
            DispatchQueue.main.async { focused = true }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.window is QuickCapturePanel, event.window?.isKeyWindow == true else { return event }
                if voice.isActive { return voiceKey(event) ? nil : event }
                guard event.keyCode == 48 else { return event }
                let all = Mode.allCases
                let next = all[(all.firstIndex(of: mode)! + (event.modifierFlags.contains(.shift) ? all.count - 1 : 1)) % all.count]
                withAnimation(Motion.snappy) { mode = next }
                return nil
            }
        }
        .onDisappear {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }

    /// Return or Esc while recording stops and saves; on the result they close it; Esc while Gemini works hides the
    /// panel (the result is announced). True when handled.
    private func voiceKey(_ event: NSEvent) -> Bool {
        let isReturn = event.keyCode == 36 || event.keyCode == 76, isEscape = event.keyCode == 53
        guard isReturn || isEscape else { return event.keyCode == 48 }
        switch voice.phase {
        case .recording:
            voice.stop()
        case .result, .failed:
            voice.reset()
            close()
        case .starting:
            if isEscape { voice.cancel(); close() }
        case .working:
            // Gemini keeps going; the result is announced when it's ready.
            if isEscape { close() }
        default:
            break
        }
        return true
    }

    private var typing: some View {
        let now = Date()
        return VStack(alignment: .leading, spacing: Space.md) {
            HStack {
                SegmentedControl(selection: $mode, options: Mode.allCases.map { ($0, $0.rawValue) })
                Spacer()
                Text("↩ save · ⇥ switch · esc close")
                    .textStyle(.caption)
                    .foregroundStyle(Color.ink3)
            }

            HStack(spacing: Space.md) {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 26, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(Color.ink)
                    .focused($focused)
                    .onSubmit(save)
                Button { voice.start() } label: { Image(systemName: "mic") }
                    .buttonStyle(IconButtonStyle(size: 34, filled: true))
                    .help("Record a voice note: Docket turns it into tasks and a memory")
                    .accessibilityLabel("Record a voice note")
            }

            Group {
                if let confirmation {
                    HStack(spacing: Space.sm) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(Color.onPrimary)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.primaryFill))
                        HStack(spacing: 0) {
                            Text(confirmation).lineLimit(1).truncationMode(.middle)
                            if !confirmationDetail.isEmpty {
                                Text(confirmationDetail).lineLimit(1).fixedSize()
                            }
                        }
                        .textStyle(.subheadStrong)
                        .foregroundStyle(Color.ink)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                } else if mode == .task {
                    // One line, as the panel has a fixed size: repeat and tags fold into "+2" and the hint
                    // drops out before anything wraps.
                    AddOptionsBar(options: $options, parsed: parser(now).parse(text), context: AddContext(), lists: store.lists, now: now,
                                  usesPopovers: false, arrangement: .oneLine,
                                  hint: text.trimmingCharacters(in: .whitespaces).isEmpty ? "Or just type “fri 10am 30m”" : nil,
                                  onPick: { focused = true })
                        .transition(.opacity)
                } else {
                    Text(mode == .note ? "Saved to Notes." : "Saved to Memory. Drop files here too.")
                        .textStyle(.subhead)
                        .foregroundStyle(Color.ink3)
                        .transition(.opacity)
                }
            }
            .frame(height: 26, alignment: .leading)
            .animation(Motion.base, value: confirmation)
        }
    }

    private var placeholder: String {
        switch mode {
        case .task: "What needs doing?"
        case .note: "Jot a note. The first line becomes the title."
        case .memory: "A thought, an idea or a link to remember"
        }
    }

    private func parser(_ now: Date) -> QuickParser {
        QuickParser(now: now, lists: store.lists, workdayEndMinutes: Prefs.workdayEnd)
    }

    private func save() {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            close()
            return
        }
        switch mode {
        case .task:
            let now = Date()
            let t = store.addTask(options.makeTask(parsed: parser(now).parse(raw), context: AddContext(), lists: store.lists, now: now))
            options.reset()
            let where_ = t.dueDate.map { "due \(Fmt.due($0, hasTime: t.dueHasTime))" } ?? "in \(store.list(t.listID)?.name ?? "Inbox")"
            confirmationDetail = ", \(where_)"
            confirmation = "Added “\(t.title)”"
        case .note:
            store.addNote(body: raw)
            confirmationDetail = ""
            confirmation = "Note saved"
        case .memory:
            let item = MemoryCenter.shared.capture(text: raw)
            confirmationDetail = ""
            confirmation = item?.kind == .link ? "Link saved to Memory" : "Remembered"
        }
        finish()
    }

    /// Files dropped on the panel go into Memory, whichever mode it's in.
    private func drop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in fileProviders {
                if let url = await Self.fileURL(from: provider) { urls.append(url) }
            }
            let saved = MemoryCenter.shared.capture(fileURLs: urls)
            guard !saved.isEmpty else { return }
            withAnimation(Motion.snappy) { mode = .memory }
            confirmationDetail = ""
            confirmation = saved.count == 1 ? "Saved “\(saved[0].displayTitle)” to Memory" : "Saved \(saved.count) files to Memory"
            finish()
        }
        return true
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { done in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in done.resume(returning: url) }
        }
    }

    private func finish() {
        Haptics.success()
        text = ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { close() }
    }
}

// MARK: - Actions

@MainActor
enum MemoryActions {
    /// Remember in Messages: the thread goes into Memory, and a toast says so.
    static func rememberMessage(_ id: String, app: AppState) {
        guard MemoryCenter.shared.rememberMessage(id) != nil else {
            app.showToast("This message isn't in Docket's inbox any more")
            return
        }
        Haptics.success()
        app.showToast("Remembered. It's in Memory")
    }
}
