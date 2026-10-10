import SwiftUI

@main
struct DocketPhoneApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .tint(.ink)
                .task { await model.start() }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active: Task { await model.refresh() }
                    case .background: model.voice.enterBackground()
                    default: break
                    }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var router = LaunchRouter.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $model.tab) {
            CaptureView()
                .tabItem { Label("Capture", systemImage: "square.and.pencil") }
                .tag(AppModel.Tab.capture)
            MemoryView()
                .tabItem { Label("Memory", systemImage: "books.vertical") }
                .tag(AppModel.Tab.memory)
            AskView()
                .tabItem { Label("Ask", systemImage: "text.bubble") }
                .tag(AppModel.Tab.ask)
            TodayView()
                .tabItem { Label("Today", systemImage: "checklist") }
                .tag(AppModel.Tab.today)
        }
        .overlay(alignment: .top) { ToastView() }
        .sheet(isPresented: $model.showSettings) {
            SettingsView().environmentObject(model)
        }
        .modifier(RecordingCover(recorder: model.voice.recorder))
        .onChange(of: model.tab) { _, tab in
            if tab != .capture { model.voice.closeCard() }
        }
        .onOpenURL { url in _ = router.handle(url) }
        .onChange(of: router.wantsRecording) { _, _ in startRecordingIfAsked() }
        .onChange(of: scenePhase) { _, _ in startRecordingIfAsked() }
        .onAppear { startRecordingIfAsked() }
    }

    /// Siri, the Action Button or docket://record asked for a recording: start once the app is in front.
    private func startRecordingIfAsked() {
        guard router.wantsRecording, scenePhase == .active else { return }
        router.wantsRecording = false
        model.showSettings = false
        model.tab = .capture
        Task { await model.voice.startRecording() }
    }
}

/// The recording screen covers everything while a recording runs.
private struct RecordingCover: ViewModifier {
    @ObservedObject var recorder: VoiceRecorder
    @EnvironmentObject private var model: AppModel

    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: Binding(get: { recorder.isActive }, set: { _ in })) {
            RecordingView(voice: model.voice, recorder: recorder)
                .environmentObject(model)
        }
    }
}

/// The gear in every tab's navigation bar.
struct SettingsButton: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button {
            model.showSettings = true
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.ink)
        }
        .accessibilityLabel("Settings")
    }
}

/// A short confirmation that floats over the content for a moment, sometimes with an Undo.
private struct ToastView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let message = model.toast {
            HStack(spacing: Space.md) {
                Text(message)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.onPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                if let action = model.toastAction {
                    Button {
                        action.run()
                        model.dismissToast()
                    } label: {
                        Text(action.title)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.onPrimary)
                            .underline()
                    }
                    .buttonStyle(PressScale(scale: 0.95))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.primaryFill))
            .floatShadow()
            .padding(.horizontal, Space.gutter)
            .padding(.top, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
            .onTapGesture { if model.toastAction == nil { model.dismissToast() } }
        }
    }
}
