import Foundation
import Carbon

/// Registers system-wide hotkeys using the Carbon hotkey API — the same
/// mechanism menu-bar utilities use. Unlike NSEvent global monitors, these
/// need no extra permission and swallow the keystroke.
final class HotkeyManager {

    enum Action: UInt32, CaseIterable {
        /// ⌥Z — toggle voice typing (matches Speechify's default).
        case toggleDictation = 1
        /// ⌥R — speak the text currently selected in any app.
        case readSelection = 2

        var keyCode: UInt32 {
            switch self {
            case .toggleDictation: return 6  // kVK_ANSI_Z
            case .readSelection: return 15   // kVK_ANSI_R
            }
        }

        var modifiers: UInt32 {
            UInt32(optionKey)
        }

        var displayName: String {
            switch self {
            case .toggleDictation: return "⌥Z"
            case .readSelection: return "⌥R"
            }
        }
    }

    private var handlers: [UInt32: () -> Void] = [:]
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var eventHandlerRef: EventHandlerRef?
    private static let signature: OSType = 0x53_50_4B_54 // 'SPKT'

    init() {
        installEventHandler()
    }

    deinit {
        for ref in hotKeyRefs {
            if let ref { UnregisterEventHotKey(ref) }
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    func register(_ action: Action, handler: @escaping () -> Void) {
        handlers[action.rawValue] = handler
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: action.rawValue)
        let status = RegisterEventHotKey(
            action.keyCode,
            action.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr {
            hotKeyRefs.append(ref)
        } else {
            NSLog("Speakit: failed to register hotkey \(action.displayName) (status \(status))")
        }
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return noErr }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                let id = hotKeyID.id
                DispatchQueue.main.async {
                    manager.handlers[id]?()
                }
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &eventHandlerRef
        )
    }
}
