import Carbon.HIToolbox
import Foundation

/// System-wide shortcut via the Carbon hot key API (works without Accessibility permission).
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    var action: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handlerInstalled = false

    /// Returns false if another app already owns the combination.
    @discardableResult
    func register(_ preset: HotKeyPreset) -> Bool {
        unregister()
        installHandlerIfNeeded()
        let (code, modifiers) = preset.carbon
        let id = EventHotKeyID(signature: OSType(0x444B_5431), id: 1) // 'DKT1'
        let status = RegisterEventHotKey(code, modifiers, id, GetApplicationEventTarget(), 0, &ref)
        return status == noErr
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKeyCenter.shared.action?() }
            return noErr
        }, 1, &spec, nil, nil)
        handlerInstalled = true
    }
}

extension HotKeyPreset {
    var carbon: (UInt32, UInt32) {
        switch self {
        case .controlOptionT: (UInt32(kVK_ANSI_T), UInt32(controlKey | optionKey))
        case .controlOptionSpace: (UInt32(kVK_Space), UInt32(controlKey | optionKey))
        case .controlOptionN: (UInt32(kVK_ANSI_N), UInt32(controlKey | optionKey))
        case .commandShiftSpace: (UInt32(kVK_Space), UInt32(cmdKey | shiftKey))
        case .commandOptionK: (UInt32(kVK_ANSI_K), UInt32(cmdKey | optionKey))
        }
    }
}
