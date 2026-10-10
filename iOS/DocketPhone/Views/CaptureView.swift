import MemoryKit
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Home: one big mic (record a debrief), a field you can type or dictate into, and four more ways to
/// capture. Everything becomes a CaptureEnvelope in the Docket folder's Inbox (or waits on the phone until
/// the folder is reachable).
struct CaptureView: View {
    @EnvironmentObject private var model: AppModel
    @State private var text = ""
    @FocusState private var focused: Bool
    @StateObject private var dictation = Dictation()
    /// The text before dictation started; heard words are added after it.
    @State private var textBeforeDictation = ""
    @State private var showTask = false
    @State private var showPhotoChoice = false
    @State private var showPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var showFiles = false

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var link: LinkDetector.Match? { LinkDetector.match(text) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    VoiceCardSlot(voice: model.voice)
                    RecordButtonCard()
                    editor
                    tools
                    status
                    recent
                }
                .padding(.horizontal, Space.gutter)
                .padding(.top, Space.xs)
                .padding(.bottom, Space.x3)
            }
            .scrollDismissesKeyboard(.interactively)
            .paperBackground()
            .navigationTitle("Capture")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { SettingsButton() } }
            .sheet(isPresented: $showTask) {
                TaskComposer(initialTitle: trimmed) { title, due, hasTime in saveTask(title, due: due, hasTime: hasTime) }
                    .presentationDetents([.medium, .large])
                    .presentationBackground(Color.paper)
            }
            .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 10,
                          matching: .any(of: [.images, .videos]))
            .onChange(of: photoItems) { _, items in savePhotos(items) }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in savePhoto(image) }.ignoresSafeArea()
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { saveFiles(urls) }
            }
            .confirmationDialog("Add a photo", isPresented: $showPhotoChoice) {
                Button("Take photo") { showCamera = true }
                Button("Choose from library") { showPhotos = true }
            }
        }
    }

    // MARK: Editor

    private var editor: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            TextField("", text: $text, prompt: Text("What's on your mind?").foregroundStyle(Color.ink3), axis: .vertical)
                .font(.system(size: 19))
                .tracking(-0.2)
                .foregroundStyle(Color.ink)
                .lineLimit(3...12)
                .focused($focused)
            HStack(spacing: Space.sm) {
                Button {
                    toggleDictation()
                } label: {
                    Image(systemName: dictation.isActive ? "stop.fill" : "mic")
                        .foregroundStyle(dictation.isActive ? Color.danger : Color.ink)
                }
                .buttonStyle(IconButtonStyle(size: 36))
                .overlay(Circle().strokeBorder(Color.danger.opacity(dictation.isActive ? 0.25 + 0.5 * dictation.level : 0), lineWidth: 2))
                .accessibilityLabel(dictation.isActive ? "Stop dictating" : "Dictate")
                if dictation.isActive {
                    Text("Listening…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.ink2)
                } else if let link {
                    Label(LinkDetector.host(link.url), systemImage: "link")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.ink2)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button(link != nil ? "Save link" : "Save") { saveText() }
                    .buttonStyle(SecondaryPill(height: 38))
                    .disabled(trimmed.isEmpty || dictation.isActive)
            }
        }
        .padding(Space.lg)
        .hairlineCard()
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .onChange(of: dictation.text) { _, heard in
            guard dictation.isActive else { return }
            text = Self.join(textBeforeDictation, heard)
        }
        .onDisappear { dictation.cancel() }
    }

    private func toggleDictation() {
        if dictation.isActive {
            Task {
                let heard = await dictation.stop()
                text = Self.join(textBeforeDictation, heard)
            }
        } else {
            focused = false
            textBeforeDictation = text
            Task {
                if let problem = await dictation.start() { model.show(problem) }
            }
        }
    }

    private static func join(_ a: String, _ b: String) -> String {
        let a = a.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + (a.hasSuffix("\n") ? "" : " ") + b
    }

    // MARK: Tools

    private var tools: some View {
        HStack(spacing: Space.sm) {
            ToolButton(symbol: "photo", title: "Photo") {
                focused = false
                if UIImagePickerController.isSourceTypeAvailable(.camera) { showPhotoChoice = true } else { showPhotos = true }
            }
            ToolButton(symbol: "doc", title: "File") { focused = false; showFiles = true }
            ToolButton(symbol: "link", title: "Paste link") { pasteLink() }
            ToolButton(symbol: "checkmark.circle", title: "Task") { focused = false; showTask = true }
        }
    }

    // MARK: Status

    @ViewBuilder
    private var status: some View {
        if model.bridgeRoot == nil {
            HStack(alignment: .center, spacing: Space.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Choose your Docket folder").textStyle(.subheadStrong).foregroundStyle(Color.ink)
                    Text(model.waitingCount > 0 ? "\(PhoneFmt.count(model.waitingCount, "capture")) waiting on this iPhone."
                         : "Until then, captures wait on this iPhone.")
                        .font(.system(size: 13)).foregroundStyle(Color.ink2)
                }
                Spacer(minLength: 0)
                Button("Choose") { model.showSettings = true }
                    .buttonStyle(SecondaryPill(height: 34))
            }
            .padding(Space.md)
            .padding(.leading, Space.xs)
            .hairlineCard(radius: Radius.md)
        } else if model.waitingCount > 0 || model.syncProblem != nil {
            VStack(alignment: .leading, spacing: Space.xs) {
                if model.waitingCount > 0 {
                    Label("\(model.waitingCount) waiting to sync", systemImage: "clock")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Tone.warning.fg)
                }
                if let problem = model.syncProblem {
                    Text(problem).font(.system(size: 13)).foregroundStyle(Color.ink2)
                }
            }
        }
    }

    // MARK: Recent

    @ViewBuilder
    private var recent: some View {
        if !model.records.isEmpty {
            VStack(alignment: .leading, spacing: Space.sm) {
                Eyebrow("Recent")
                VStack(spacing: 0) {
                    ForEach(Array(model.records.prefix(12).enumerated()), id: \.element.id) { index, record in
                        if index > 0 { Hairline().padding(.leading, 52) }
                        RecentRow(record: record)
                    }
                }
            }
        }
    }

    // MARK: Saving

    /// The field's text as a caption for a photo, recording or file (then cleared).
    private func takeCaption() -> String? {
        let caption = trimmed
        text = ""
        return caption.isEmpty ? nil : caption
    }

    private func saveText() {
        guard !trimmed.isEmpty else { return }
        if let link {
            let host = LinkDetector.host(link.url)
            model.capture(CaptureEnvelope(kind: .link, text: link.note.isEmpty ? nil : link.note, url: link.url),
                          title: link.note.isEmpty ? link.url : link.note, detail: host)
        } else {
            let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
            model.capture(CaptureEnvelope(kind: .note, text: trimmed), title: firstLine)
        }
        text = ""
        focused = false
    }

    private func pasteLink() {
        let board = UIPasteboard.general
        guard board.hasURLs || board.hasStrings else {
            model.show("Nothing to paste. Copy a link first.")
            return
        }
        var found: String?
        if let url = board.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            found = url.absoluteString
        } else if let string = board.string, let match = LinkDetector.match(string) {
            found = match.url
        }
        guard let found else {
            model.show("No link on the clipboard.")
            return
        }
        text = trimmed.isEmpty ? found : trimmed + "\n" + found
    }

    private func saveTask(_ title: String, due: Date?, hasTime: Bool) {
        if trimmed == title.trimmingCharacters(in: .whitespacesAndNewlines) { text = "" }
        model.capture(CaptureEnvelope(kind: .task, title: title, due: due, dueHasTime: hasTime),
                      title: title, detail: due.map { "Due \(PhoneFmt.due($0, hasTime: hasTime))" })
    }

    private func savePhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        let caption = takeCaption()
        Task {
            for (index, item) in items.enumerated() {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                let type = item.supportedContentTypes.first
                let isVideo = type?.conforms(to: .movie) ?? false
                let ext = type?.preferredFilenameExtension ?? (isVideo ? "mov" : "jpg")
                let suffix = items.count > 1 ? " \(index + 1)" : ""
                let name = "\(isVideo ? "Video" : "Photo") \(PhoneFmt.fileStamp())\(suffix).\(ext)"
                model.capture(CaptureEnvelope(kind: isVideo ? .file : .photo, text: caption),
                              attachment: .data(data, name: name), title: caption ?? (isVideo ? "Video" : "Photo"))
            }
            photoItems = []
        }
    }

    private func savePhoto(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
        let caption = takeCaption()
        model.capture(CaptureEnvelope(kind: .photo, text: caption),
                      attachment: .data(data, name: "Photo \(PhoneFmt.fileStamp()).jpg"), title: caption ?? "Photo")
    }

    private func saveFiles(_ urls: [URL]) {
        let caption = takeCaption()
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            model.capture(CaptureEnvelope(kind: .file, text: caption), attachment: .file(url, move: false),
                          title: url.lastPathComponent)
        }
    }
}

// MARK: - Pieces

private struct ToolButton: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .medium))
                    .frame(height: 22)
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(Color.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 66)
            .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.fill))
        }
        .buttonStyle(PressScale(scale: 0.95))
    }
}

private struct RecentRow: View {
    let record: CaptureRecord

    var body: some View {
        HStack(spacing: Space.md) {
            KindTile(symbol: record.kind.symbolName, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.ink3)
                    .lineLimit(1)
            }
            Spacer(minLength: Space.sm)
            stateView
        }
        .padding(.vertical, 10)
    }

    private var subtitle: String {
        let when = PhoneFmt.dayTime(record.createdAt)
        guard let detail = record.detail, !detail.isEmpty else { return when }
        return "\(when) · \(detail)"
    }

    @ViewBuilder
    private var stateView: some View {
        switch record.state {
        case .waiting:
            Badge(text: "Waiting", tone: .warning, icon: "clock")
        case .synced:
            Image(systemName: "icloud.and.arrow.up")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.ink3)
                .accessibilityLabel("Synced to the Docket folder")
        case .received:
            Image(systemName: "checkmark.circle")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.ink3)
                .accessibilityLabel("On your Mac")
        }
    }
}

extension CaptureEnvelope.Kind {
    var symbolName: String {
        switch self {
        case .note: "note.text"
        case .link: "link"
        case .photo: "photo"
        case .voice: "waveform"
        case .file: "doc"
        case .task: "checkmark.circle"
        case .taskDone: "checkmark.circle.fill"
        case .taskUndone: "arrow.uturn.backward.circle"
        case .taskDelete: "trash"
        }
    }
}

// MARK: - Voice

/// The result card of the latest recording, while it's open.
private struct VoiceCardSlot: View {
    @ObservedObject var voice: VoiceCenter

    var body: some View {
        if let job = voice.card {
            DebriefCardView(job: job)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

// MARK: - Camera

struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onImage: onImage, dismiss: { dismiss() }) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImage: (UIImage) -> Void
        let dismiss: () -> Void

        init(onImage: @escaping (UIImage) -> Void, dismiss: @escaping () -> Void) {
            self.onImage = onImage
            self.dismiss = dismiss
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { onImage(image) }
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { dismiss() }
    }
}
