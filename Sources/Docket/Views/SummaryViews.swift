import SwiftUI

// The "Summary" card at the top of an open thread in Messages, and "Save as note" from any message.

// MARK: - Summary

/// At the top of the thread: for an important one, its summary (2–4 bullets and "Needs from you: …"), made by
/// itself when it opens and again when the thread changed, with a refresh. For any other, a Summarize button.
/// Nothing without AI (off, or no key).
struct ThreadSummaryCard: View {
    @ObservedObject private var integrations = Integrations.shared
    let itemID: String

    var body: some View {
        let summary = integrations.summary(for: itemID)
        let working = integrations.summarizing.contains(itemID)
        let problem = integrations.summaryProblems[itemID]
        Group {
            if !integrations.showsSummaries {
                EmptyView()
            } else if let summary {
                card(summary, working: working, problem: problem)
            } else if working {
                writing
            } else if let problem, integrations.isImportant(itemID) {
                problemLine(problem)
            } else {
                summarizeButton
            }
        }
        .animation(Motion.base, value: summary)
        .animation(Motion.base, value: working)
    }

    private func card(_ summary: ThreadSummary, working: Bool, problem: String?) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .center, spacing: Space.sm) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.ink2)
                Eyebrow(text: "Summary")
                Spacer(minLength: Space.sm)
                if !integrations.summaryIsCurrent(itemID), !working {
                    Text("Thread changed")
                        .textStyle(.caption)
                        .foregroundStyle(Color.ink3)
                }
                refreshButton(working: working)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(summary.bullets.enumerated()), id: \.offset) { _, bullet in
                    HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                        Text("•").foregroundStyle(Color.ink3)
                        Text(bullet)
                            .foregroundStyle(Color.bodyText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.system(size: 14))
            .textSelection(.enabled)
            if let needs = summary.needsFromYou {
                (Text("Needs from you: ").fontWeight(.semibold).foregroundColor(Color.ink) + Text(needs).foregroundColor(Color.ink))
                    .font(.system(size: 14))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.top, 2)
            }
            if let problem {
                Text("Couldn't update it. \(problem)")
                    .textStyle(.footnote)
                    .foregroundStyle(Color.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Color.hair, lineWidth: 1))
        .help("Written by AI from the whole thread on \(Fmt.dateTime(summary.madeAt)). Check the messages for anything that matters.")
        .transition(.opacity)
    }

    @ViewBuilder
    private func refreshButton(working: Bool) -> some View {
        if working {
            ProgressView()
                .controlSize(.small)
                .frame(width: 24, height: 24)
                .help("Summarizing the thread…")
        } else {
            Button { Task { await integrations.summarize(itemID, force: true) } } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(IconButtonStyle(size: 24))
            .help("Summarize the thread again")
            .accessibilityLabel("Summarize again")
        }
    }

    private var writing: some View {
        HStack(spacing: Space.sm) {
            ProgressView().controlSize(.small)
            Text("Summarizing the thread…")
                .textStyle(.footnote)
                .foregroundStyle(Color.ink2)
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Color.hair, lineWidth: 1))
        .transition(.opacity)
    }

    private func problemLine(_ problem: String) -> some View {
        HStack(alignment: .center, spacing: Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.warning)
            Text("Couldn't summarize it. \(problem)")
                .textStyle(.footnote)
                .foregroundStyle(Color.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.sm)
            Button("Try again") { Task { await integrations.summarize(itemID, force: true) } }
                .buttonStyle(SecondaryPill(height: 26))
                .help("Summarize the thread again")
        }
        .transition(.opacity)
    }

    private var summarizeButton: some View {
        Button { Task { await integrations.summarize(itemID, force: true) } } label: {
            Label("Summarize", systemImage: "sparkles")
        }
        .buttonStyle(SecondaryPill(height: 28))
        .help("Have AI sum up the thread in a few bullets, with what it needs from you")
        .transition(.opacity)
    }
}

// MARK: - Save as note

/// "Save as note" from the inbox: the list's menu, the open message's ⋯, a message of its thread.
@MainActor
enum InboxNotes {
    /// Items being saved, so a second click waits.
    private static var saving: Set<String> = []

    /// Saves the item's whole thread (or one message of it) as a note, then says so and opens the note.
    static func save(item id: String, message: String? = nil, app: AppState, integrations: Integrations? = nil) {
        let integrations = integrations ?? .shared
        let key = id + " " + (message ?? "")
        guard saving.insert(key).inserted else { return }
        Task {
            defer { saving.remove(key) }
            do {
                let note = try await integrations.saveAsNote(id, message: message, now: app.clock)
                Haptics.success()
                app.noteModes[note.id] = .read
                app.showToast("Saved as a note")
                app.reveal(note: note.id)
            } catch {
                let e = IntegrationError.wrap(error, id.hasPrefix("gmail:") ? .gmail : .slack)
                app.showToast("Couldn't save it as a note. \(e.errorDescription ?? "")")
            }
        }
    }
}
