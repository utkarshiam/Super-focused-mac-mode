import AppKit
import SwiftUI

// The AI features (Google Gemini): the "Plan with AI" sheet, the sparkle in quick add, "Break down
// with AI" in a task's checklist, "Order my day" in the Calendar, and Settings → AI. Everything the
// model suggests is shown for review first; nothing changes until the user says so.

/// Where to get a Gemini API key (free).
private let aiStudioKeysURL = URL(string: "https://aistudio.google.com/apikey")

// MARK: - Plan with AI

/// "Plan with AI": describe what's on your mind, review the proposed tasks, add them.
struct AIPlanSheet: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var ai = AIService.shared
    @AppStorage(Prefs.Key.aiEnabled) private var aiEnabled = true
    let request: AIPlannerRequest

    private enum Step { case prompt, thinking, review }
    @State private var step: Step
    @State private var text: String
    @State private var items: [PlanItem]
    @State private var problem: PlanProblem?
    @State private var work: Task<Void, Never>?
    /// The page the planner was opened from: like quick add, planning on a list's page files the tasks
    /// there, a tag's page tags them, and Important makes them High (see `TaskDraft.filed(in:lists:)`).
    @State private var openedFrom: SidebarItem?
    /// Set once the tasks are added, so a second click while the sheet closes can't add them twice.
    @State private var didAdd = false
    @FocusState private var editorFocused: Bool

    init(request: AIPlannerRequest) {
        self.request = request
        _step = State(initialValue: request.drafts.isEmpty ? .prompt : .review)
        _text = State(initialValue: request.text)
        // Each card needs its own id, even if the same draft was handed in twice.
        var seen = Set<UUID>()
        _items = State(initialValue: request.drafts.map { draft in
            var d = draft
            if !seen.insert(d.id).inserted { d.id = UUID() }
            return PlanItem(draft: d)
        })
    }

    private var isNote: Bool { request.noteID != nil }
    /// Drafts handed in (a Slack or Gmail suggestion): there's no text to go back to.
    private var startedFromDrafts: Bool { !request.drafts.isEmpty }
    private var includedCount: Int { items.filter { $0.included && !$0.draft.title.trimmingCharacters(in: .whitespaces).isEmpty }.count }
    private var canRun: Bool {
        aiEnabled && ai.isConfigured && step != .thinking && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            switch step {
            case .prompt: promptStep
            case .thinking: thinkingStep
            case .review: reviewStep
            }
        }
        .transition(.opacity)
        // Short enough to hang inside the smallest main window (600 pt, less its title bar).
        .frame(width: 640, height: 560)
        .background(Color.raised)
        .tint(Color.ink)
        .onAppear { if openedFrom == nil { openedFrom = app.selection } }
        .onDisappear { work?.cancel() }
    }

    // MARK: Step 1: what's on your mind

    private var promptStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Space.md) {
                SheetHeader(
                    title: isNote ? "Find tasks in “\(store.note(request.noteID)?.title ?? "this note")”" : "Plan with AI",
                    subtitle: isNote
                        ? "Docket reads the note and suggests the tasks in it. Nothing is added until you've reviewed them."
                        : "Write it the way you'd say it. Docket turns it into tasks with dates, estimates and steps, for you to review.")
                    .padding(.bottom, Space.xs)
                editor
                Text(isNote ? "Trim anything you'd rather not send." : "Try “Board meeting Thursday 10am. Deck done by Wednesday, dry run before. Book flights for the offsite.”")
                    .textStyle(.footnote)
                    .foregroundStyle(Color.ink3)
                    .lineLimit(2)
                notice
            }
            .padding(.horizontal, Space.xxl)
            .padding(.top, Space.xxl)
            .padding(.bottom, Space.lg)

            SheetFooter {
                Label("Sent to Google Gemini", systemImage: "lock")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.ink3)
                    .help("Only this text and your list and tag names go to Google Gemini.")
                Spacer(minLength: Space.sm)
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryPill())
                    .keyboardShortcut(.cancelAction)
                    .help("Close (Esc)")
                Button(isNote ? "Find tasks" : "Make tasks", action: run)
                    .buttonStyle(PrimaryPill())
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canRun)
                    .help(isNote ? "Find the tasks in this text (⌘↩)" : "Turn this into tasks (⌘↩)")
            }
        }
        .task {
            // A sheet takes the keyboard a moment after it appears.
            try? await Task.sleep(nanoseconds: 150_000_000)
            editorFocused = true
        }
    }

    private var editor: some View {
        TextEditor(text: $text)
            .font(.system(size: 15))
            .foregroundStyle(Color.ink)
            .scrollContentBackground(.hidden)
            .focused($editorFocused)
            .padding(Space.md)
            .background(alignment: .topLeading) {
                if text.isEmpty {
                    // TextEditor has no placeholder: this sits under it, where its first line starts.
                    Text("What's on your mind?")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.ink3)
                        .padding(.leading, Space.md + 5)
                        .padding(.top, Space.md)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.fill))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .strokeBorder(editorFocused ? Color.ink.opacity(0.35) : Color.clear, lineWidth: 1.5)
            )
            .animation(Motion.fast, value: editorFocused)
    }

    /// AI switched off, no key yet, an error, or nothing found: said once, under the text.
    @ViewBuilder
    private var notice: some View {
        if !aiEnabled {
            AINotice(icon: "sparkles", message: "AI is turned off. You can turn it on in Settings → AI.",
                     actions: [NoticeAction("Open Settings", help: "Open Settings → AI") { SettingsView.show(.ai, app: app) }])
        } else if !ai.isConfigured {
            AINotice(icon: "key", message: "Add a Google Gemini API key in Settings → AI to use this. Keys are free from Google AI Studio.",
                     actions: [NoticeAction("Open Settings", help: "Open Settings → AI") { SettingsView.show(.ai, app: app) },
                               NoticeAction("Get a key", help: "Open Google AI Studio in your browser") { openAIStudio() }])
        } else if let problem {
            switch problem {
            case .failed(let message, let needsSettings):
                AINotice(icon: "exclamationmark.triangle", message: message, tone: .danger,
                         actions: [NoticeAction("Try again", help: "Send it again", run)]
                            + (needsSettings ? [NoticeAction("Open Settings", help: "Open Settings → AI") { SettingsView.show(.ai, app: app) }] : []))
            case .nothingFound:
                AINotice(icon: "text.magnifyingglass",
                         message: isNote ? "No tasks found in this note." : "No tasks found in that. Add a little more detail and try again.",
                         actions: [])
            }
        }
    }

    // MARK: Step 2: thinking

    private var thinkingStep: some View {
        VStack(spacing: Space.md) {
            Spacer()
            ThinkingDots()
                .padding(.bottom, Space.xs)
            Text("Thinking…")
                .textStyle(.title3)
                .foregroundStyle(Color.ink)
            Text(isNote ? "Reading the note for things to do." : "Turning your words into tasks.")
                .textStyle(.callout)
                .foregroundStyle(Color.ink2)
            Button("Cancel", action: cancel)
                .buttonStyle(SecondaryPill())
                .keyboardShortcut(.cancelAction)
                .help("Stop and go back (Esc)")
                .padding(.top, Space.md)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(Space.xxl)
    }

    // MARK: Step 3: review

    private var reviewStep: some View {
        let count = includedCount
        let allChecked = items.allSatisfy(\.included)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: Space.md) {
                SheetHeader(title: items.count == 1 ? "Review the task" : "Review \(items.count) tasks",
                            subtitle: items.count == 1
                                ? "Change anything before it's added. Click the title or a chip to edit it."
                                : "Uncheck any you don't want. Click a title or a chip to change it.")
                Spacer(minLength: Space.md)
                if items.count > 1 {
                    Button(allChecked ? "Select none" : "Select all") {
                        withAnimation(Motion.snappy) { for i in items.indices { items[i].included = !allChecked } }
                    }
                    .buttonStyle(SecondaryPill(height: 30))
                    .help(allChecked ? "Uncheck every task" : "Check every task")
                }
            }
            .padding(.horizontal, Space.xxl)
            .padding(.top, Space.xxl)
            .padding(.bottom, Space.lg)

            ScrollView {
                VStack(spacing: Space.sm) {
                    ForEach($items) { $item in
                        DraftCard(item: $item, lists: store.lists, now: app.clock)
                            .enterUp(items.firstIndex { $0.id == item.id } ?? 0)
                    }
                }
                .padding(.horizontal, Space.xxl)
                .padding(.bottom, Space.lg)
            }

            SheetFooter {
                Button(startedFromDrafts ? "Cancel" : "Back", action: back)
                    .buttonStyle(SecondaryPill())
                    .keyboardShortcut(.cancelAction)
                    .help(startedFromDrafts ? "Close without adding (Esc)" : "Back to your text (Esc)")
                Spacer(minLength: Space.sm)
                Button("Add \(Fmt.plural(count, "task"))", action: add)
                    .buttonStyle(PrimaryPill())
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(count == 0 || didAdd)
                    .help("Add the checked tasks (⌘↩)")
            }
        }
    }

    // MARK: Actions

    private func run() {
        guard canRun else { return }
        let input = text
        problem = nil
        work?.cancel()
        withAnimation(Motion.base) { step = .thinking }
        work = Task { @MainActor in
            do {
                let drafts: [TaskDraft]
                if let noteID = request.noteID, var note = store.note(noteID) {
                    note.body = input // what's left in the editor is what gets read
                    drafts = try await AIService.shared.findTasks(inNote: note, store: store)
                } else {
                    drafts = try await AIService.shared.planTasks(from: input, store: store)
                }
                try Task.checkCancellation()
                withAnimation(Motion.base) {
                    if drafts.isEmpty {
                        problem = .nothingFound
                        step = .prompt
                    } else {
                        items = drafts.map { PlanItem(draft: $0.filed(in: openedFrom, lists: store.lists)) }
                        step = .review
                    }
                }
            } catch is CancellationError {
                // Cancelled from the sheet: it has already gone back.
            } catch {
                guard !Task.isCancelled else { return }
                withAnimation(Motion.base) {
                    problem = PlanProblem(error)
                    step = .prompt
                }
            }
        }
    }

    private func cancel() {
        work?.cancel()
        work = nil
        withAnimation(Motion.base) { step = .prompt }
    }

    private func back() {
        if startedFromDrafts {
            dismiss()
        } else {
            withAnimation(Motion.base) { step = .prompt }
        }
    }

    private func add() {
        let chosen = items.filter { $0.included && !$0.draft.title.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !didAdd, !chosen.isEmpty else { return }
        didAdd = true
        // Tasks found in a note link back to it (no checklist line of their own, so no two-way sync).
        let noteID = request.noteID.flatMap { store.note($0) == nil ? nil : $0 }
        let tasks = chosen.map { item -> TaskItem in
            var t = item.draft.makeTask(lists: store.lists)
            t.linkedNoteID = noteID
            return t
        }
        let added = withAnimation(Motion.gentle) { store.addPlannedTasks(tasks) }
        Haptics.success()
        dismiss()
        app.showToast("Added \(Fmt.plural(added.count, "task"))")
        // From a suggestion, stay in the list being worked through; otherwise show where they went.
        if !startedFromDrafts, let first = added.first { show(first.id) }
    }

    /// Selects the first new task: right here when this list page shows it, otherwise where it lives
    /// (the Calendar scrolls to its day).
    private func show(_ id: UUID) {
        let here = app.selection.isTaskView && app.selection != .calendar && app.selection != .search
            && app.visibleTaskOrder(in: store).contains(id)
        guard here else { return app.reveal(task: id, in: store) }
        app.selectedTaskIDs = []
        withAnimation(Motion.sheet) { app.selectedTaskID = id }
    }
}

/// A draft in the review step: whether it's checked, and whether its steps are open.
private struct PlanItem: Identifiable {
    var draft: TaskDraft
    var included = true
    var showsSteps = false
    var id: UUID { draft.id }
}

private enum PlanProblem: Equatable {
    case failed(message: String, needsSettings: Bool)
    case nothingFound

    init(_ error: Error) {
        let aiError = error as? AIError
        self = .failed(message: error.localizedDescription, needsSettings: aiError?.needsSettings ?? false)
    }
}

/// One proposed task: checkbox, editable title, chips for date, estimate, priority and list,
/// anything else it carries (reminder, who it's waiting on, tags), its steps, and why it's suggested.
private struct DraftCard: View {
    @Binding var item: PlanItem
    let lists: [TaskList]
    let now: Date
    @State private var pickingDate = false
    @State private var newStep = ""

    private var draft: TaskDraft { item.draft }

    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            IncludeBox(on: item.included) { item.included.toggle() }
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 10) {
                TextField("Task title", text: $item.draft.title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(Color.ink)
                    .lineLimit(1...3)
                    .help("The task's title. Click to change it")
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    dateChip
                    estimateChip
                    priorityChip
                    listChip
                    if let reminder = reminderText {
                        RemovableChip(icon: draft.reminderIsAlarm ? "alarm" : "bell", text: reminder, help: "Remove the reminder") {
                            item.draft.reminderMinutesBefore = nil
                        }
                    }
                    if let person = draft.waitingOn {
                        RemovableChip(icon: "person", text: "Waiting on \(person)", help: "Not waiting on anyone") {
                            item.draft.waitingOn = nil
                        }
                    }
                    ForEach(draft.tags, id: \.self) { tag in
                        RemovableChip(icon: "number", text: tag, help: "Remove #\(tag)") {
                            item.draft.tags.removeAll { $0 == tag }
                        }
                    }
                }
                if !draft.subtasks.isEmpty { steps }
                if let reason = draft.reason {
                    Text(reason)
                        .textStyle(.caption)
                        .foregroundStyle(Color.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Space.lg)
        .hairlineCard(radius: Radius.lg)
        .opacity(item.included ? 1 : 0.5)
        .animation(Motion.fast, value: item.included)
    }

    // MARK: Chips

    private var dateChip: some View {
        let isPast = draft.due.map { d in
            draft.dueHasTime ? d < now : Calendar.current.startOfDay(for: d) < Calendar.current.startOfDay(for: now)
        } ?? false
        return Button { pickingDate = true } label: {
            ChipLabel(icon: "calendar", text: draft.due.map { Fmt.due($0, hasTime: draft.dueHasTime, now: now) } ?? "No date",
                      muted: draft.due == nil, tone: isPast ? .danger : nil)
        }
        .buttonStyle(MenuChromeStyle(shape: Capsule(), fill: isPast ? Tone.danger.bg : .fill, hoverFill: isPast ? Tone.danger.border : .fillStrong))
        .help(isPast ? "This date has passed. Click to change it" : "Deadline")
        .popover(isPresented: $pickingDate, arrowEdge: .bottom) {
            DatePopover(date: $item.draft.due, hasTime: $item.draft.dueHasTime, allowsTime: true, title: "Deadline",
                        close: { pickingDate = false })
        }
    }

    private var estimateChip: some View {
        let current = draft.estimateMinutes
        var choices = [5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240, 360, 480]
        // An estimate the model gave that isn't one of the usual steps still shows, checked.
        if let current, !choices.contains(current) { choices = (choices + [current]).sorted() }
        return Menu {
            Button { item.draft.estimateMinutes = nil } label: {
                if current == nil { Label("No estimate", systemImage: "checkmark") } else { Text("No estimate") }
            }
            Divider()
            ForEach(choices, id: \.self) { m in
                Button { item.draft.estimateMinutes = m } label: {
                    if m == current { Label(Fmt.duration(minutes: m), systemImage: "checkmark") } else { Text(Fmt.duration(minutes: m)) }
                }
            }
        } label: {
            ChipLabel(icon: "hourglass", text: draft.estimateMinutes.map { Fmt.duration(minutes: $0) } ?? "Estimate",
                      muted: draft.estimateMinutes == nil)
        }
        .menuChrome(Capsule())
        .help("How long it takes")
    }

    private var priorityChip: some View {
        let p = draft.priority
        return Menu {
            ForEach(Priority.allCases.reversed()) { option in
                Button { item.draft.priority = option } label: {
                    if option == p { Label(option.label, systemImage: "checkmark") } else { Text(option.label) }
                }
            }
        } label: {
            ChipLabel(icon: "flag", text: p == .none ? "Priority" : p.label, muted: p == .none, tone: p.tone)
        }
        .menuChrome(Capsule(), fill: p.tone?.bg ?? .fill, hoverFill: p.tone?.border ?? .fillStrong)
        .help("Priority")
    }

    private var listChip: some View {
        let list = TaskDraft.list(named: draft.listName, in: lists)
        return Menu {
            Button { item.draft.listName = nil } label: {
                if list == nil { Label("Inbox", systemImage: "checkmark") } else { Text("Inbox") }
            }
            if !lists.isEmpty { Divider() }
            ForEach(lists) { option in
                Button { item.draft.listName = option.name } label: {
                    if option.id == list?.id { Label(option.name, systemImage: "checkmark") } else { Text(option.name) }
                }
            }
        } label: {
            ChipLabel(icon: list?.icon ?? "tray", text: list?.name ?? "Inbox")
        }
        // A long list name shortens with "…" rather than pushing past the card.
        .menuChrome(Capsule(), truncates: true)
        .help("List")
    }

    private var reminderText: String? {
        guard draft.due != nil, let minutes = draft.reminderMinutesBefore else { return nil }
        let kind = draft.reminderIsAlarm ? "Alarm" : "Reminder"
        return minutes == 0 ? "\(kind) at the deadline" : "\(kind) \(Fmt.duration(minutes: minutes)) before"
    }

    // MARK: Steps

    private var steps: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(Motion.snappy) { item.showsSteps.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(item.showsSteps ? 90 : 0))
                    Text(Fmt.plural(draft.subtasks.count, "step"))
                }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.ink2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(item.showsSteps ? "Hide the steps" : "Show and edit the steps")

            if item.showsSteps {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(draft.subtasks.indices, id: \.self) { i in
                        HStack(spacing: Space.sm) {
                            Circle()
                                .strokeBorder(Color.ink3, lineWidth: 1.2)
                                .frame(width: 12, height: 12)
                            TextField("Step", text: step(at: i))
                                .textFieldStyle(.plain)
                                .font(.system(size: 13.5, weight: .medium))
                                .foregroundStyle(Color.ink)
                                .help("A step on the task's checklist. Click to change it")
                            Button {
                                withAnimation(Motion.base) {
                                    if item.draft.subtasks.indices.contains(i) { item.draft.subtasks.remove(at: i) }
                                }
                            } label: { Image(systemName: "minus") }
                                .buttonStyle(IconButtonStyle(size: 22))
                                .help("Remove this step")
                                .accessibilityLabel("Remove this step")
                        }
                        .frame(minHeight: 28)
                    }
                    HStack(spacing: Space.sm) {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.ink2)
                            .frame(width: 12)
                        TextField("Add a step", text: $newStep)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13.5, weight: .medium))
                            .help("Type a step and press Return")
                            .onSubmit {
                                let title = newStep.trimmingCharacters(in: .whitespaces)
                                guard !title.isEmpty else { return }
                                withAnimation(Motion.base) { item.draft.subtasks.append(title) }
                                newStep = ""
                            }
                    }
                    .frame(minHeight: 28)
                }
                .padding(.leading, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// A step's text, safe while steps are being removed.
    private func step(at i: Int) -> Binding<String> {
        Binding(get: { item.draft.subtasks.indices.contains(i) ? item.draft.subtasks[i] : "" },
                set: { if item.draft.subtasks.indices.contains(i) { item.draft.subtasks[i] = $0 } })
    }
}

/// The square "include this task" checkbox of a draft card.
private struct IncludeBox: View {
    var on: Bool
    var toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button {
            withAnimation(Motion.snappy) { toggle() }
            Haptics.select()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(on ? Color.primaryFill : (hovering ? Color.pressedTint : Color.clear))
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(on ? Color.primaryFill : Color.ink3, lineWidth: 1.5)
                if on {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(Color.onPrimary)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale(scale: 0.9))
        .onHover { h in withAnimation(Motion.fast) { hovering = h } }
        .help(on ? "Don't add this task" : "Add this task")
        .accessibilityLabel("Add this task")
        .accessibilityValue(on ? "Checked" : "Unchecked")
    }
}

/// Icon and text sized for a 26 pt chip; the chip's shape comes from `.menuChrome` or `MenuChromeStyle`.
private struct ChipLabel: View {
    var icon: String
    var text: String
    var muted = false
    var tone: Tone?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10.5, weight: .semibold))
            Text(text).lineLimit(1)
        }
        .font(.system(size: 12.5, weight: .semibold))
        .foregroundStyle(tone?.fg ?? (muted ? Color.ink3 : Color.ink))
        .padding(.horizontal, 10)
        .frame(height: 26)
    }
}

/// A chip with a ✕ for something the draft carries that can only be removed here.
private struct RemovableChip: View {
    var icon: String
    var text: String
    var help: String
    var remove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10.5, weight: .semibold))
            Text(text).lineLimit(1)
            Button {
                withAnimation(Motion.snappy) { remove() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .padding(6).contentShape(Rectangle()).padding(-6)
            }
            .buttonStyle(.plain)
            .help(help)
            .accessibilityLabel(help)
        }
        .font(.system(size: 12.5, weight: .semibold))
        .foregroundStyle(Color.ink)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Capsule().fill(Color.fill))
    }
}

/// Title and one line of explanation at the top of the sheet.
private struct SheetHeader: View {
    var title: String
    var subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .textStyle(.title2)
                .foregroundStyle(Color.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(subtitle)
                .textStyle(.callout)
                .foregroundStyle(Color.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The sheet's bottom bar: a hairline, then the buttons.
private struct SheetFooter<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.hair).frame(height: 1)
            HStack(spacing: Space.sm) { content }
                .padding(.horizontal, Space.xxl)
                .frame(height: 68)
        }
    }
}

private struct NoticeAction {
    var title: String
    var help: String
    var run: () -> Void

    init(_ title: String, help: String, _ run: @escaping () -> Void) {
        self.title = title
        self.help = help
        self.run = run
    }
}

/// A calm inline message (AI off, no key, an error) with its buttons.
private struct AINotice: View {
    var icon: String
    var message: String
    var tone: Tone = .neutral
    var actions: [NoticeAction]

    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tone == .danger ? Color.dangerText : Color.ink2)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: Space.sm) {
                Text(message)
                    .textStyle(.subhead)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if !actions.isEmpty {
                    HStack(spacing: Space.sm) {
                        ForEach(actions, id: \.title) { action in
                            Button(action.title, action: action.run)
                                .buttonStyle(SecondaryPill(height: 28))
                                .help(action.help)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(tone.bg))
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(tone.border, lineWidth: 1))
        .transition(.opacity.combined(with: .offset(y: -4)))
    }
}

/// Three dots breathing in turn while Gemini thinks. Still (and half-lit) with Reduce Motion.
/// Driven by the clock rather than a repeating animation, so it can never sway the layout around it.
private struct ThinkingDots: View {
    var size: CGFloat = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: size * 0.75) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.ink)
                        .frame(width: size, height: size)
                        .opacity(reduceMotion ? 0.5 : Self.brightness(at: time, dot: i))
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Thinking")
    }

    /// 0.2…0.85 on a 1.2 s breath, each dot 0.2 s behind the one before it.
    static func brightness(at time: TimeInterval, dot: Int) -> Double {
        let period = 1.2
        var phase = (time - Double(dot) * 0.2).truncatingRemainder(dividingBy: period) / period
        if phase < 0 { phase += 1 }
        return 0.2 + 0.65 * (0.5 - 0.5 * cos(phase * 2 * .pi))
    }
}

@MainActor
private func openAIStudio() {
    if let url = aiStudioKeysURL { NSWorkspace.shared.open(url) }
}

// MARK: - Quick add sparkle

/// Sparkle button inside the quick-add field: plans what was typed with AI.
struct AIQuickAddButton: View {
    @EnvironmentObject var app: AppState
    @AppStorage(Prefs.Key.aiEnabled) private var aiEnabled = true
    @Binding var text: String
    /// The quick-add field's day (Calendar). The planner keeps the dates the AI reads from the text.
    let day: Date?

    init(text: Binding<String>, day: Date?) {
        _text = text
        self.day = day
    }

    var body: some View {
        if aiEnabled {
            Button {
                let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                text = ""
                // The field may sit in a floating panel: the planner opens over the main window.
                app.showMainWindow()
                app.aiPlanner = AIPlannerRequest(text: typed)
            } label: {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.ink2)
            }
            .buttonStyle(IconButtonStyle(size: 26))
            // Where there's a quick-add field, ⌘J takes what's typed in it along (the menu item can't see it).
            .keyboardShortcut("j", modifiers: .command)
            .help("Plan with AI (⌘J)")
            .accessibilityLabel("Plan with AI")
        }
    }
}

// MARK: - Break down with AI

/// "Break down with AI" in a task's checklist card: proposes steps (and an estimate) inline,
/// to add or dismiss.
struct AIBreakdownRow: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    @AppStorage(Prefs.Key.aiEnabled) private var aiEnabled = true
    let taskID: UUID

    private enum Phase: Equatable {
        case idle
        case thinking
        case proposal(steps: [String], estimate: Int?)
        /// Already one step; maybe an estimate to offer.
        case singleStep(estimate: Int?)
        case failed(message: String, needsSettings: Bool)
    }

    @State private var phase: Phase = .idle
    @State private var work: Task<Void, Never>?
    @State private var hovering = false

    init(taskID: UUID) {
        self.taskID = taskID
    }

    var body: some View {
        if aiEnabled, let task = store.task(taskID), !task.isCompleted {
            VStack(alignment: .leading, spacing: 0) {
                Rectangle().fill(Color.hair).frame(height: 1).padding(.leading, 42)
                Group {
                    switch phase {
                    case .idle:
                        idleRow
                    case .thinking:
                        thinkingRow
                    case .proposal(let steps, let estimate):
                        proposal(steps, estimate: estimate, task: task)
                    case .singleStep(let estimate):
                        singleStep(estimate: task.estimateMinutes == nil ? estimate : nil)
                    case .failed(let message, let needsSettings):
                        failure(message, needsSettings: needsSettings)
                    }
                }
                .transition(.opacity)
            }
            .animation(Motion.base, value: phase)
            // A proposal belongs to one task: never offer it on another one shown in the same place.
            .onChange(of: taskID) { _ in stop() }
            // Hidden mid-request (the task was ticked off, AI switched off): stop, so the row can't
            // come back stuck on "Thinking" with nothing running.
            .onDisappear { if phase == .thinking { stop() } else { work?.cancel() } }
        }
    }

    private var idleRow: some View {
        Button(action: start) {
            HStack(spacing: Space.md) {
                sparkle
                Text("Break down with AI")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(hovering ? Color.ink : Color.ink2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.md)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale(scale: 0.99))
        .onHover { h in withAnimation(Motion.fast) { hovering = h } }
        .help("Suggest steps and an estimate for this task")
    }

    private var thinkingRow: some View {
        HStack(spacing: Space.md) {
            sparkle
            Text("Thinking")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.ink2)
            ThinkingDots(size: 5)
            Spacer(minLength: 0)
            Button(action: stop) { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle(size: 24))
                .help("Stop")
                .accessibilityLabel("Stop")
        }
        .padding(.horizontal, Space.md)
        .frame(height: 44)
    }

    private func proposal(_ steps: [String], estimate: Int?, task: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: Space.md) {
                sparkle
                Text(estimate.map { "Suggested steps · about \(Fmt.duration(minutes: $0))" } ?? "Suggested steps")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.ink)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .center, spacing: Space.sm) {
                        Text("\(i + 1)")
                            .font(.system(size: 11.5, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(Color.ink3)
                            .frame(width: 18, alignment: .trailing)
                        Text(step)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(Color.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button {
                            var rest = steps
                            rest.remove(at: i)
                            phase = rest.isEmpty ? .idle : .proposal(steps: rest, estimate: estimate)
                        } label: { Image(systemName: "minus") }
                            .buttonStyle(IconButtonStyle(size: 22))
                            .help("Leave this step out")
                            .accessibilityLabel("Leave this step out")
                    }
                    .frame(minHeight: 26)
                }
            }
            HStack(spacing: Space.sm) {
                Button("Add steps") { add(steps, estimate: task.estimateMinutes == nil ? estimate : nil) }
                    .buttonStyle(SecondaryPill(height: 30))
                    .help(task.estimateMinutes == nil && estimate != nil
                          ? "Add these steps to the checklist and set the estimate"
                          : "Add these steps to the checklist")
                Button("Dismiss") { phase = .idle }
                    .buttonStyle(PressScale())
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.ink2)
                    .padding(.horizontal, Space.sm)
                    .help("Don't add them")
            }
            .padding(.leading, 18 + Space.md)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, 12)
    }

    private func singleStep(estimate: Int?) -> some View {
        HStack(spacing: Space.md) {
            sparkle
            Text("Already a single step.")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Color.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.sm)
            if let estimate {
                Button("Set \(Fmt.duration(minutes: estimate))") { add([], estimate: estimate) }
                    .buttonStyle(SecondaryPill(height: 28))
                    .help("Use this as the estimate")
            }
            Button { phase = .idle } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle(size: 24))
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
    }

    private func failure(_ message: String, needsSettings: Bool) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .top, spacing: Space.md) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dangerText)
                    .frame(width: 18)
                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Space.sm) {
                Button("Try again", action: start)
                    .buttonStyle(SecondaryPill(height: 28))
                    .help("Ask again")
                if needsSettings {
                    Button("Open Settings") { SettingsView.show(.ai, app: app) }
                        .buttonStyle(SecondaryPill(height: 28))
                        .help("Open Settings")
                }
                Button { phase = .idle } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle(size: 24))
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss")
            }
            .padding(.leading, 18 + Space.md)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, 12)
    }

    private var sparkle: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.ink2)
            .frame(width: 18)
    }

    private func start() {
        guard let task = store.task(taskID) else { return }
        work?.cancel()
        phase = .thinking
        work = Task { @MainActor in
            do {
                let result = try await AIService.shared.breakDown(task, store: store)
                try Task.checkCancellation()
                phase = result.subtasks.isEmpty
                    ? .singleStep(estimate: result.estimateMinutes)
                    : .proposal(steps: result.subtasks, estimate: result.estimateMinutes)
            } catch is CancellationError {
                // Stopped, or the task was closed.
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(message: error.localizedDescription, needsSettings: (error as? AIError)?.needsSettings ?? false)
            }
        }
    }

    private func stop() {
        work?.cancel()
        work = nil
        phase = .idle
    }

    /// Appends the steps (skipping any the checklist already has, say typed while Gemini was thinking)
    /// and fills in the estimate if the task has none: one undo step.
    private func add(_ steps: [String], estimate: Int?) {
        // Only from a proposal on screen: a second click as it closes adds nothing more.
        guard phase != .idle, phase != .thinking else { return }
        guard let task = store.task(taskID) else { return stop() }
        let fold = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        var seen = Set(task.subtasks.map { fold($0.title) })
        let fresh = steps.filter { seen.insert(fold($0)).inserted }
        let setsEstimate = task.estimateMinutes == nil ? estimate : nil
        withAnimation(Motion.base) {
            phase = .idle
            guard !fresh.isEmpty || setsEstimate != nil else { return }
            store.mutateTask(taskID, undo: fresh.isEmpty ? "Set Estimate" : "Add Steps") { t in
                t.subtasks += fresh.map { Subtask(title: $0) }
                if t.estimateMinutes == nil, let setsEstimate { t.estimateMinutes = setsEstimate }
            }
        }
        switch (fresh.count, setsEstimate) {
        case (0, nil):
            app.showToast("The checklist already has those steps")
        case (0, let minutes?):
            Haptics.success()
            app.showToast("Estimate set to \(Fmt.duration(minutes: minutes))")
        case (let n, let minutes?):
            Haptics.success()
            app.showToast("Added \(Fmt.plural(n, "step")) · estimate \(Fmt.duration(minutes: minutes))")
        case (let n, nil):
            Haptics.success()
            app.showToast("Added \(Fmt.plural(n, "step"))")
        }
    }
}

// MARK: - Order my day

/// Sparkle button in the Calendar header that suggests an order for today's tasks.
/// Applying it only reorders today's tasks that have no time; no date ever changes.
struct OrderMyDayButton: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    @AppStorage(Prefs.Key.aiEnabled) private var aiEnabled = true
    @State private var open = false

    var body: some View {
        if aiEnabled {
            let count = AIActions.untimedToday(in: store, now: app.clock).count
            Button { open = true } label: { Image(systemName: "sparkles") }
                .buttonStyle(IconButtonStyle(filled: true))
                .disabled(count < 2)
                .help(count < 2 ? "Order my day with AI: needs two or more tasks without a time today" : "Order my day with AI")
                .accessibilityLabel("Order my day with AI")
                .popover(isPresented: $open, arrowEdge: .bottom) {
                    OrderDayPopover(close: { open = false })
                        .environmentObject(store)
                        .environmentObject(app)
                }
        }
    }
}

/// The suggested order with a reason per task; "Apply order" sets today's manual order in one undo step.
private struct OrderDayPopover: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    var close: () -> Void

    private struct Pick: Identifiable {
        var id: UUID
        var title: String
        var reason: String
        var minutes: Int
    }

    private enum Phase {
        case thinking
        case ready([Pick], unchanged: Bool)
        case failed(message: String, needsSettings: Bool)
    }

    @State private var phase: Phase = .thinking
    @State private var attempt = 0
    /// Set once the order is applied, so a second click as the popover closes records nothing more.
    @State private var applied = false

    var body: some View {
        let today = Calendar.current.startOfDay(for: app.clock)
        let count = AIActions.untimedToday(in: store, now: app.clock).count
        VStack(alignment: .leading, spacing: Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Order my day")
                    .font(.system(size: 17, weight: .bold))
                    .tracking(-0.2)
                    .foregroundStyle(Color.ink)
                Text("\(Fmt.absoluteDay(today, now: app.clock)) · \(Fmt.plural(count, "task")) without a time")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.ink2)
            }

            switch phase {
            case .thinking:
                HStack(spacing: Space.sm) {
                    ThinkingDots(size: 6)
                    Text("Thinking about your day")
                        .textStyle(.subhead)
                        .foregroundStyle(Color.ink2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Space.lg)
            case .ready(let picks, let unchanged):
                if unchanged {
                    Text("Your current order already looks right.")
                        .textStyle(.subhead)
                        .foregroundStyle(Color.ink2)
                }
                if picks.count > 7 {
                    ScrollView { pickList(picks) }
                        .frame(height: 380)
                } else {
                    pickList(picks)
                }
            case .failed(let message, let needsSettings):
                AINotice(icon: "exclamationmark.triangle", message: message, tone: .danger,
                         actions: [NoticeAction("Try again", help: "Ask again") { attempt += 1 }]
                            + (needsSettings ? [NoticeAction("Open Settings", help: "Open Settings → AI") { SettingsView.show(.ai, app: app) }] : []))
            }

            HStack(spacing: Space.sm) {
                Spacer(minLength: 0)
                Button("Cancel", action: close)
                    .buttonStyle(SecondaryPill(height: 32))
                    .keyboardShortcut(.cancelAction)
                    .help("Keep the current order (Esc)")
                Button("Apply") {
                    if case .ready(let picks, _) = phase { apply(picks) }
                }
                .buttonStyle(PrimaryPill(height: 32))
                .keyboardShortcut(.defaultAction)
                .disabled(!canApply)
                .help("Put today's tasks in this order (↩)")
            }
        }
        .padding(Space.lg)
        .frame(width: 380)
        .background(Color.raised)
        .tint(Color.ink)
        .task(id: attempt) { await suggest() }
    }

    private var canApply: Bool {
        if !applied, case .ready(let picks, let unchanged) = phase { return !unchanged && picks.count > 1 }
        return false
    }

    private func pickList(_ picks: [Pick]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(picks.enumerated()), id: \.element.id) { i, pick in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(i + 1)")
                        .font(.system(size: 11.5, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Color.ink2)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.fill))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pick.title)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Color.ink)
                            .lineLimit(2)
                        if !pick.reason.isEmpty {
                            Text(pick.reason)
                                .textStyle(.caption)
                                .foregroundStyle(Color.ink3)
                                .lineLimit(2)
                        }
                    }
                    .padding(.top, 2)
                    Spacer(minLength: Space.sm)
                    if pick.minutes > 0 {
                        Text(Fmt.duration(minutes: pick.minutes))
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Color.ink2)
                            .padding(.top, 4)
                    }
                }
                .enterUp(i)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func suggest() async {
        phase = .thinking
        let tasks = AIActions.dayToOrder(in: store, now: app.clock)
        do {
            let order = try await AIService.shared.orderDay(tasks)
            let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let picks = order.compactMap { entry in
                byID[entry.id].map { Pick(id: $0.id, title: $0.title, reason: entry.reason, minutes: $0.remainingMinutes) }
            }
            withAnimation(Motion.base) { phase = .ready(picks, unchanged: picks.map(\.id) == tasks.map(\.id)) }
        } catch is CancellationError {
            // The popover closed.
        } catch {
            guard !Task.isCancelled else { return }
            withAnimation(Motion.base) {
                phase = .failed(message: error.localizedDescription, needsSettings: (error as? AIError)?.needsSettings ?? false)
            }
        }
    }

    /// Ranks today's untimed tasks 1…n in the suggested order (anything added since keeps its place
    /// after them). Ranks only: no date changes.
    private func apply(_ picks: [Pick]) {
        guard !applied else { return }
        applied = true
        let current = AIActions.dayToOrder(in: store, now: app.clock).map(\.id)
        let stillToday = Set(current)
        var ids = picks.map(\.id).filter { stillToday.contains($0) }
        let placed = Set(ids)
        ids += current.filter { !placed.contains($0) }
        guard ids.count > 1 else { return close() }
        withAnimation(Motion.gentle) {
            store.setRanks(Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, Double($0 + 1)) }), undo: "Order My Day")
        }
        Haptics.success()
        app.showToast("Reordered \(Fmt.plural(ids.count, "task")) for \(Fmt.absoluteDay(app.clock, now: app.clock))")
        close()
    }
}

// MARK: - Settings → AI

/// Settings → AI: the "Use AI" switch, the Gemini key (kept in the keychain, never shown), the model,
/// a connection test, and what gets sent.
struct AISettingsPage: View {
    @AppStorage(Prefs.Key.aiEnabled) private var aiEnabled = true
    @ObservedObject private var ai = AIService.shared
    @State private var keyDraft = ""
    @State private var modelDraft = ""
    @State private var modelSave: Task<Void, Never>?
    @State private var test: TestState = .idle
    @State private var testWork: Task<Void, Never>?

    private enum TestState: Equatable { case idle, running, passed(String), failed(String) }
    private enum KeySource { case settings, bundled, environment, none }

    var body: some View {
        let source = keySource
        SettingsPage {
            SettingsSection(title: "Google Gemini",
                            footer: "Only the text you send to an AI feature (and your list and tag names) goes to Google Gemini. "
                                + "With Slack or Gmail connected, new messages are sent too, to pick out the ones that need you.") {
                ToggleRow(title: "Use AI",
                          subtitle: "Plan tasks from a brain dump, break tasks into steps, order your day and find tasks in notes",
                          isOn: Binding(get: { aiEnabled }, set: { on in
                              aiEnabled = on
                              ai.settingsChanged()
                          }),
                          divider: false)
                    .help(aiEnabled ? "Turn off every AI feature. Nothing is sent to Gemini while it's off"
                                    : "Turn on the AI features")
            }

            SettingsSection(title: "API key", footer: keyFooter(source)) {
                SettingsRow(title: "Gemini API key", subtitle: keyStatus(source)) {
                    HStack(spacing: Space.sm) {
                        SecureField(source == .settings ? "Paste a new key" : "Paste your key", text: $keyDraft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 10)
                            .frame(width: 180, height: 30)
                            .background(RoundedRectangle(cornerRadius: Radius.xs, style: .continuous).fill(Color.fill))
                            .onSubmit(saveKey)
                            .help("Your key is kept in the macOS keychain and never shown again")
                        Button("Save", action: saveKey)
                            .buttonStyle(SecondaryPill(height: 30))
                            .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .help("Save the key and check that it works")
                        if source == .settings {
                            Button("Remove", action: removeKey)
                                .buttonStyle(SecondaryPill(height: 30))
                                .help("Delete your key from the keychain")
                        }
                    }
                }
                SettingsRow(title: "Model", subtitle: "Using \(Secrets.geminiModel)") {
                    TextField(Secrets.defaultGeminiModel, text: $modelDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 10)
                        .frame(width: 180, height: 30)
                        .background(RoundedRectangle(cornerRadius: Radius.xs, style: .continuous).fill(Color.fill))
                        .onSubmit(saveModel)
                        .help("Leave empty for the default, \(Secrets.defaultGeminiModel)")
                }
                if source == .none {
                    SettingsRow(title: "Get a key", subtitle: "Free from Google AI Studio, with your Google account") {
                        Button("Open AI Studio") { openAIStudio() }
                            .buttonStyle(SecondaryPill(height: 30))
                            .help("Open Google AI Studio in your browser")
                    }
                }
                SettingsRow(title: "Test connection", subtitle: testLine, divider: false) {
                    HStack(spacing: Space.sm) {
                        switch test {
                        case .running: ThinkingDots(size: 5)
                        case .passed: Badge(text: "Works", tone: .success, icon: "checkmark")
                        case .failed: Badge(text: "Failed", tone: .danger)
                        case .idle: EmptyView()
                        }
                        Button("Test", action: runTest)
                            .buttonStyle(SecondaryPill(height: 30))
                            .disabled(source == .none || test == .running)
                            .help("Send a tiny request to Gemini with this key and model")
                    }
                }
            }
            .disabled(!aiEnabled)
            .opacity(aiEnabled ? 1 : 0.45)
        }
        .onAppear { modelDraft = Keychain.string(Keychain.Account.geminiModel) ?? "" }
        .onChange(of: modelDraft) { _ in
            // Saved a moment after typing stops (and on Return).
            modelSave?.cancel()
            modelSave = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 700_000_000)
                if !Task.isCancelled { saveModel() }
            }
        }
        .onDisappear {
            modelSave?.cancel()
            saveModel()
            testWork?.cancel()
            // The Settings window is reused: a test cut short isn't left "Asking Gemini…" (Test disabled) for next time.
            if test == .running { test = .idle }
        }
    }

    // MARK: Key

    private var keySource: KeySource {
        let own = Keychain.string(Keychain.Account.geminiAPIKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !own.isEmpty { return .settings }
        if Secrets.geminiKeyIsBundled { return .bundled }
        if Secrets.geminiAPIKey != nil { return .environment }
        return .none
    }

    private func keyStatus(_ source: KeySource) -> String {
        switch source {
        case .settings: "Saved in your keychain"
        case .bundled: "Built into this copy of Docket"
        case .environment: "From GEMINI_API_KEY"
        case .none: "Not set yet"
        }
    }

    private func keyFooter(_ source: KeySource) -> String {
        switch source {
        case .settings: "Your own key, kept in the macOS keychain. Docket never shows it or writes it anywhere else."
        case .bundled: "Using the key built into this copy of Docket. Paste your own to use that instead."
        case .environment: "Using the key in the GEMINI_API_KEY environment variable. Paste one here to keep it in the keychain instead."
        case .none: "Paste a Gemini API key to use AI. It's kept in the macOS keychain and never shown again."
        }
    }

    private func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        Keychain.set(key, for: Keychain.Account.geminiAPIKey)
        keyDraft = ""
        ai.settingsChanged()
        runTest()
    }

    private func removeKey() {
        Keychain.set(nil, for: Keychain.Account.geminiAPIKey)
        testWork?.cancel()
        test = .idle
        ai.settingsChanged()
    }

    // MARK: Model

    private func saveModel() {
        let model = modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model != (Keychain.string(Keychain.Account.geminiModel) ?? "") else { return }
        Keychain.set(model.isEmpty ? nil : model, for: Keychain.Account.geminiModel)
        if test != .running { test = .idle }
        ai.settingsChanged()
    }

    // MARK: Test

    private var testLine: String? {
        switch test {
        case .idle: "Checks the key and model with a tiny request"
        case .running: "Asking Gemini…"
        case .passed(let line), .failed(let line): line
        }
    }

    private func runTest() {
        modelSave?.cancel()
        saveModel()
        testWork?.cancel()
        withAnimation(Motion.fast) { test = .running }
        testWork = Task { @MainActor in
            do {
                let line = try await AIService.shared.testConnection()
                withAnimation(Motion.base) { test = .passed(line) }
            } catch is CancellationError {
                // Left the page.
            } catch {
                guard !Task.isCancelled else { return }
                // The messages point to "Settings → AI", which is this page.
                let message = error.localizedDescription.replacingOccurrences(of: " in Settings → AI", with: " above")
                withAnimation(Motion.base) { test = .failed(message) }
            }
        }
    }
}

// MARK: - Actions

enum AIActions {
    /// Opens the planner with the note's text; the tasks it creates link back to the note.
    /// The text is what will be sent, so it's what the user reviews: photos and videos appear as
    /// "Photo: Whiteboard" (no file paths), and a very long note shows where it was cut.
    @MainActor
    static func findTasks(inNote noteID: UUID, app: AppState, store: Store) {
        guard let note = store.note(noteID) else { return }
        let text = AIPrompts.noteInput(note)
        guard !text.isEmpty else {
            app.showToast("This note is empty")
            return
        }
        app.aiPlanner = AIPlannerRequest(text: text, noteID: noteID)
    }

    /// Today's open tasks without a set time, in their current order: what "Order my day" rearranges.
    /// Overdue and timed tasks keep their own places (as in `Store.dayList`).
    @MainActor
    static func dayToOrder(in store: Store, now: Date) -> [TaskItem] {
        store.dayOrdered(untimedToday(in: store, now: now))
    }

    /// The same tasks in no particular order: enough to count them.
    @MainActor
    static func untimedToday(in store: Store, now: Date) -> [TaskItem] {
        let cal = store.calendar
        let today = cal.startOfDay(for: now)
        return store.tasks.filter { t in
            guard !t.isCompleted, !store.isOverdueByDay(t, today: today), store.calendarDay(of: t, today: today) == today else { return false }
            if t.dueHasTime, let due = t.dueDate, cal.isDate(due, inSameDayAs: today) { return false }
            return true
        }
    }
}
