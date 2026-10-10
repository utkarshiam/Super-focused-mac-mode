import AppKit
import MemoryKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Memory: lenses and what AI is doing, how the brain is organised (with "Organise now"), what
/// Docket remembers by itself, the iPhone folder, importing from ENGRAM and rebuilding the search index.
struct MemorySettingsPage: View {
    @ObservedObject private var center = MemoryCenter.shared
    @ObservedObject private var library = MemoryCenter.shared.library
    @ObservedObject private var processor = MemoryCenter.shared.processor
    @ObservedObject private var brain = MemoryCenter.shared.brain
    @AppStorage(Prefs.Key.memoryAutoCapture) private var autoCapture = true
    @AppStorage(Prefs.Key.memoryCaptureNotes) private var captureNotes = true
    @AppStorage(Prefs.Key.memoryCaptureMessages) private var captureMessages = true
    @State private var importLine: String?
    @State private var storage: Int64?

    var body: some View {
        SettingsPage {
            SettingsSection(title: "Memory", footer: "Lenses shape what Docket picks out and the words it uses. What it knows about you is in Memory → Profile.") {
                SettingsRow(title: "Lenses", subtitle: lensLine) { lensMenu }
                SettingsRow(title: "AI", subtitle: center.statusLine) {
                    if center.failedCount > 0 && center.hasAI && processor.processingCount == 0 {
                        Button("Try again") { processor.retryFailed() }
                            .buttonStyle(SecondaryPill(height: 30))
                    }
                }
                SettingsRow(title: "Topics", subtitle: center.brainLine) {
                    Button("Organise now") { center.organizeNow() }
                        .buttonStyle(SecondaryPill(height: 30))
                        .disabled(brain.isWorking || library.count < brain.minimumItemsToOrganize)
                        .help("Sort memories into topics and areas again (what you fixed by hand stays)")
                }
                SettingsRow(title: "Storage", subtitle: storageLine, divider: false) {
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: library.directory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(library.directory)
                    }
                    .buttonStyle(SecondaryPill(height: 30))
                }
            }

            SettingsSection(title: "Remember automatically",
                            footer: "Memories stay on this Mac. With a Gemini key, each one is summarised by Google Gemini.") {
                ToggleRow(title: "Remember my work automatically", subtitle: "Without you saving anything", isOn: $autoCapture)
                Group {
                    ToggleRow(title: "Notes", subtitle: "Once you stop editing", isOn: $captureNotes)
                    ToggleRow(title: "Message threads", subtitle: "Summaries, replies you send, and messages you make into tasks or notes",
                              isOn: $captureMessages, divider: false)
                }
                .disabled(!autoCapture)
                .opacity(autoCapture ? 1 : 0.45)
            }

            if let phone = center.phone { PhoneSettingsSection(phone: phone) }

            SettingsSection(title: "Import and index") {
                SettingsRow(title: "Import from ENGRAM", subtitle: importLine ?? "The .json file from ENGRAM's Settings → Export") {
                    Button("Import…", action: importEngram)
                        .buttonStyle(SecondaryPill(height: 30))
                }
                SettingsRow(title: "Rebuild search index", subtitle: "Indexes every memory again", divider: false) {
                    Button("Rebuild") { processor.reembedAll() }
                        .buttonStyle(SecondaryPill(height: 30))
                        .disabled(!center.hasAI || processor.processingCount > 0)
                        .help(center.hasAI ? "Make Ask and search find things again after changing the model" : "Needs a Gemini key")
                }
            }
        }
        .task(id: library.revision) { storage = await center.storageBytes() }
    }

    // MARK: Lenses

    private var lensLine: String {
        library.lenses.isEmpty ? "None chosen yet" : library.lenses.map(\.displayName).joined(separator: ", ")
    }

    private var lensMenu: some View {
        Menu {
            ForEach(Lens.allCases, id: \.self) { lens in
                Button {
                    let chosen = library.lenses
                    library.setLenses(chosen.contains(lens) ? chosen.filter { $0 != lens } : chosen + [lens])
                } label: {
                    if library.lenses.contains(lens) { Label(lens.displayName, systemImage: "checkmark") } else { Text(lens.displayName) }
                }
            }
        } label: {
            (Text("Choose") + Text("  ") + Text(Image(systemName: "chevron.up.chevron.down")).font(.system(size: 9, weight: .bold)))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.ink)
                .padding(.horizontal, 12)
                .frame(height: 30)
        }
        .menuChrome(Capsule())
    }

    // MARK: Storage and import

    /// "412 memories · 38 MB".
    private var storageLine: String {
        let count = MemoryCenter.memories(library.count)
        guard let storage, storage > 0 else { return count }
        return count + " · " + ByteCountFormatter.string(fromByteCount: storage, countStyle: .file)
    }

    private func importEngram() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose an ENGRAM export (.json)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            importLine = MemoryCenter.importLine(try center.importEngram(from: url))
        } catch {
            importLine = (error as? LocalizedError)?.errorDescription ?? "That file isn't an ENGRAM export."
        }
    }
}

/// The iPhone switch, its folder and when it last synced.
private struct PhoneSettingsSection: View {
    @ObservedObject var phone: PhoneSync
    @AppStorage(Prefs.Key.phoneSync) private var phoneSync = false
    @AppStorage(Prefs.Key.phoneFolder) private var phoneFolder = ""

    var body: some View {
        SettingsSection(title: "iPhone", footer: "Install Docket on your iPhone and pick the same Docket folder in iCloud Drive.") {
            ToggleRow(title: "Sync with iPhone", subtitle: phoneSync ? phone.problem : "Off. Nothing leaves this Mac", isOn: $phoneSync)
            SettingsRow(title: "Folder", subtitle: Self.display(PhoneSync.root)) {
                Button("Change…", action: chooseFolder)
                    .buttonStyle(SecondaryPill(height: 30))
            }
            SettingsRow(title: "Last synced", divider: false) {
                Text(phone.lastSync.map(Fmt.dateTime) ?? "Not yet")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.ink2)
            }
        }
    }

    /// "iCloud Drive/Docket", or the path with "~".
    static func display(_ url: URL) -> String {
        let cloud = PhoneSync.defaultRoot.deletingLastPathComponent().path
        if url.path.hasPrefix(cloud + "/") { return "iCloud Drive" + url.path.dropFirst(cloud.count) }
        return (url.path as NSString).abbreviatingWithTildeInPath
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Choose the folder Docket on your iPhone uses"
        panel.directoryURL = PhoneSync.root.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        phoneFolder = url.standardizedFileURL.path == PhoneSync.defaultRoot.standardizedFileURL.path ? "" : url.path
        phone.folderChanged()
    }
}
