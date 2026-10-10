import MemoryKit
import SwiftUI

/// Ask your memory: answers come only from your items, with [n] citations that open them.
struct AskView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        AskScreen(session: model.ask)
    }
}

private struct AskScreen: View {
    @ObservedObject var session: AskSession
    @EnvironmentObject private var model: AppModel
    @FocusState private var focused: Bool
    @State private var openItem: OpenItem?
    @StateObject private var dictation = Dictation()

    struct OpenItem: Identifiable {
        let id: UUID
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.x3) {
                        if !model.hasKey {
                            NoKeyCard()
                        } else if session.entries.isEmpty {
                            examples
                        } else {
                            ForEach(session.entries) { entry in
                                AskEntryView(entry: entry, session: session) { openItem = OpenItem(id: $0) }
                                    .id(entry.id)
                            }
                        }
                    }
                    .padding(.horizontal, Space.gutter)
                    .padding(.top, Space.sm)
                    .padding(.bottom, Space.xxl)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: session.entries.count) { _, _ in
                    if let last = session.entries.last?.id {
                        withAnimation(Motion.gentle) { proxy.scrollTo(last, anchor: .top) }
                    }
                }
            }
            .paperBackground()
            .navigationTitle("Ask")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !session.entries.isEmpty {
                        Button("Clear") { withAnimation(Motion.snappy) { session.clear() } }
                            .foregroundStyle(Color.ink2)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { SettingsButton() }
            }
            .safeAreaInset(edge: .bottom) {
                if model.hasKey { inputBar }
            }
            .sheet(item: $openItem) { item in
                ItemSheet(itemID: item.id).environmentObject(model)
            }
        }
    }

    // MARK: Empty

    private var examples: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Ask anything you've saved").textStyle(.title3).foregroundStyle(Color.ink)
                Text("Answers come only from your memory, with the sources they used.")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                ForEach(Array(Lens.askExamples(for: model.lenses).enumerated()), id: \.offset) { index, question in
                    if index > 0 { Hairline() }
                    Button {
                        session.ask(question, model: model)
                    } label: {
                        HStack(spacing: Space.md) {
                            Text(question)
                                .font(.system(size: 16))
                                .foregroundStyle(Color.ink)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: Space.sm)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.ink3)
                        }
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScale(scale: 0.985))
                }
            }
        }
    }

    // MARK: Input

    private var inputBar: some View {
        let empty = session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(alignment: .bottom, spacing: Space.sm) {
            TextField("", text: $session.draft,
                      prompt: Text(dictation.isActive ? "Listening…" : "Ask your memory").foregroundStyle(Color.ink3), axis: .vertical)
                .font(.system(size: 16))
                .foregroundStyle(Color.ink)
                .lineLimit(1...5)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit { send() }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.card))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.hairStrong, lineWidth: 1))
            if dictation.isActive {
                // Stop listening and ask what was heard.
                Button {
                    Task {
                        let heard = await dictation.stop()
                        if !heard.isEmpty { session.draft = heard }
                        send()
                    }
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(IconButtonStyle(size: 44, primary: true))
                .overlay(Circle().strokeBorder(Color.danger.opacity(0.3 + 0.6 * dictation.level), lineWidth: 2.5).padding(-3))
                .accessibilityLabel("Stop and ask")
            } else if empty {
                Button {
                    focused = false
                    Task { if let problem = await dictation.start() { model.show(problem) } }
                } label: {
                    Image(systemName: "mic.fill")
                }
                .buttonStyle(IconButtonStyle(size: 44, primary: true))
                .disabled(session.isBusy)
                .accessibilityLabel("Ask by voice")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(IconButtonStyle(size: 44, primary: true))
                .disabled(session.isBusy)
                .accessibilityLabel("Ask")
            }
        }
        .onChange(of: dictation.text) { _, heard in
            if dictation.isActive { session.draft = heard }
        }
        .onDisappear { dictation.cancel() }
        .padding(.horizontal, Space.gutter)
        .padding(.top, Space.sm)
        .padding(.bottom, Space.sm)
        .background(Color.paper.opacity(0.96))
    }

    private func send() {
        session.ask(session.draft, model: model)
    }
}

// MARK: - One exchange

private struct AskEntryView: View {
    let entry: AskSession.Entry
    @ObservedObject var session: AskSession
    let open: (UUID) -> Void
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text(entry.question)
                .font(.system(size: 20, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let answer = entry.answer {
                answerView(answer)
            } else if let error = entry.error {
                VStack(alignment: .leading, spacing: Space.md) {
                    Text(error).font(.system(size: 15)).foregroundStyle(Color.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: Space.sm) {
                        Button("Try again") { session.retry(entry, model: model) }
                            .buttonStyle(SecondaryPill(height: 34))
                        if entry.needsSettings {
                            Button("Open Settings") { model.showSettings = true }
                                .buttonStyle(SecondaryPill(height: 34))
                        }
                    }
                }
            } else {
                HStack(spacing: Space.sm) {
                    ProgressView().tint(Color.ink2)
                    Text("Looking through your memory…").font(.system(size: 15)).foregroundStyle(Color.ink2)
                }
            }
        }
    }

    @ViewBuilder
    private func answerView(_ answer: MemoryAnswer) -> some View {
        Text(Self.attributed(answer.text))
            .font(.system(size: 17))
            .lineSpacing(4)
            .foregroundStyle(answer.answered ? Color.bodyText : Color.ink2)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "docket-cite", let n = Int(url.host ?? ""), let item = answer.item(forCitation: n) else {
                    return .systemAction
                }
                open(item.id)
                return .handled
            })
        ListenButton(text: answer.text, id: entry.id)
        if !answer.citations.isEmpty {
            VStack(alignment: .leading, spacing: Space.sm) {
                Eyebrow("Sources")
                VStack(spacing: Space.sm) {
                    ForEach(answer.citations, id: \.number) { citation in
                        if let item = answer.item(forCitation: citation.number) {
                            SourceChip(number: citation.number, item: item) { open(item.id) }
                        }
                    }
                }
            }
        }
        if !answer.followUps.isEmpty {
            VStack(alignment: .leading, spacing: Space.sm) {
                Eyebrow("Ask next")
                FlowLayout(spacing: Space.sm) {
                    ForEach(answer.followUps, id: \.self) { question in
                        Button(question) { session.ask(question, model: model) }
                            .buttonStyle(SecondaryPill(height: 34))
                            .disabled(session.isBusy)
                    }
                }
            }
        }
    }

    /// The answer with each [n] as a small tappable number.
    static func attributed(_ text: String) -> AttributedString {
        var out = AttributedString()
        guard let regex = try? NSRegularExpression(pattern: #"\[(\d+)\]"#) else { return AttributedString(text) }
        let ns = text as NSString
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += AttributedString(ns.substring(with: NSRange(location: last, length: match.range.location - last)))
            let number = ns.substring(with: match.range(at: 1))
            var marker = AttributedString("\u{2009}\(number)")
            marker.swiftUI.font = .system(size: 12, weight: .bold)
            marker.swiftUI.baselineOffset = 5
            marker.swiftUI.foregroundColor = Color.ink2
            marker.link = URL(string: "docket-cite://\(number)")
            out += marker
            last = match.range.location + match.range.length
        }
        out += AttributedString(ns.substring(from: last))
        return out
    }
}

private struct SourceChip: View {
    let number: Int
    let item: MemoryItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.md) {
                Text("\(number)")
                    .font(.system(size: 12, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.ink)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.fill))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayTitle)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                    Text("\(item.kind.label) · \(PhoneFmt.day(item.createdAt))")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.ink3)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.ink3)
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, 10)
            .hairlineCard(radius: Radius.md)
        }
        .buttonStyle(PressScale(scale: 0.985))
    }
}

/// Reads an answer aloud (and stops it).
private struct ListenButton: View {
    let text: String
    let id: UUID
    @ObservedObject private var speaker = Speaker.shared

    var body: some View {
        let speaking = speaker.speakingID == id
        Button {
            speaker.toggle(text, id: id)
        } label: {
            Label(speaking ? "Stop" : "Listen", systemImage: speaking ? "stop.fill" : "speaker.wave.2")
                .font(.system(size: 14, weight: .semibold))
        }
        .buttonStyle(SecondaryPill(height: 32))
        .accessibilityLabel(speaking ? "Stop reading" : "Read the answer aloud")
    }
}

/// Shown on Ask without a Gemini key.
private struct NoKeyCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Ask needs your Gemini key").textStyle(.title3).foregroundStyle(Color.ink)
            Text("Docket answers from your memory using Google Gemini with your own key. Your question and the few memories that match it go to Google; nothing else leaves this iPhone.")
                .font(.system(size: 15))
                .foregroundStyle(Color.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Text("Without a key, search in Memory still works.")
                .font(.system(size: 15))
                .foregroundStyle(Color.ink2)
            Button("Add key in Settings") { model.showSettings = true }
                .buttonStyle(PrimaryPill(height: 42))
                .padding(.top, Space.xs)
        }
        .padding(Space.xl)
        .hairlineCard()
    }
}

/// An item opened from Ask (or anywhere outside the Memory tab), in its own stack.
struct ItemSheet: View {
    let itemID: UUID
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ItemDetailView(itemID: itemID)
                .navigationDestination(for: UUID.self) { ItemDetailView(itemID: $0) }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }.fontWeight(.semibold).foregroundStyle(Color.ink)
                    }
                }
        }
    }
}
