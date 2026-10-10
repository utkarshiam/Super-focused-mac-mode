import MemoryKit
import SwiftUI

// MARK: - "What do you do?"

/// Memory's first screen: the six lenses to pick from (any number; the first names things), and one
/// optional line about the user, saved as a pinned fact. Skip counts as choosing none.
struct LensOnboardingCard: View {
    @ObservedObject var library: MemoryLibrary
    @State private var picked: [Lens] = []
    @State private var about = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What do you do?")
                    .textStyle(.title2)
                    .foregroundStyle(Color.ink)
                Text("Pick any that fit. Docket listens for different things in each, and calls them what you would.")
                    .textStyle(.callout)
                    .foregroundStyle(Color.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Two to a row, each row as tall as its taller card.
            Grid(horizontalSpacing: Space.sm, verticalSpacing: Space.sm) {
                ForEach(0..<(Lens.allCases.count + 1) / 2, id: \.self) { row in
                    GridRow {
                        ForEach(Array(Lens.allCases.dropFirst(row * 2).prefix(2))) { lens in card(lens) }
                    }
                }
            }
            TextField("Anything Docket should know about you? (optional)", text: $about)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium))
                .padding(.horizontal, 12)
                .frame(height: 42)
                .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.fill))
                .onSubmit { if !picked.isEmpty { finish(picked) } }
            HStack(spacing: Space.sm) {
                Text("You can change this any time.")
                    .textStyle(.footnote)
                    .foregroundStyle(Color.ink3)
                Spacer()
                Button("Skip") { finish([]) }
                    .buttonStyle(SecondaryPill())
                    .help("Use neutral words; pick later from What Docket knows about me")
                Button("Continue") { finish(picked) }
                    .buttonStyle(PrimaryPill())
                    .disabled(picked.isEmpty)
            }
        }
        .padding(Space.xxl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hairlineCard()
        .enterUp()
    }

    private func card(_ lens: Lens) -> some View {
        LensCard(lens: lens, isOn: picked.contains(lens), primary: picked.count > 1 && picked.first == lens) {
            withAnimation(Motion.snappy) {
                if let i = picked.firstIndex(of: lens) { picked.remove(at: i) } else { picked.append(lens) }
            }
            Haptics.select()
        }
    }

    private func finish(_ lenses: [Lens]) {
        let line = about.trimmingCharacters(in: .whitespacesAndNewlines)
        withAnimation(Motion.gentle) {
            library.batch {
                if !line.isEmpty { library.addFact(line, category: .identity, pinned: true) }
                library.setLenses(lenses)
            }
        }
        MemoryView.debugOnboarding = false
    }
}

// MARK: - What Docket knows about me

/// The profile every AI call gets as context: the lenses, and facts by category. AI keeps the facts
/// current from memory ("Refresh"); pinned facts and the user's own stay exactly as written.
struct MemoryProfileView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var center = MemoryCenter.shared
    @ObservedObject private var library = MemoryCenter.shared.library
    @State private var newFact = ""
    @State private var newCategory: ProfileFact.Category = .work
    @State private var refreshing = false
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("What Docket knows about me")
                        .textStyle(.title2)
                        .foregroundStyle(Color.ink)
                    Text("Docket reads this before it summarises or answers. Pinned facts stay exactly as written.")
                        .textStyle(.callout)
                        .foregroundStyle(Color.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Space.md)
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle(size: 28, filled: true))
                    .keyboardShortcut(.cancelAction)
                    .help("Close")
            }
            .padding(.horizontal, Space.xxl)
            .padding(.top, Space.xxl)
            .padding(.bottom, Space.lg)

            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Eyebrow(text: "What I do").padding(.leading, 4)
                        LensToggles(library: library)
                        Text(vocabularyLine)
                            .textStyle(.footnote)
                            .foregroundStyle(Color.ink3)
                            .padding(.leading, 4)
                    }
                    facts
                    addRow
                }
                .padding(.horizontal, Space.xxl)
                .padding(.bottom, Space.xl)
            }

            Rectangle().fill(Color.hair).frame(height: 1)
            footer
        }
        .frame(width: 580, height: 640)
        .background(Color.raised)
    }

    /// "Projects are called Initiatives here, insights Learnings."
    private var vocabularyLine: String {
        let v = library.vocabulary
        guard !library.lenses.isEmpty else { return "No lens: Docket uses plain words (projects, promises, insights)." }
        return "\(v.projects) for projects, \(v.promises.lowercased()) for promises, \(v.insights.lowercased()) for insights."
    }

    @ViewBuilder
    private var facts: some View {
        let all = library.profile.facts
        if all.isEmpty {
            Text("Nothing yet. Add something below\(center.hasAI ? ", or refresh from your memory." : ".")")
                .textStyle(.callout)
                .foregroundStyle(Color.ink2)
        } else {
            ForEach(ProfileFact.Category.allCases) { category in
                let list = all.filter { $0.category == category }
                if !list.isEmpty {
                    DetailSection(category.label) {
                        ForEach(list) { fact in
                            ProfileFactRow(fact: fact, library: library)
                        }
                    }
                }
            }
        }
    }

    private var addRow: some View {
        HStack(spacing: Space.sm) {
            TextField("Add something Docket should know", text: $newFact)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium))
                .onSubmit(add)
            Menu {
                ForEach(ProfileFact.Category.allCases) { c in
                    Button(c.label) { newCategory = c }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(newCategory.label)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold))
                }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.ink2)
                .padding(.horizontal, 10)
                .frame(height: 26)
            }
            .menuChrome(Capsule(), fill: .fillStrong, hoverFill: .hairStrong)
            .help("What kind of fact it is")
            Button("Add", action: add)
                .buttonStyle(SecondaryPill(height: 28))
                .disabled(newFact.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.leading, Space.md)
        .padding(.trailing, 6)
        .frame(height: 42)
        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.fill))
    }

    private var footer: some View {
        HStack(spacing: Space.md) {
            Button {
                Task { await refresh() }
            } label: {
                HStack(spacing: 6) {
                    if refreshing { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                    Text("Refresh from my memory")
                }
            }
            .buttonStyle(SecondaryPill(height: 32))
            .disabled(!center.hasAI || refreshing || library.count == 0)
            .help(center.hasAI ? "Read recent and pinned memories again and update the facts (pinned ones stay)" : MemoryText.noKey)
            VStack(alignment: .leading, spacing: 1) {
                if let problem {
                    Text(problem).foregroundStyle(Color.dangerText).lineLimit(2)
                } else if let when = library.profile.refreshedAt {
                    Text("Last refreshed \(MemoryText.date(when, now: app.clock))")
                } else if !center.hasAI {
                    Text("Add a Gemini key in Settings → AI to refresh.")
                }
            }
            .textStyle(.caption)
            .foregroundStyle(Color.ink3)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(PrimaryPill())
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, Space.xxl)
        .frame(height: 64)
    }

    private func add() {
        guard library.addFact(newFact, category: newCategory, pinned: true) != nil else { return }
        newFact = ""
    }

    private func refresh() async {
        guard let ai = center.processor.ai else { return }
        refreshing = true
        problem = nil
        do {
            try await ProfileSynthesizer(ai: ai).refresh(library)
        } catch {
            problem = (error as? MemoryAIError)?.errorDescription ?? error.localizedDescription
        }
        refreshing = false
    }
}

/// One fact: click it to edit in place (Return saves; empty deletes), pin it, or remove it. It's plain text
/// until clicked, so opening the sheet doesn't put the cursor in the first fact.
private struct ProfileFactRow: View {
    let fact: ProfileFact
    @ObservedObject var library: MemoryLibrary
    @State private var text = ""
    @State private var editing = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Group {
                if editing {
                    TextField("", text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...4)
                        .focused($focused)
                        .onSubmit(save)
                        .onChange(of: focused) { f in if !f { save() } }
                        .onAppear { focused = true }
                } else {
                    Text(fact.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            text = fact.text
                            editing = true
                        }
                        .help("Click to edit")
                }
            }
            .font(.system(size: 13.5, weight: .medium))
            .foregroundStyle(Color.ink)
            if fact.source == .ai && !fact.pinned {
                Image(systemName: "sparkle")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.ink3)
                    .help("Docket worked this out from your memory. Pin it to keep it as it is.")
            }
            Button { withAnimation(Motion.snappy) { library.setFactPinned(fact.id, !fact.pinned) } } label: {
                Image(systemName: fact.pinned ? "pin.fill" : "pin").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(IconButtonStyle(size: 24, filled: fact.pinned))
            .help(fact.pinned ? "Unpin: AI may update it" : "Pin: AI never changes it")
            Button { withAnimation(Motion.base) { library.removeFact(fact.id) } } label: {
                Image(systemName: "minus").font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(IconButtonStyle(size: 24))
            .help("Forget this")
        }
        .padding(.leading, Space.md)
        .padding(.trailing, Space.sm)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.hair).frame(height: 1).padding(.leading, Space.md) }
    }

    private func save() {
        guard editing else { return }
        editing = false
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != fact.text else { return }
        var updated = fact
        updated.text = trimmed
        library.updateFact(updated)
    }
}
