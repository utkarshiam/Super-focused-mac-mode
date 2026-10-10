import AppKit
import MemoryKit
import SwiftUI

/// Memory: one Ask field on top (typing filters, Return searches and, with a key, answers from what's
/// saved), the library under it, and the open memory on the right. Anything dropped on it is remembered.
/// Until the user has said what they do, the lens card stands in for all of it.
struct MemoryView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    @EnvironmentObject var focus: FocusTimer
    @EnvironmentObject var calendar: CalendarService
    @ObservedObject private var center = MemoryCenter.shared
    @ObservedObject private var library = MemoryCenter.shared.library
    @State private var dropTargeted = false
    @State private var composing: MemoryComposeSheet.Mode?

    /// Screenshots: the lens card even when lenses were chosen.
    static var debugOnboarding = false

    private var onboarding: Bool { !library.lensesChosen || Self.debugOnboarding }

    var body: some View {
        HStack(spacing: 0) {
            MemoryMainColumn(onboarding: onboarding, compose: { composing = $0 }, addFiles: addFiles)
                .frame(minWidth: 360, maxWidth: .infinity, alignment: .leading)
            if !onboarding, let id = app.selectedMemoryID, library.item(id) != nil {
                Rectangle().fill(Color.hair).frame(width: 1).ignoresSafeArea()
                MemoryItemDetail(itemID: id)
                    .frame(width: 390)
                    .id(id)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 16)), removal: .opacity))
            }
        }
        .background(Color.paper)
        .animation(Motion.sheet, value: app.selectedMemoryID)
        .onDrop(of: MemoryDrop.types, isTargeted: $dropTargeted) { providers in
            MemoryDrop.read(providers) { files, links, texts in remember(files: files, links: links, texts: texts) }
            return true
        }
        .overlay { if dropTargeted { dropOverlay } }
        .animation(Motion.fast, value: dropTargeted)
        .sheet(isPresented: $app.showsMemoryProfile) {
            MemoryProfileView()
                .environmentObject(store)
                .environmentObject(app)
                .environmentObject(focus)
                .environmentObject(calendar)
        }
        .sheet(item: $composing) { mode in
            MemoryComposeSheet(mode: mode) { item in
                app.selectedMemoryID = item.id
                app.showToast("Saved to memory")
            }
            .environmentObject(app)
        }
        .onAppear(perform: askPending)
        .onChange(of: app.memoryQuestion) { _ in askPending() }
    }

    /// ⌘K "Ask memory: …" brought us here with a question.
    private func askPending() {
        guard let question = app.memoryQuestion else { return }
        app.memoryQuestion = nil
        app.memoryAsk.ask(question, library: library, ai: center.processor.ai, scope: app.memoryScope.filter)
    }

    private var dropOverlay: some View {
        ZStack {
            Color.paper.opacity(0.88)
            VStack(spacing: Space.sm) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Color.ink)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(Color.fill))
                Text("Drop to remember").textStyle(.title3).foregroundStyle(Color.ink)
                Text("Files, photos, links or text").textStyle(.callout).foregroundStyle(Color.ink2)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
                .strokeBorder(Color.ink3, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .padding(Space.md)
        )
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private func remember(files: [URL], links: [URL], texts: [String]) {
        let saved = MemoryDrop.save(files: files, links: links, texts: texts)
        guard !saved.isEmpty else {
            app.showToast("Couldn't save that")
            return
        }
        Haptics.success()
        if saved.count == 1 { app.selectedMemoryID = saved[0].id }
        app.showToast(saved.count == 1 ? "Saved to memory" : "Saved \(MemoryText.count(saved.count)) to memory")
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose files, photos, videos or recordings to remember"
        panel.prompt = "Remember"
        guard panel.runModal() == .OK else { return }
        remember(files: panel.urls, links: [], texts: [])
    }
}

// MARK: - The main column

private struct MemoryMainColumn: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var center = MemoryCenter.shared
    @ObservedObject private var library = MemoryCenter.shared.library
    @ObservedObject private var processor = MemoryCenter.shared.processor
    let onboarding: Bool
    let compose: (MemoryComposeSheet.Mode) -> Void
    let addFiles: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Memory", subtitle: onboarding ? nil : subtitle) { headerButtons }
            if onboarding {
                ScrollView {
                    LensOnboardingCard(library: library)
                        .frame(maxWidth: 680)
                        .padding(.horizontal, Space.gutter)
                        .padding(.top, Space.sm)
                        .padding(.bottom, Space.x4)
                        .frame(maxWidth: .infinity)
                }
            } else {
                MemoryAskBar(ask: app.memoryAsk, submit: submit)
                    .padding(.horizontal, Space.gutter)
                    .padding(.bottom, Space.md)
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        if let problem = library.loadProblem {
                            MemoryNote(icon: "exclamationmark.triangle.fill", warning: true, text: problem)
                        }
                        MemoryAskStatus(ask: app.memoryAsk, submit: submit)
                        ResurfacingStrip(ask: app.memoryAsk)
                        MemoryLibrarySection(ask: app.memoryAsk)
                    }
                    .padding(.horizontal, Space.gutter)
                    .padding(.top, Space.xs)
                    .padding(.bottom, Space.x4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .background(Color.paper)
    }

    private var subtitle: String {
        var parts = [MemoryText.count(library.count)]
        if processor.processingCount > 0 { parts.append("summarising \(processor.processingCount)") }
        return parts.joined(separator: " · ")
    }

    private func submit(_ text: String) {
        app.memoryAsk.ask(text, library: library, ai: processor.ai, scope: app.memoryScope.filter)
    }

    /// Who Docket thinks you are, and + to add something. Nothing until the lens card is done.
    @ViewBuilder
    private var headerButtons: some View {
        if !onboarding {
            HStack(spacing: Space.sm) {
                Button { app.showsMemoryProfile = true } label: { Image(systemName: "person.crop.circle") }
                    .buttonStyle(IconButtonStyle(filled: true))
                    .help("What Docket knows about you")
                    .accessibilityLabel("What Docket knows about me")
                Menu {
                    Button { compose(.note) } label: { Label("New Note…", systemImage: "square.and.pencil") }
                    Button { compose(.link) } label: { Label("Add Link…", systemImage: "link") }
                    Button { addFiles() } label: { Label("Add Files…", systemImage: "doc.badge.plus") }
                    Divider()
                    Button { app.recordVoiceNote() } label: { Label("Record Voice Note", systemImage: "mic") }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.ink)
                        .frame(width: 32, height: 32)
                }
                .menuChrome(Circle(), fill: .fill)
                .help("Add a note, a link or files (or drop them here)")
                .accessibilityLabel("Add to memory")
            }
        }
    }
}

// MARK: - Ask

/// The one field: "Ask your memory…", with example questions under it while it's empty.
private struct MemoryAskBar: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var ask: MemoryAskModel
    @ObservedObject private var library = MemoryCenter.shared.library
    let submit: (String) -> Void
    @FocusState private var focused: Bool
    @StateObject private var dictation = AskDictation()

    var body: some View {
        let empty = ask.query.trimmingCharacters(in: .whitespaces).isEmpty
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.md) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.ink2)
                TextField(MemoryText.askPlaceholder(library.lenses), text: $ask.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .medium))
                    .tracking(-0.2)
                    .foregroundStyle(Color.ink)
                    .focused($focused)
                    .onSubmit {
                        dictation.stop()
                        submit(ask.query)
                    }
                if !empty && !dictation.isListening {
                    Button { ask.clear() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.ink3)
                        .help("Clear")
                }
                AskMicButton(dictation: dictation, ask: ask, submit: submit)
                Button {
                    dictation.stop()
                    submit(ask.query)
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.onPrimary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(MenuChromeStyle(shape: Circle(), fill: .primaryFill, hoverFill: Color.primaryFill.opacity(0.85)))
                .disabled(empty)
                .help("Ask (Return)")
                .accessibilityLabel("Ask")
            }
            .padding(.leading, Space.lg)
            .padding(.trailing, 8)
            .frame(height: 50)
            .background(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).fill(Color.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .strokeBorder(dictation.isListening ? Color.ink2 : focused ? Color.hairStrong : Color.hair, lineWidth: 1))

            if let problem = dictation.problem {
                MemoryNote(icon: "mic.slash", warning: true, text: problem.errorDescription ?? "Couldn't listen.") {
                    if problem.opensPrivacySettings {
                        Button("Open System Settings") {
                            NSWorkspace.shared.open(problem == .speechDenied ? VoiceError.speechSettingsURL : VoiceError.microphoneSettingsURL)
                        }
                        .buttonStyle(SecondaryPill(height: 26))
                    }
                    Button { dictation.clearProblem() } label: { Image(systemName: "xmark") }
                        .buttonStyle(IconButtonStyle(size: 24))
                        .help("Dismiss")
                }
            }

            if empty && ask.answer == nil && ask.phase == .idle {
                // One line of examples: as many as fit.
                let examples = MemoryText.askChips(library.lenses)
                ViewThatFits(in: .horizontal) {
                    ForEach((1...examples.count).reversed(), id: \.self) { n in
                        HStack(spacing: Space.sm) {
                            ForEach(examples.prefix(n), id: \.self) { example in
                                SuggestionChip(title: example) { submit(example) }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            }
        }
        .animation(Motion.base, value: empty)
        .onChange(of: ask.query) { _ in ask.textChanged() }
        .onDisappear { dictation.stop() }
    }
}

/// Under the field: Gemini thinking, the answer, or why there isn't one.
private struct MemoryAskStatus: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var ask: MemoryAskModel
    let submit: (String) -> Void

    var body: some View {
        Group {
            switch ask.phase {
            case .idle:
                EmptyView()
            case .asking:
                HStack(spacing: Space.sm) {
                    ProgressView().controlSize(.small)
                    Text("Looking through your memory…").textStyle(.callout).foregroundStyle(Color.ink2)
                }
                .padding(.vertical, Space.xs)
            case .noKey:
                MemoryNote(icon: "key", text: MemoryText.noKey) {
                    Button("Open Settings") { MemorySettings.openAI(app) }
                        .buttonStyle(SecondaryPill(height: 26))
                }
            case .failed(let message, let settings):
                MemoryNote(icon: "exclamationmark.triangle.fill", warning: true, text: message) {
                    if settings {
                        Button("Open Settings") { MemorySettings.openAI(app) }
                            .buttonStyle(SecondaryPill(height: 26))
                    } else {
                        Button("Try again") { submit(ask.query) }
                            .buttonStyle(SecondaryPill(height: 26))
                    }
                }
            case .answered:
                if let answer = ask.answer {
                    MemoryAnswerCard(answer: answer, ask: ask, submit: submit)
                        .transition(.opacity.combined(with: .offset(y: 6)))
                }
            }
        }
        .animation(Motion.gentle, value: ask.phase)
    }
}

/// The answer: its text with [n] as small citation chips, the sources it cites, follow-ups, and "Ask another".
private struct MemoryAnswerCard: View {
    @EnvironmentObject var app: AppState
    let answer: MemoryAnswer
    @ObservedObject var ask: MemoryAskModel
    let submit: (String) -> Void

    /// The cited sources, by number.
    private var cited: [(number: Int, item: MemoryItem)] {
        var seen = Set<UUID>()
        var out: [(Int, MemoryItem)] = []
        let numbers = CitationText.numbers(in: answer.text) + answer.citations.map(\.number)
        for n in numbers {
            guard let item = answer.item(forCitation: n), seen.insert(item.id).inserted else { continue }
            out.append((n, item))
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text(Self.attributed(answer.text, sources: answer.sources.count))
                .font(.system(size: 15))
                .lineSpacing(4)
                .foregroundStyle(answer.answered ? Color.bodyText : Color.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .environment(\.openURL, OpenURLAction { url in
                    guard let n = Self.citation(url) else { return .systemAction }
                    open(n)
                    return .handled
                })

            let sources = cited
            if !sources.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Eyebrow(text: "Sources")
                        .padding(.bottom, Space.xs)
                    ForEach(sources, id: \.item.id) { source in
                        sourceRow(source.number, source.item)
                    }
                }
            }

            if !answer.followUps.isEmpty {
                FlowLayout(spacing: Space.sm, lineSpacing: Space.sm) {
                    ForEach(answer.followUps, id: \.self) { q in
                        SuggestionChip(title: q, icon: "arrow.turn.down.right") { submit(q) }
                    }
                }
            }

            HStack {
                SpeakAnswerButton(text: answer.text, id: answer.question)
                Spacer()
                Button("Ask another") { withAnimation(Motion.gentle) { ask.clear() } }
                    .buttonStyle(SecondaryPill(height: 30))
                    .help("Clear the question and start again")
            }
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hairlineCard()
    }

    private func sourceRow(_ n: Int, _ item: MemoryItem) -> some View {
        Button { open(n) } label: {
            HStack(spacing: Space.sm) {
                Text("\(n)")
                    .font(.system(size: 10.5, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.ink)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.fillStrong))
                Image(systemName: item.kind.symbolName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.ink2)
                    .frame(width: 16)
                Text(item.displayTitle)
                    .font(.system(size: 13.5, weight: .semibold))
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
            .frame(height: 32)
            .contentShape(Rectangle())
            .hoverHighlight(cornerRadius: Radius.sm)
        }
        .buttonStyle(PressScale(scale: 0.985))
        .padding(.horizontal, -Space.sm)
        .help("Open this memory")
    }

    private func open(_ n: Int) {
        guard let item = answer.item(forCitation: n) else { return }
        withAnimation(Motion.sheet) { app.selectedMemoryID = item.id }
    }

    /// The answer with each [n] as a small tappable chip.
    static func attributed(_ text: String, sources: Int) -> AttributedString {
        var out = AttributedString()
        for segment in CitationText.segments(text, valid: sources > 0 ? 1...sources : nil) {
            switch segment {
            case .text(let s):
                out += AttributedString(s)
            case .citation(let n):
                out += AttributedString("\u{2009}")
                var chip = AttributedString("\u{2009}\(n)\u{2009}")
                chip.font = .system(size: 10.5, weight: .bold).monospacedDigit()
                chip.foregroundColor = .ink
                chip.backgroundColor = .fillStrong
                chip.baselineOffset = 2
                chip.link = URL(string: "docket-cite:\(n)")
                out += chip
            }
        }
        return out
    }

    static func citation(_ url: URL) -> Int? {
        guard url.scheme == "docket-cite" else { return nil }
        return Int(url.absoluteString.dropFirst("docket-cite:".count))
    }
}

// MARK: - Worth revisiting

/// Up to three older memories brought back ("On this day", pinned, open promises…). Hidden for the
/// session once dismissed, and while asking or filtering.
private struct ResurfacingStrip: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var library = MemoryCenter.shared.library
    /// The app's ask model: the strip steps aside while there's a question.
    @ObservedObject var ask: MemoryAskModel

    var body: some View {
        let cards = ask.resurfacingDismissed || app.memoryScope != .all || !ask.query.isEmpty || ask.answer != nil
            ? [] : MemoryResurfacing.cards(library, now: app.clock)
        if !cards.isEmpty {
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack {
                    Eyebrow(text: cards.contains { $0.onThisDay } && cards.count == 1 ? "On this day" : "Worth revisiting")
                    Spacer()
                    Button { withAnimation(Motion.gentle) { ask.resurfacingDismissed = true } } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(IconButtonStyle(size: 22))
                    .help("Hide until Docket is opened again")
                    .accessibilityLabel("Hide")
                }
                HStack(alignment: .top, spacing: Space.md) {
                    ForEach(cards) { card in
                        cardView(card)
                    }
                }
            }
            .transition(.opacity)
        }
    }

    private func cardView(_ card: MemoryResurfacing.Card) -> some View {
        Button { withAnimation(Motion.sheet) { app.selectedMemoryID = card.item.id } } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(card.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.ink3)
                    .lineLimit(1)
                Text(card.item.displayTitle)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(MemoryText.date(card.item.createdAt, now: app.clock))
                    .font(.system(size: 12, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.ink2)
            }
            .padding(Space.md)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).fill(Color.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(Color.hair))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale(scale: 0.985))
    }
}

/// What "Worth revisiting" shows, worked out once per library change and day.
@MainActor
enum MemoryResurfacing {
    struct Card: Identifiable {
        var item: MemoryItem
        var label: String
        var onThisDay: Bool
        var id: UUID { item.id }
    }

    private static var cache: (revision: Int, day: Date, cards: [Card])?

    /// On this day first, then pinned, related, open promises and ideas; three at most.
    static func cards(_ library: MemoryLibrary, now: Date) -> [Card] {
        let day = Calendar.current.startOfDay(for: now)
        if let cache, cache.revision == library.revision, cache.day == day { return cache.cards }
        var out: [Card] = []
        for item in library.onThisDay(now).prefix(2) {
            out.append(Card(item: item, label: "On this day", onThisDay: true))
        }
        for r in library.worthRevisiting(limit: 3, now: now) where out.count < 3 && !out.contains(where: { $0.id == r.id }) {
            out.append(Card(item: r.item, label: MemoryText.reason(r.reason, library.vocabulary), onThisDay: false))
        }
        cache = (library.revision, day, out)
        return out
    }
}

// MARK: - The library

private struct MemoryLibrarySection: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var ask: MemoryAskModel
    @ObservedObject private var center = MemoryCenter.shared
    @ObservedObject private var library = MemoryCenter.shared.library
    @ObservedObject private var processor = MemoryCenter.shared.processor

    var body: some View {
        let scope = app.memoryScope
        let items = shownItems(ask: ask, scope: scope)
        VStack(alignment: .leading, spacing: Space.md) {
            MemoryFilterRow(scope: Binding(get: { app.memoryScope }, set: { s in withAnimation(Motion.snappy) { app.memoryScope = s } }))
            if ask.showsSearch, let q = ask.searched {
                if ask.searching {
                    ProgressView().controlSize(.small)
                } else {
                    Text(MemoryText.matches(items.count, q))
                        .textStyle(.footnote)
                        .foregroundStyle(Color.ink3)
                        .lineLimit(1)
                }
            }
            if library.count == 0 {
                EmptyState(icon: "brain", title: "Nothing remembered yet",
                           message: "Drop files, photos, links or text here, or add a note with +. Docket remembers what matters in them.")
                    .frame(minHeight: 280)
            } else if items.isEmpty {
                if !ask.showsSearch {
                    Text(ask.query.isEmpty ? "Nothing here yet." : "Nothing matches “\(ask.query.trimmingCharacters(in: .whitespaces))”.")
                        .textStyle(.callout)
                        .foregroundStyle(Color.ink2)
                        .padding(.vertical, Space.lg)
                }
            } else if MemoryScope.usesGrid(scope, kinds: items.map(\.kind)) {
                MemoryGrid(items: items, selectedID: app.selectedMemoryID, select: select)
            } else {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(items.prefix(400).enumerated()), id: \.element.id) { i, item in
                        MemoryRow(item: item, isSelected: app.selectedMemoryID == item.id,
                                  running: processor.runningIDs.contains(item.id), hasAI: center.hasAI, index: i)
                            .onTapGesture { select(item.id) }
                            .contextMenu { MemoryItemMenu(item: item) }
                    }
                }
                .padding(.horizontal, -Space.md)
            }
        }
    }

    private func shownItems(ask: MemoryAskModel, scope: MemoryScope) -> [MemoryItem] {
        let filter = scope.filter
        if ask.showsSearch { return ask.hits.map(\.item).filter { filter.matches($0) && library.item($0.id) != nil } }
        var typed = filter
        typed.text = ask.query.trimmingCharacters(in: .whitespacesAndNewlines)
        return library.items(matching: typed)
    }

    private func select(_ id: UUID) {
        if app.selectedMemoryID == id {
            withAnimation(Motion.sheet) { app.selectedMemoryID = nil }
        } else {
            app.selectedMemoryID = id
        }
    }
}

/// All · Notes · Links · Media · Files · Messages · Tasks, then Browse (people, projects, decisions…).
private struct MemoryFilterRow: View {
    @Binding var scope: MemoryScope
    @ObservedObject private var library = MemoryCenter.shared.library

    var body: some View {
        let vocabulary = library.vocabulary
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(MemoryScope.kinds, id: \.self) { s in
                MemoryChip(title: s.label(vocabulary), isOn: scope == s, help: "Show \(s.label(vocabulary).lowercased())") { scope = s }
            }
            if scope.isBrowse {
                MemoryChip(title: scope.label(vocabulary), icon: scope.symbol, isOn: true, trailingIcon: "xmark",
                           help: "Show everything again") { scope = .all }
            }
            browseMenu(vocabulary)
        }
    }

    private func browseMenu(_ vocabulary: LensVocabulary) -> some View {
        Menu {
            let people = library.people()
            if !people.isEmpty {
                Menu(vocabulary.people) {
                    ForEach(people.prefix(40)) { p in
                        Button("\(p.name)  ·  \(p.count)") { scope = .person(p.name) }
                    }
                }
            }
            let projects = library.projects()
            if !projects.isEmpty {
                Menu(vocabulary.projects) {
                    ForEach(projects.prefix(40)) { p in
                        Button("\(p.name)  ·  \(p.count)") { scope = .project(p.name) }
                    }
                }
            }
            Divider()
            ForEach(MemoryScope.momentKinds, id: \.self) { kind in
                Button { scope = .moments(kind) } label: {
                    Label(vocabulary.label(for: kind), systemImage: MemoryText.symbol(for: kind))
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text("Browse")
                Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .heavy))
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Color.ink2)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .overlay(Capsule().strokeBorder(Color.hair, lineWidth: 1))
        }
        .menuChrome(Capsule(), fill: .clear, hoverFill: .pressedTint)
        .help("Browse by \(vocabulary.people.lowercased()), \(vocabulary.projects.lowercased()), \(vocabulary.decisions.lowercased()) and more")
    }
}

/// One memory in the list: kind (or picture), title, one line of summary, its real date on the right.
private struct MemoryRow: View {
    @EnvironmentObject var app: AppState
    let item: MemoryItem
    let isSelected: Bool
    let running: Bool
    let hasAI: Bool
    let index: Int
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        HStack(spacing: Space.md) {
            MemoryKindTile(item: item, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if item.pinned {
                        Image(systemName: "pin.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.ink2)
                    }
                    Text(item.displayTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                }
                secondLine
            }
            Spacer(minLength: Space.sm)
            if running || (item.processing == .pending && hasAI) {
                ProgressView()
                    .controlSize(.mini)
                    .help("Summarising…")
            }
            Text(MemoryText.date(item.createdAt, now: app.clock))
                .font(.system(size: 14, weight: .bold))
                .tracking(-0.2)
                .monospacedDigit()
                .foregroundStyle(Color.ink)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(isSelected ? Color.fill : (hovering ? Color.pressedTint : Color.clear)))
        .overlay(shape.strokeBorder(isSelected ? Color.hairStrong : Color.clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(Motion.fast) { hovering = h } }
        .enterUp(index)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var secondLine: some View {
        if case .failed(let message) = item.processing {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Color.warning)
                Text("Couldn't summarise").foregroundStyle(Color.ink2)
                Button("Retry") { MemoryCenter.shared.processor.reprocess(item.id) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.ink)
                    .fontWeight(.semibold)
                    .help(message)
            }
            .font(.system(size: 12.5))
        } else if !item.summary.isEmpty {
            Text(item.summary)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.ink2)
                .lineLimit(1)
        } else if item.processing == .skipped && !hasAI {
            Text("Not summarised — add a key")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.ink3)
                .lineLimit(1)
                .help(MemoryText.noKey)
        } else if let line = item.fullText.split(whereSeparator: \.isNewline).dropFirst(item.title.isEmpty ? 1 : 0).first {
            Text(String(line))
                .font(.system(size: 12.5))
                .foregroundStyle(Color.ink2)
                .lineLimit(1)
        }
    }
}

/// Media as a grid of pictures.
private struct MemoryGrid: View {
    @EnvironmentObject var app: AppState
    let items: [MemoryItem]
    let selectedID: UUID?
    let select: (UUID) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: Space.md)], alignment: .leading, spacing: Space.lg) {
            ForEach(Array(items.prefix(400).enumerated()), id: \.element.id) { i, item in
                tile(item)
                    .onTapGesture { select(item.id) }
                    .contextMenu { MemoryItemMenu(item: item) }
                    .enterUp(i)
            }
        }
    }

    private func tile(_ item: MemoryItem) -> some View {
        let selected = item.id == selectedID
        let shape = RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        return VStack(alignment: .leading, spacing: 6) {
            GridPicture(item: item)
                .frame(height: 118)
                .frame(maxWidth: .infinity)
                .clipShape(shape)
                .overlay(shape.strokeBorder(selected ? Color.ink : Color.hair, lineWidth: selected ? 2 : 1))
            Text(item.displayTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.ink)
                .lineLimit(1)
            Text(MemoryText.date(item.createdAt, now: app.clock))
                .font(.system(size: 11.5, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Color.ink2)
        }
        .contentShape(Rectangle())
    }
}

private struct GridPicture: View {
    let item: MemoryItem
    @ObservedObject private var library = MemoryCenter.shared.library
    @State private var loaded = 0

    var body: some View {
        ZStack {
            Color.fill
            if let image = MemoryVisual.image(for: item, library: library) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .clipped()
            } else {
                Image(systemName: item.kind.symbolName)
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(Color.ink3)
            }
            if item.kind == .video {
                Image(systemName: "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.black.opacity(0.45)))
            }
        }
        .id(loaded)
        .onReceive(NotificationCenter.default.publisher(for: MediaCache.didLoad)) { _ in loaded += 1 }
    }
}

/// Right-click on a memory.
struct MemoryItemMenu: View {
    @EnvironmentObject var app: AppState
    let item: MemoryItem

    var body: some View {
        let center = MemoryCenter.shared
        Button(item.pinned ? "Unpin" : "Pin") { center.library.setPinned(item.id, !item.pinned) }
        Button("Summarise Again") { center.processor.reprocess(item.id) }
            .disabled(!center.hasAI)
        Divider()
        Button("Delete…", role: .destructive) { MemoryDelete.confirm(item, app: app) }
    }
}

/// Deleting a memory asks first (it takes its files with it, and there's no undo).
@MainActor
enum MemoryDelete {
    static func confirm(_ item: MemoryItem, app: AppState) {
        let alert = NSAlert()
        alert.messageText = "Delete “\(item.displayTitle)”?"
        alert.informativeText = item.attachments.isEmpty
            ? "Docket forgets it. This can't be undone."
            : "Docket forgets it and deletes its files. This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let run = {
            if app.selectedMemoryID == item.id { withAnimation(Motion.sheet) { app.selectedMemoryID = nil } }
            withAnimation(Motion.base) { MemoryCenter.shared.library.remove(item.id) }
        }
        if let window = NSApp?.keyWindow ?? NSApp?.mainWindow {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { run() }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            run()
        }
    }
}

// MARK: - New note / link

struct MemoryComposeSheet: View {
    enum Mode: String, Identifiable {
        case note, link
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    let saved: (MemoryItem) -> Void
    @State private var title = ""
    @State private var text = ""
    @State private var address = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text(mode == .note ? "New note" : "Add a link")
                .textStyle(.title2)
                .foregroundStyle(Color.ink)
            if mode == .link {
                field("https://…", text: $address)
                field("Why it's worth keeping (optional)", text: $text)
            } else {
                field("Title (optional)", text: $title)
                TextEditor(text: $text)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
                    .frame(minHeight: 160)
                    .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.fill))
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryPill())
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(PrimaryPill())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(Space.xxl)
        .frame(width: 460)
        .background(Color.raised)
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 15, weight: .medium))
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.fill))
            .onSubmit { if canSave { save() } }
    }

    private var link: URL? {
        var a = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty else { return nil }
        if !a.contains("://") { a = "https://" + a }
        return MemoryCenter.singleURL(in: a)
    }

    private var canSave: Bool {
        mode == .link ? link != nil : !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        let center = MemoryCenter.shared
        let item: MemoryItem?
        if mode == .link, let link {
            item = center.capture(link: link, note: text.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            item = center.capture(text: text, title: trimmedTitle.isEmpty ? nil : trimmedTitle)
        }
        dismiss()
        if let item { saved(item) }
    }
}
