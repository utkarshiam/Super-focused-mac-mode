import MemoryKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var pickFolder = false
    @State private var keyDraft = ""
    @State private var keyMessage: String?
    @AppStorage(SpeechLanguage.defaultsKey) private var speechLanguage = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.x3) {
                    folderSection
                    keySection
                    voiceSection
                    lensSection
                    aboutSection
                }
                .padding(.horizontal, Space.gutter)
                .padding(.top, Space.sm)
                .padding(.bottom, Space.x4)
            }
            .scrollDismissesKeyboard(.interactively)
            .paperBackground()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold).foregroundStyle(Color.ink)
                }
            }
            .fileImporter(isPresented: $pickFolder, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { model.choose(folder: url) }
            }
        }
        .presentationBackground(Color.paper)
    }

    // MARK: Folder

    private var folderSection: some View {
        SettingsSection(title: "Docket folder") {
            HStack(spacing: Space.md) {
                Image(systemName: model.bridgeRoot == nil ? "folder.badge.questionmark" : "folder")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.ink2)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.folderName ?? "Not chosen yet")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.ink)
                    Text(folderStatus)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            Button(model.bridgeRoot == nil ? "Choose folder" : "Change folder") { pickFolder = true }
                .buttonStyle(PrimaryPill(height: 42, fullWidth: true))
            Text("On your Mac: Settings → Memory → iPhone. Then pick iCloud Drive → Docket here.")
                .font(.system(size: 13.5))
                .foregroundStyle(Color.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var folderStatus: String {
        switch model.libraryState {
        case .noFolder: return "Captures wait on this iPhone until you choose it."
        case .loading: return "Opening…"
        case .downloading: return "Downloading from iCloud…"
        case .waitingForMac: return "Waiting for the first update from your Mac."
        case .problem(let message): return message
        case .ready:
            if model.waitingCount > 0 { return "\(model.waitingCount) waiting to sync." }
            return model.lastUpdatedLine ?? "Connected."
        }
    }

    // MARK: Key

    private var keySection: some View {
        SettingsSection(title: "Gemini key") {
            if model.hasKey {
                HStack(spacing: Space.md) {
                    Image(systemName: "key")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.ink2)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.isDemo ? "Demo mode: canned answers" : "Saved in this iPhone's Keychain")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.ink)
                        Text("Used for Ask, search by meaning and voice debriefs.")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.ink2)
                    }
                    Spacer(minLength: 0)
                    if !model.isDemo {
                        Button("Remove") {
                            model.removeKey()
                            keyMessage = nil
                        }
                        .buttonStyle(SecondaryPill(height: 32))
                    }
                }
            } else {
                HStack(spacing: Space.sm) {
                    SecureField("", text: $keyDraft, prompt: Text("Paste your API key").foregroundStyle(Color.ink3))
                        .font(.system(size: 16))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.password)
                        .padding(.horizontal, Space.md)
                        .frame(height: 42)
                        .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Color.fill))
                    Button("Save") {
                        if model.saveKey(keyDraft) {
                            keyDraft = ""
                            keyMessage = nil
                        } else {
                            keyMessage = "Couldn't save the key in the Keychain. Try again."
                        }
                    }
                    .buttonStyle(SecondaryPill(height: 42))
                    .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let keyMessage {
                    Text(keyMessage).font(.system(size: 13)).foregroundStyle(Color.dangerText)
                }
                if let url = URL(string: "https://aistudio.google.com/apikey") {
                    Link(destination: url) {
                        Label("Get a free key at aistudio.google.com", systemImage: "arrow.up.right.square")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.ink)
                    }
                }
            }
            Text("Ask sends your question and the few memories that match it to Google Gemini with your key; a voice debrief sends the recording. The key stays on this iPhone.")
                .font(.system(size: 13.5))
                .foregroundStyle(Color.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Voice

    private var voiceSection: some View {
        SettingsSection(title: "Voice") {
            HStack {
                Text("Speech language").font(.system(size: 16, weight: .medium)).foregroundStyle(Color.ink)
                Spacer()
                Menu {
                    Picker("Speech language", selection: $speechLanguage) {
                        ForEach(SpeechLanguage.choices, id: \.id) { choice in
                            Text(choice.name).tag(choice.id)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(SpeechLanguage.name(for: speechLanguage))
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold))
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.ink)
                }
            }
            Text("For the live transcript while you talk. Gemini writes the real one in whatever you speak, Hindi and English mixed included.")
                .font(.system(size: 13.5))
                .foregroundStyle(Color.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Hairline()
            VStack(alignment: .leading, spacing: 4) {
                Text("Record from anywhere").font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.ink)
                Text("Say “Hey Siri, record in Docket”. For the Action Button: Settings → Action Button → Shortcut → Docket → Record a debrief.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Lenses

    private var lensSection: some View {
        SettingsSection(title: "Lenses") {
            if model.lenses.isEmpty {
                Text("None chosen yet.")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.ink2)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.lenses.enumerated()), id: \.element) { index, lens in
                        if index > 0 { Hairline().padding(.leading, 40) }
                        HStack(alignment: .top, spacing: Space.md) {
                            Image(systemName: lens.symbolName)
                                .font(.system(size: 17))
                                .foregroundStyle(Color.ink2)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(lens.displayName).font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.ink)
                                Text(lens.blurb).font(.system(size: 13)).foregroundStyle(Color.ink2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 10)
                    }
                }
            }
            Text("Lenses change the words Docket uses and what it looks for. Change them on your Mac.")
                .font(.system(size: 13.5))
                .foregroundStyle(Color.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: About

    private var aboutSection: some View {
        SettingsSection(title: "About") {
            HStack {
                Text("Version").font(.system(size: 15)).foregroundStyle(Color.ink)
                Spacer()
                Text(version).font(.system(size: 15)).foregroundStyle(Color.ink2).monospacedDigit()
            }
            Text("No account and no server: Docket syncs through your own iCloud Drive.")
                .font(.system(size: 13.5))
                .foregroundStyle(Color.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}

/// An eyebrow over a hairline card.
private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Eyebrow(title)
            VStack(alignment: .leading, spacing: Space.md) {
                content
            }
            .padding(Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hairlineCard()
        }
    }
}
