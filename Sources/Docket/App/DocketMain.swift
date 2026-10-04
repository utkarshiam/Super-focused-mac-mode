import AppKit

@main
enum DocketMain {
    @MainActor private static var delegate: AppDelegate?

    @MainActor
    static func main() {
        Prefs.registerDefaults()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.run()
    }
}
