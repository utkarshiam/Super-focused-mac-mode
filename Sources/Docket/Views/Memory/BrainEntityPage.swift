import AppKit
import MemoryKit
import SwiftUI

/// A brain page, on the right of Memory like an open memory: where it sits (breadcrumb), its name (click to
/// rename), what it is and when it was seen, "What you know" with citation chips, notes that disagree, key
/// facts, open questions, open promises and decisions, sub-topics, related things and the timeline. The ⋯
/// menu holds the corrections (rename, merge, split, move, lock, delete). Without a key the page has no
/// summary, just a one-line hint, and everything else still works.
struct BrainEntityPage: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var center = MemoryCenter.shared
    @ObservedObject private var brain = MemoryCenter.shared.brain
    @ObservedObject private var library = MemoryCenter.shared.library
    let entityID: UUID

    @State private var name = ""
    @FocusState private var nameFocused: Bool
    @State private var editingSummary = false
    @State private var draft = ""
    @State private var newFact = ""
    @State private var problem: String?
    @State private var merging = false
    @State private var timelineExpanded = false

    var body: some View {
        if let e = brain.entity(entityID) {
            content(e)
                .background(Color.paper)
                .onAppear { name = e.name }
                .onChange(of: e.name) { name = $0 }
                .onChange(of: nameFocused) { focused in if !focused { commitName() } }
                .sheet(isPresented: $merging) {
                    BrainMergeSheet(source: e) { target in
                        if brain.merge(e.id, into: target.id) {
                            app.showToast("Merged into \(target.name)")
                            app.selectedEntityID = brain.entity(target.id) != nil ? target.id : nil
                        }
                    }
                }
        }
    }

    private func content(_ e: BrainEntity) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                topBar(e)
                VStack(alignment: .leading, spacing: Space.sm) {
                    TextField(e.name, text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 22, weight: .bold))
                        .tracking(-0.4)
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                        .focused($nameFocused)
                        .onSubmit(commitName)
                        .help("Click to rename")
                    meta(e)
                }
                .padding(.top, -Space.sm)
                summary(e)
                disagreements(e)
                facts(e)
                questions(e)
                moments(e)
                subTopics(e)
                related(e)
                timeline(e)
                footer(e)
            }
            .padding(Space.xl)
        }
    }

    // MARK: Top

    private func topBar(_ e: BrainEntity) -> some View {
        HStack(spacing: Space.sm) {
            breadcrumb(e)
            Spacer(minLength: Space.sm)
            if isWriting(e) {
                ProgressView().controlSize(.small).help("Docket is writing this page")
            }
            correctionsMenu(e)
            Button { withAnimation(Motion.sheet) { app.selectedEntityID = nil } } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle(size: 28, filled: true))
                .keyboardShortcut(.cancelAction)
                .help("Close")
        }
    }

    /// "Product › Pricing" for topics (each step opens), or the kind for people, organisations and projects.
    @ViewBuilder
    private func breadcrumb(_ e: BrainEntity) -> some View {
        let path = brain.path(to: e.id).dropLast()
        if e.kind.isTaxonomy && !path.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: e.kind.symbolName)
                    .font(.system(size: 10.5, weight: .semibold))
                ForEach(Array(path), id: \.id) { step in
                    Button(step.name) { open(step.id) }
                        .buttonStyle(.plain)
                        .lineLimit(1)
                        .help("Open \(step.name)")
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Color.ink3)
                }
                Text(e.name).foregroundStyle(Color.ink3).lineLimit(1)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.ink2)
        } else {
            Label(e.kind.label(library.vocabulary), systemImage: e.kind.symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.ink2)
                .lineLimit(1)
        }
    }

    /// "Topic · 4 memories · 2 sub-topics", then when it was first and last seen.
    private func meta(_ e: BrainEntity) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(BrainText.meta(e, subTopics: brain.children(of: e.id).count, vocabulary: library.vocabulary))
                if e.locks.any {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9.5, weight: .semibold))
                        .help("Locked: Docket won't rename, move or refile it")
                }
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Color.ink2)
            if let seen = BrainText.seen(first: e.firstSeen, last: e.lastSeen, now: app.clock) {
                Text(seen)
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.ink3)
            }
            if let others = e.kind.isExtracted ? BrainText.aliases(e) : nil {
                Text(others)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.ink3)
                    .lineLimit(2)
            }
        }
    }

    // MARK: Corrections

    private func correctionsMenu(_ e: BrainEntity) -> some View {
        Menu {
            Button("Rename") { nameFocused = true }
            if center.hasAI {
                Button("Write Page Again") { write(e.id) }
                    .disabled(isWriting(e) || e.itemCount == 0)
            }
            Divider()
            Button("Merge Into…") { merging = true }
            let others = e.aliases.filter { EntityPicker.fold($0) != EntityPicker.fold(e.name) }
            if !others.isEmpty {
                Menu(e.kind.isExtracted ? "Split Off" : "Forget Name") {
                    ForEach(others, id: \.self) { alias in
                        Button(alias) { split(alias, from: e) }
                    }
                }
            }
            if e.kind == .topic {
                Menu("Move To") {
                    Button("Top Level") { move(e, to: nil) }
                        .disabled(e.parentID == nil)
                    let areas = brain.areas()
                    if !areas.isEmpty {
                        Section(EntityKind.area.pluralLabel()) {
                            ForEach(areas) { a in
                                Button(a.name) { move(e, to: a.id) }.disabled(a.id == e.parentID)
                            }
                        }
                    }
                    let parents = brain.allTopics().filter { t in
                        t.id != e.id && brain.entity(t.parentID ?? UUID())?.kind != .topic
                    }
                    if !parents.isEmpty && brain.children(of: e.id).isEmpty {
                        Section("Under a topic") {
                            ForEach(parents.prefix(40)) { t in
                                Button(t.name) { move(e, to: t.id) }.disabled(t.id == e.parentID)
                            }
                        }
                    }
                }
            }
            Button(e.locks.any ? "Unlock" : "Lock") {
                brain.setLocks(e.locks.any ? .none : .all, for: e.id)
            }
            .help("Locked: Docket won't rename, move or refile it")
            if e.kind.isTaxonomy {
                Divider()
                Button(e.kind == .area ? "Delete Area…" : "Delete Topic…", role: .destructive) { confirmDelete(e) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.ink)
                .frame(width: 28, height: 28)
        }
        .menuChrome(Circle())
        .help("Fix it: rename, merge, split, move, lock")
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let e = brain.entity(entityID), !trimmed.isEmpty, trimmed != e.name else {
            if let e = brain.entity(entityID) { name = e.name }
            return
        }
        brain.rename(entityID, to: trimmed)
    }

    private func split(_ alias: String, from e: BrainEntity) {
        if let newID = brain.unmerge(alias: alias, from: e.id) {
            app.showToast("\(alias) is separate from \(e.name) now")
            _ = newID
        } else {
            app.showToast("\(alias) no longer finds \(e.name)")
        }
    }

    private func move(_ e: BrainEntity, to parent: UUID?) {
        if brain.move(e.id, to: parent) {
            app.showToast("Moved to \(parent.flatMap(brain.entity)?.name ?? "the top level")")
        } else {
            app.showToast("Can't go there: topics are at most two levels deep")
        }
    }

    private func confirmDelete(_ e: BrainEntity) {
        let alert = NSAlert()
        alert.messageText = "Delete “\(e.name)”?"
        alert.informativeText = e.kind == .area
            ? "Its topics move to the top level. Memories aren't deleted."
            : "Its sub-topics move up and memories with no other topic wait in Unsorted. Memories aren't deleted."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let run = {
            withAnimation(Motion.sheet) { app.selectedEntityID = nil }
            brain.deleteTopic(e.id)
        }
        if let window = NSApp?.keyWindow ?? NSApp?.mainWindow {
            alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { run() } }
        } else if alert.runModal() == .alertFirstButtonReturn {
            run()
        }
    }

    // MARK: What you know

    private func isWriting(_ e: BrainEntity) -> Bool {
        if center.writingPages.contains(e.id) { return true }
        guard brain.isWorking, center.hasAI, e.kind != .area else { return false }
        return brain.staleEntities(limit: 8).contains { $0.id == e.id }
    }

    @ViewBuilder
    private func summary(_ e: BrainEntity) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Eyebrow(text: "What you know").padding(.leading, 4)
                Spacer()
                if !editingSummary && (!e.summary.isEmpty || center.hasAI) {
                    Button("Edit") {
                        draft = e.summary
                        withAnimation(Motion.snappy) { editingSummary = true }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.ink2)
                    .help("Write it yourself: Docket keeps your words")
                }
            }
            if editingSummary {
                summaryEditor(e)
            } else if !e.summary.isEmpty {
                Text(attributedSummary(e))
                    .font(.system(size: 14.5))
                    .lineSpacing(4)
                    .foregroundStyle(Color.bodyText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .environment(\.openURL, OpenURLAction { url in
                        guard let n = MemoryAnswerLinks.citation(url), let item = e.summarySource(n) else { return .systemAction }
                        openItem(item)
                        return .handled
                    })
                    .padding(.horizontal, 4)
                if e.summaryEditedByUser {
                    HStack(spacing: Space.sm) {
                        Text("Written by you").textStyle(.caption).foregroundStyle(Color.ink3)
                        if center.hasAI {
                            Button("Let Docket write it") { letDocketWrite(e) }
                                .buttonStyle(.plain)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(Color.ink2)
                        }
                    }
                    .padding(.leading, 4)
                }
            } else if isWriting(e) {
                HStack(spacing: Space.sm) {
                    ProgressView().controlSize(.small)
                    Text("Docket is writing this page…").textStyle(.footnote).foregroundStyle(Color.ink2)
                }
                .padding(.leading, 4)
            } else if !center.hasAI {
                MemoryNote(icon: "key", text: BrainText.noKeyHint(e))
                    .padding(.leading, 4)
            } else if e.itemCount < brain.synthesisMinimumItems {
                MemoryNote(icon: "text.alignleft", text: "Docket writes a page once there are \(brain.synthesisMinimumItems) memories.")
                    .padding(.leading, 4)
            } else {
                MemoryNote(icon: "text.alignleft", text: "Not written yet.") {
                    Button("Write it") { write(e.id) }
                        .buttonStyle(SecondaryPill(height: 26))
                }
                .padding(.leading, 4)
            }
            if let problem {
                MemoryNote(icon: "exclamationmark.triangle.fill", warning: true, text: problem)
                    .padding(.leading, 4)
            }
        }
    }

    private func summaryEditor(_ e: BrainEntity) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            TextEditor(text: $draft)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
                .frame(minHeight: 140)
                .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.fill))
            HStack(spacing: Space.sm) {
                if center.hasAI {
                    Button("Let Docket write it") { letDocketWrite(e) }
                        .buttonStyle(SecondaryPill(height: 30))
                        .help("Hand the page back to Docket and write it now")
                }
                Spacer()
                Button("Cancel") { withAnimation(Motion.snappy) { editingSummary = false } }
                    .buttonStyle(SecondaryPill(height: 30))
                Button("Save") {
                    brain.editSummary(e.id, text: draft)
                    withAnimation(Motion.snappy) { editingSummary = false }
                }
                .buttonStyle(PrimaryPill(height: 30))
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    /// The summary with [n] as small chips and **bold** kept.
    private func attributedSummary(_ e: BrainEntity) -> AttributedString {
        var out = AttributedString()
        for segment in BrainText.summarySegments(e.summary, sources: e.summarySources.count) {
            switch segment {
            case .text(let s):
                out += BrainText.inline(s)
            case .citation(let n):
                out += MemoryAnswerLinks.chip(n)
            }
        }
        return out
    }

    private func letDocketWrite(_ e: BrainEntity) {
        brain.editSummary(e.id, text: nil)
        withAnimation(Motion.snappy) { editingSummary = false }
        write(e.id)
    }

    private func write(_ id: UUID) {
        problem = nil
        Task { @MainActor in problem = await center.writePage(id) }
    }

    // MARK: Disagreements, facts, questions

    @ViewBuilder
    private func disagreements(_ e: BrainEntity) -> some View {
        if !e.disagreements.isEmpty {
            VStack(alignment: .leading, spacing: Space.sm) {
                Eyebrow(text: "Notes that disagree").padding(.leading, 4)
                VStack(alignment: .leading, spacing: Space.md) {
                    ForEach(e.disagreements) { d in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                                Image(systemName: "arrow.left.arrow.right")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Color.warning)
                                Text(d.text)
                                    .font(.system(size: 13.5, weight: .medium))
                                    .foregroundStyle(Color.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                                Spacer(minLength: 0)
                                Button { brain.removeFact(d.id, from: e.id) } label: {
                                    Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold))
                                }
                                .buttonStyle(IconButtonStyle(size: 22))
                                .help("Settled: hide this")
                            }
                            VStack(spacing: 0) {
                                ForEach(d.itemIDs.compactMap(library.item), id: \.id) { item in
                                    sourceRow(item, entity: e.id)
                                }
                            }
                            .padding(.leading, 19)
                        }
                    }
                }
                .padding(Space.md)
                .background(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).fill(Color.card))
                .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                    .strokeBorder(Color.warning.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }
        }
    }

    @ViewBuilder
    private func facts(_ e: BrainEntity) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Eyebrow(text: "Key facts").padding(.leading, 4)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(e.keyFacts) { fact in
                    BrainFactRow(fact: fact, entityID: e.id, open: openItem)
                }
                HStack(spacing: Space.sm) {
                    TextField("Add a fact", text: $newFact)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.5, weight: .medium))
                        .onSubmit { addFact(e) }
                    if !newFact.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button("Add") { addFact(e) }
                            .buttonStyle(SecondaryPill(height: 26))
                    }
                }
                .padding(.horizontal, Space.md)
                .frame(minHeight: 40)
            }
            .hairlineCard(radius: Radius.lg)
        }
    }

    private func addFact(_ e: BrainEntity) {
        guard brain.addFact(newFact, to: e.id) != nil else { return }
        newFact = ""
    }

    @ViewBuilder
    private func questions(_ e: BrainEntity) -> some View {
        if !e.openQuestions.isEmpty {
            DetailSection("Open questions") {
                ForEach(e.openQuestions, id: \.self) { q in
                    BrainQuestionRow(question: q) { withAnimation(Motion.base) { brain.removeOpenQuestion(q, from: e.id) } }
                }
            }
        }
    }

    // MARK: Promises and decisions

    /// Open promises and decisions in its memories, newest first, in the lens's words.
    @ViewBuilder
    private func moments(_ e: BrainEntity) -> some View {
        let vocabulary = library.vocabulary
        let items = brain.items(for: e.id)
        let promises = items.flatMap { item in item.moments.filter { $0.kind == .promise && !$0.done }.map { (item, $0) } }
        let decisions = items.flatMap { item in item.moments.filter { $0.kind == .decision }.map { (item, $0) } }
        if !promises.isEmpty {
            DetailSection("Open \(vocabulary.promises.lowercased())") {
                ForEach(promises.prefix(5), id: \.1.id) { item, m in
                    momentRow(m, item: item, entity: e.id)
                }
            }
        }
        if !decisions.isEmpty {
            DetailSection(vocabulary.decisions) {
                ForEach(decisions.prefix(5), id: \.1.id) { item, m in
                    momentRow(m, item: item, entity: e.id)
                }
            }
        }
    }

    private func momentRow(_ m: Moment, item: MemoryItem, entity: UUID) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            momentButton(m, item: item)
            if m.kind == .promise {
                PromiseTaskButton(moment: m, item: item)
                    .padding(.leading, 42)
                    .padding(.top, -4)
                    .padding(.bottom, 10)
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.hair).frame(height: 1).padding(.leading, 42) }
    }

    private func momentButton(_ m: Moment, item: MemoryItem) -> some View {
        Button { openItem(item.id) } label: {
            HStack(alignment: .top, spacing: Space.md) {
                Image(systemName: MemoryText.symbol(for: m.kind))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.ink2)
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.text)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    Text([m.kind == .promise ? MemoryText.promiseLine(m, now: app.clock) : MemoryText.whoLine(m),
                          MemoryText.date(item.createdAt, now: app.clock)].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.ink2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .hoverHighlight(cornerRadius: Radius.sm)
        }
        .buttonStyle(PressScale(scale: 0.985))
        .help("Open “\(item.displayTitle)”")
    }

    // MARK: Sub-topics, related

    @ViewBuilder
    private func subTopics(_ e: BrainEntity) -> some View {
        let kids = brain.children(of: e.id)
        if !kids.isEmpty {
            VStack(alignment: .leading, spacing: Space.sm) {
                Eyebrow(text: e.kind == .area ? "Topics" : "Sub-topics").padding(.leading, 4)
                FlowLayout(spacing: Space.sm, lineSpacing: Space.sm) {
                    ForEach(kids) { k in
                        SuggestionChip(title: "\(k.name)  \(k.itemCount)", icon: k.kind.symbolName) { open(k.id) }
                            .help("Open \(k.name)")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func related(_ e: BrainEntity) -> some View {
        let list = brain.related(e.id, limit: 10)
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: Space.sm) {
                Eyebrow(text: "Related").padding(.leading, 4)
                FlowLayout(spacing: Space.sm, lineSpacing: Space.sm) {
                    ForEach(list) { r in
                        BrainRelatedChip(related: r) { open(r.entity.id) }
                    }
                }
            }
        }
    }

    // MARK: Timeline

    @ViewBuilder
    private func timeline(_ e: BrainEntity) -> some View {
        let entries = brain.timeline(e.id)
        if !entries.isEmpty {
            let shown = timelineExpanded ? entries : Array(entries.prefix(8))
            DetailSection("Timeline") {
                ForEach(shown) { entry in
                    sourceRow(entry.item, entity: e.id, tile: 28)
                        .padding(.horizontal, Space.xs)
                }
                if entries.count > shown.count {
                    Button("Show all \(entries.count)") { withAnimation(Motion.snappy) { timelineExpanded = true } }
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.ink2)
                        .padding(.horizontal, Space.md)
                        .frame(height: 36)
                }
            }
        }
    }

    /// A memory behind something on the page: kind (or picture), title, its real date. A click opens it.
    private func sourceRow(_ item: MemoryItem, entity: UUID, tile: CGFloat = 22) -> some View {
        Button { openItem(item.id) } label: {
            HStack(spacing: Space.sm) {
                MemoryKindTile(item: item, size: tile)
                Text(item.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                Spacer(minLength: Space.sm)
                Text(MemoryText.date(item.createdAt, now: app.clock))
                    .font(.system(size: 12.5, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.ink2)
                    .fixedSize()
            }
            .padding(.horizontal, Space.sm)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .hoverHighlight(cornerRadius: Radius.sm)
        }
        .buttonStyle(PressScale(scale: 0.985))
        .help("Open this memory")
    }

    private func footer(_ e: BrainEntity) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if e.summaryEditedByUser {
                Text("Summary written by you")
            } else if let at = e.synthesizedAt, !e.summary.isEmpty {
                Text("Written by Docket \(MemoryText.dateTime(at, now: app.clock))")
            }
            if e.locks.any { Text("Locked: Docket won't rename, move or refile it") }
        }
        .textStyle(.caption)
        .foregroundStyle(Color.ink3)
        .padding(.top, Space.sm)
        .padding(.leading, 4)
    }

    // MARK: Opening things

    private func open(_ id: UUID) {
        app.selectedEntityID = id
    }

    private func openItem(_ id: UUID) {
        withAnimation(Motion.sheet) { app.openMemory(id, from: entityID) }
    }
}

// MARK: - Pieces

/// One key fact: its text, the memories behind it (small chips), pin and remove.
private struct BrainFactRow: View {
    let fact: CitedText
    let entityID: UUID
    let open: (UUID) -> Void
    @ObservedObject private var brain = MemoryCenter.shared.brain
    @ObservedObject private var library = MemoryCenter.shared.library
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Text(fact.text)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            ForEach(Array(fact.itemIDs.compactMap(library.item).prefix(3).enumerated()), id: \.element.id) { _, item in
                Button { open(item.id) } label: {
                    Image(systemName: item.kind.symbolName)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.ink2)
                        .frame(width: 18, height: 16)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.fillStrong))
                }
                .buttonStyle(PressScale(scale: 0.9))
                .help("From “\(item.displayTitle)”, \(MemoryText.date(item.createdAt))")
            }
            Spacer(minLength: 0)
            Button { withAnimation(Motion.snappy) { brain.setFactPinned(fact.id, in: entityID, !fact.pinned) } } label: {
                Image(systemName: fact.pinned ? "pin.fill" : "pin").font(.system(size: 10.5, weight: .semibold))
            }
            .buttonStyle(IconButtonStyle(size: 22, filled: fact.pinned))
            .help(fact.pinned ? "Unpin: Docket may rewrite it" : "Pin: Docket keeps it as it is")
            .opacity(hovering || fact.pinned ? 1 : 0)
            Button { withAnimation(Motion.base) { brain.removeFact(fact.id, from: entityID) } } label: {
                Image(systemName: "minus").font(.system(size: 10.5, weight: .bold))
            }
            .buttonStyle(IconButtonStyle(size: 22))
            .help("Remove this fact")
            .opacity(hovering ? 1 : 0)
        }
        .onHover { h in withAnimation(Motion.fast) { hovering = h } }
        .padding(.leading, Space.md)
        .padding(.trailing, Space.sm)
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.hair).frame(height: 1).padding(.leading, Space.md) }
    }
}

/// An open question; × (on hover) when it's answered.
private struct BrainQuestionRow: View {
    let question: String
    let dismiss: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Image(systemName: "questionmark")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(Color.ink3)
                .frame(width: 14)
            Text(question)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold)) }
                .buttonStyle(IconButtonStyle(size: 22))
                .help("Answered or no longer a question")
                .opacity(hovering ? 1 : 0)
        }
        .padding(.leading, Space.md)
        .padding(.trailing, Space.sm)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.hair).frame(height: 1).padding(.leading, Space.md) }
        .onHover { h in withAnimation(Motion.fast) { hovering = h } }
    }
}

/// A related topic, person or project: its name and how strongly they're linked (a short bar).
struct BrainRelatedChip: View {
    let related: RelatedEntity
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: related.entity.kind.symbolName)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.ink3)
                Text(related.entity.name).lineLimit(1)
                StrengthBar(value: related.strength)
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Color.ink2)
            .padding(.horizontal, 11)
            .frame(height: 28)
        }
        .buttonStyle(MenuChromeStyle(shape: Capsule(), fill: .fill, hoverFill: .fillStrong))
        .help("\(related.entity.name): shares \(MemoryText.count(related.sharedItems))")
    }
}

/// Three ticks, filled by strength (0…1).
struct StrengthBar: View {
    let value: Double

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(Double(i) < (value * 3).rounded(.up) ? Color.ink2 : Color.hairStrong)
                    .frame(width: 3, height: 8)
            }
        }
        .accessibilityLabel("Strength \(Int(value * 100))%")
    }
}

/// "Merge Pricing into…": the same kind only, searchable.
struct BrainMergeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var brain = MemoryCenter.shared.brain
    @ObservedObject private var library = MemoryCenter.shared.library
    let source: BrainEntity
    let merge: (BrainEntity) -> Void
    @State private var query = ""
    @State private var picked: UUID?

    var body: some View {
        let matches = EntityPicker.filter(brain.entities(source.kind), query: query, kind: source.kind, excluding: [source.id])
        VStack(alignment: .leading, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Merge \(source.name) into…")
                    .textStyle(.title2)
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                Text(source.kind.isExtracted
                     ? "Every way of writing \(source.name) will mean the one you pick, from now on."
                     : "Its memories and sub-topics move there, and \(source.name) finds it from now on.")
                    .textStyle(.callout)
                    .foregroundStyle(Color.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("Search \(source.kind.pluralLabel(library.vocabulary).lowercased())", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium))
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.fill))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(matches) { e in
                        Button { picked = e.id } label: {
                            HStack(spacing: Space.sm) {
                                Image(systemName: e.kind.symbolName)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color.ink2)
                                    .frame(width: 18)
                                Text(e.name)
                                    .font(.system(size: 13.5, weight: .semibold))
                                    .foregroundStyle(Color.ink)
                                    .lineLimit(1)
                                Spacer(minLength: Space.sm)
                                Text(BrainText.memories(e.itemCount))
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.ink3)
                                if picked == e.id {
                                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.ink)
                                }
                            }
                            .padding(.horizontal, Space.sm)
                            .frame(height: 34)
                            .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(picked == e.id ? Color.fill : .clear))
                            .contentShape(Rectangle())
                            .hoverHighlight(cornerRadius: Radius.sm)
                        }
                        .buttonStyle(.plain)
                    }
                    if matches.isEmpty {
                        Text("Nothing matches.").textStyle(.callout).foregroundStyle(Color.ink2).padding(Space.sm)
                    }
                }
            }
            .frame(height: 240)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryPill())
                    .keyboardShortcut(.cancelAction)
                Button("Merge") {
                    guard let id = picked, let target = brain.entity(id) else { return }
                    dismiss()
                    merge(target)
                }
                .buttonStyle(PrimaryPill())
                .keyboardShortcut(.defaultAction)
                .disabled(picked == nil)
            }
        }
        .padding(Space.xxl)
        .frame(width: 460)
        .background(Color.raised)
    }
}
