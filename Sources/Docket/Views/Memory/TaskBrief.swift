import MemoryKit
import SwiftUI

// A task's Brief: what memory knows that helps get it done (memory → tasks, never the other way round).

// MARK: - Answers

/// "Brief me" answers, one per task, kept for the session (not saved): reopening a task shows its answer
/// again until Refresh asks anew.
@MainActor
final class TaskBriefs: ObservableObject {
    static let shared = TaskBriefs()

    @Published private(set) var answers: [UUID: MemoryAnswer] = [:]
    @Published private(set) var running: Set<UUID> = []
    @Published private(set) var problems: [UUID: String] = [:]

    /// "What do I need to know to do: Send Jordan Lee the SOC 2 bridge letter?"
    static func question(for task: TaskItem) -> String {
        let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return "What do I need to know to do: \(title.isEmpty ? "this task" : title)?"
    }

    /// What memory is searched for: the task's title, notes and who it waits on.
    static func about(_ task: TaskItem) -> String {
        [task.title, task.notes, task.waitingOn.map { "Waiting on \($0)" } ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Asks memory about the task (needs a key). The answer replaces any earlier one.
    func brief(_ task: TaskItem) {
        guard !running.contains(task.id) else { return }
        guard let ai = MemoryCenter.shared.processor.ai else {
            problems[task.id] = MemoryText.noKey
            return
        }
        running.insert(task.id)
        problems[task.id] = nil
        let id = task.id, question = Self.question(for: task), about = Self.about(task)
        let library = MemoryCenter.shared.library
        Task { @MainActor in
            defer { running.remove(id) }
            do {
                let answer = try await MemoryAsk(ai: ai, sourceLimit: 6).ask(question, in: library, about: about)
                answers[id] = answer
            } catch {
                problems[id] = (error as? MemoryAIError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// Screenshots: an answer made without Gemini.
    func debugSet(_ answer: MemoryAnswer, for taskID: UUID) {
        answers[taskID] = answer
    }
}

// MARK: - The section

/// What memory knows about the open task, under its notes: up to three related memories (real dates), chips for
/// the people, organisations and projects it names (each opens its page) with their open promises, and "Brief
/// me", a short cited answer from memory. Open when there's something relevant, folded otherwise; hidden while
/// memory is empty.
struct TaskBriefSection: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: Store
    @ObservedObject private var briefs = TaskBriefs.shared
    @ObservedObject private var center = MemoryCenter.shared
    @ObservedObject private var library = MemoryCenter.shared.library
    let task: TaskItem

    @State private var context = TaskContext()
    @State private var loaded = false
    /// The user's own open/closed choice for this task; nil follows what's there.
    @State private var userExpanded: Bool?

    private var expanded: Bool { userExpanded ?? (!context.isEmpty || briefs.answers[task.id] != nil) }
    private var about: String { TaskBriefs.about(task) }

    var body: some View {
        VStack(spacing: 0) {
            if loaded, library.count > 0 {
                VStack(alignment: .leading, spacing: 0) {
                    Button { withAnimation(Motion.snappy) { userExpanded = !expanded } } label: { header }
                        .buttonStyle(.plain)
                        .help(expanded ? "Fold the brief" : "What memory knows about this task")
                    if expanded {
                        VStack(alignment: .leading, spacing: Space.md) {
                            memories
                            entities
                            answer
                        }
                        .padding(.horizontal, Space.md)
                        .padding(.bottom, Space.md)
                        .transition(.opacity)
                    }
                }
                .hairlineCard(radius: Radius.lg)
                .transition(.opacity)
            }
        }
        .task(id: about) { await load() }
        .onChange(of: task.id) { _ in
            userExpanded = nil
            context = TaskContext()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "brain")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.ink2)
                .frame(width: 18)
            Text("Brief")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.ink)
                .fixedSize()
            if !expanded {
                Text(foldedLine)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.ink2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: Space.xs)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.ink3)
                .rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .padding(.horizontal, Space.md)
        .frame(height: 40)
        .contentShape(Rectangle())
    }

    /// "Seed round: investor feedback +2 · Priya Shah", or what Brief can do when memory has nothing on it.
    private var foldedLine: String {
        var parts: [String] = []
        if let first = context.memories.first {
            parts.append(first.displayTitle + (context.memories.count > 1 ? " +\(context.memories.count - 1)" : ""))
        }
        parts += context.entities.prefix(2).map(\.entity.name)
        return parts.isEmpty ? "Nothing in memory on this yet" : parts.joined(separator: " · ")
    }

    // MARK: Related memories

    @ViewBuilder
    private var memories: some View {
        if !context.memories.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(context.memories) { item in
                    Button { app.reveal(memory: item.id) } label: {
                        HStack(spacing: Space.sm) {
                            MemoryKindTile(item: item, size: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.displayTitle)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color.ink)
                                    .lineLimit(1)
                                if !item.summary.isEmpty {
                                    Text(item.summary)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Color.ink2)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: Space.xs)
                            Text(MemoryText.date(item.createdAt, now: app.clock))
                                .font(.system(size: 12, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(Color.ink2)
                                .fixedSize()
                        }
                        .padding(.horizontal, Space.sm)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .hoverHighlight(cornerRadius: Radius.sm)
                    }
                    .buttonStyle(PressScale(scale: 0.985))
                    .help("Open in Memory")
                }
            }
            .padding(.horizontal, -Space.sm)
        }
    }

    // MARK: People, organisations, projects

    @ViewBuilder
    private var entities: some View {
        if !context.entities.isEmpty {
            let promises = context.entities.flatMap(\.promises)
            VStack(alignment: .leading, spacing: Space.sm) {
                FlowLayout(spacing: Space.sm, lineSpacing: Space.sm) {
                    ForEach(context.entities) { e in
                        SuggestionChip(title: e.entity.name, icon: e.entity.kind.symbolName) { app.reveal(entity: e.id) }
                            .help("Everything about \(e.entity.name)")
                    }
                }
                ForEach(promises) { p in promiseRow(p) }
            }
        }
    }

    private func promiseRow(_ p: TaskContext.Promise) -> some View {
        Button { app.reveal(memory: p.itemID) } label: {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Image(systemName: MemoryText.symbol(for: .promise))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.ink3)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.moment.text)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    if let line = MemoryText.promiseLine(p.moment, now: app.clock) {
                        Text(line)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(isLate(p.moment) ? Color.dangerText : Color.ink2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale(scale: 0.99))
        .help("Open “\(p.itemTitle)”")
    }

    private func isLate(_ m: Moment) -> Bool {
        guard let due = m.due else { return false }
        return Calendar.current.startOfDay(for: due) < Calendar.current.startOfDay(for: app.clock)
    }

    // MARK: Brief me

    @ViewBuilder
    private var answer: some View {
        let running = briefs.running.contains(task.id)
        VStack(alignment: .leading, spacing: Space.sm) {
            if !context.memories.isEmpty || !context.entities.isEmpty {
                Rectangle().fill(Color.hair).frame(height: 1)
            }
            if let answer = briefs.answers[task.id] {
                Text(Self.attributed(answer.text, sources: answer.sources.count))
                    .font(.system(size: 13.5))
                    .lineSpacing(3)
                    .foregroundStyle(answer.answered ? Color.bodyText : Color.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .environment(\.openURL, OpenURLAction { url in
                        guard let n = MemoryAnswerLinks.citation(url), let item = answer.item(forCitation: n) else { return .systemAction }
                        app.reveal(memory: item.id)
                        return .handled
                    })
            }
            HStack(spacing: Space.sm) {
                if running {
                    ThinkingDots(size: 5)
                    Text("Reading your memory…").textStyle(.caption).foregroundStyle(Color.ink2)
                } else if briefs.answers[task.id] == nil {
                    Button { briefs.brief(task) } label: { Label("Brief me", systemImage: "sparkles") }
                        .buttonStyle(SecondaryPill(height: 28))
                        .disabled(!center.hasAI)
                        .help(center.hasAI ? "Ask memory what you need to know to do this" : "Needs a Gemini key in Settings → AI")
                    Text(center.hasAI ? "A short answer from your memory, with sources" : "Needs a Gemini key")
                        .textStyle(.caption)
                        .foregroundStyle(Color.ink3)
                        .lineLimit(1)
                } else {
                    Text("From your memory").textStyle(.caption).foregroundStyle(Color.ink3)
                }
                Spacer(minLength: 0)
                if !running, briefs.answers[task.id] != nil {
                    Button { briefs.brief(task) } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(IconButtonStyle(size: 24))
                        .disabled(!center.hasAI)
                        .help(center.hasAI ? "Ask again" : "Needs a Gemini key in Settings → AI")
                        .accessibilityLabel("Refresh the brief")
                }
            }
            .frame(minHeight: 28)
            if let problem = briefs.problems[task.id], !running {
                MemoryNote(icon: "exclamationmark.triangle.fill", warning: true, text: problem)
            }
        }
    }

    /// The answer with each [n] as a small chip that opens its source.
    static func attributed(_ text: String, sources: Int) -> AttributedString {
        var out = AttributedString()
        for segment in CitationText.segments(text, valid: sources > 0 ? 1...sources : nil) {
            switch segment {
            case .text(let s): out += AttributedString(s)
            case .citation(let n): out += MemoryAnswerLinks.chip(n)
            }
        }
        return out
    }

    // MARK: Loading

    private func load() async {
        // Typing in the title shouldn't search on every keystroke.
        if loaded { try? await Task.sleep(nanoseconds: 350_000_000) }
        guard !Task.isCancelled else { return }
        let people = task.waitingOn.map { [$0] } ?? []
        let found = await center.taskContext(for: about, people: people, ai: center.processor.ai)
        guard !Task.isCancelled else { return }
        withAnimation(Motion.base) {
            context = found
            loaded = true
        }
    }
}

// MARK: - From memory: <title>

/// On a task made from a memory: "From memory: <title>", opening it.
struct TaskMemoryLink: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var library = MemoryCenter.shared.library
    let memoryID: UUID

    var body: some View {
        if let item = library.item(memoryID) {
            Button { app.reveal(memory: item.id) } label: {
                Label("From memory: \(item.displayTitle)", systemImage: "brain")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(SecondaryPill(truncates: true))
            .help("Open “\(item.displayTitle)” in Memory")
        }
    }
}

// MARK: - Add as task

/// On a promise in Memory (a memory's detail, a person's or project's page): "Add as task", or once it has one,
/// "Task added · Open". Done promises without a task offer nothing.
struct PromiseTaskButton: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: Store
    let moment: Moment
    let item: MemoryItem

    var body: some View {
        if let t = MemoryTasks.linkedTask(moment.id, in: store) {
            Button { app.reveal(task: t.id, in: store) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy))
                    Text("Task added · Open")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.ink2)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .fixedSize()
            }
            .buttonStyle(MenuChromeStyle(shape: Capsule(), fill: .fill, hoverFill: .fillStrong))
            .help("Open “\(t.title)”")
        } else if !moment.done {
            Button {
                let t = withAnimation(Motion.snappy) { MemoryTasks.add(moment, in: item, store: store) }
                app.showToast(MemoryTasks.toast(t, now: app.clock))
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus").font(.system(size: 9, weight: .heavy))
                    Text("Add as task")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.ink)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .overlay(Capsule().strokeBorder(Color.hairStrong, lineWidth: 1))
                .fixedSize()
            }
            .buttonStyle(MenuChromeStyle(shape: Capsule(), fill: .clear, hoverFill: .pressedTint))
            .help(moment.direction == .theirs && moment.who != nil
                  ? "A follow-up task, waiting on \(moment.who ?? "")" : "A task due on its date, linked to this memory")
        }
    }
}
