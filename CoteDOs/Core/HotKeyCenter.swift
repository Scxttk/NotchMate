import Carbon.HIToolbox

/// Global hotkeys via Carbon's `RegisterEventHotKey` — which, unlike an
/// `NSEvent` global monitor, needs **no Accessibility permission** and works
/// system-wide even though this app never activates.
///
/// One handler for the whole app, dispatching on the hotkey's id. That is the
/// point of centralising it: Carbon delivers *every* hotkey press to *every*
/// installed handler, so the previous one-handler-per-hotkey shape worked only
/// while exactly one hotkey existed — a second one would have fired the first
/// one's action too, because nothing inspected the id.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    /// Stable ids, so a re-registration replaces its own hotkey rather than
    /// stacking a second one on the same action.
    enum Action: UInt32 {
        case quickCapture = 1
        case spectrumFullscreen = 2
        case notchToggle = 3

        /// Each action's default combination, so the Carbon key codes stay in
        /// this file and call sites read as intent (`register(.spectrumFullscreen)`).
        var defaultCombo: (keyCode: UInt32, modifiers: UInt32) {
            switch self {
            case .quickCapture:
                return (UInt32(kVK_Space), UInt32(cmdKey | optionKey))          // ⌥⌘Space
            case .spectrumFullscreen:
                return (UInt32(kVK_ANSI_S), UInt32(cmdKey | optionKey))         // ⌥⌘S
            case .notchToggle:
                return (UInt32(kVK_ANSI_N), UInt32(cmdKey | optionKey))         // ⌥⌘N
            }
        }
    }

    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?
    private let signature: OSType = 0x4E4D4361 // 'NMCa'

    private init() {}

    /// Registers `action` on its default combination.
    func register(_ action: Action, onTrigger: @escaping () -> Void) {
        let combo = action.defaultCombo
        register(action, keyCode: combo.keyCode, modifiers: combo.modifiers, onTrigger: onTrigger)
    }

    /// Registers (or re-registers) `action`'s hotkey. `onTrigger` runs on the
    /// main thread.
    func register(_ action: Action, keyCode: UInt32, modifiers: UInt32, onTrigger: @escaping () -> Void) {
        installHandlerIfNeeded()
        unregister(action)
        actions[action.rawValue] = onTrigger
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: signature, id: action.rawValue)
        guard RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr,
              let ref else { return }
        refs[action.rawValue] = ref
    }

    func unregister(_ action: Action) {
        if let ref = refs.removeValue(forKey: action.rawValue) {
            UnregisterEventHotKey(ref)
        }
        actions.removeValue(forKey: action.rawValue)
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData, let event else { return noErr }
            var pressed = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                          EventParamType(typeEventHotKeyID), nil,
                                          MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard status == noErr else { return noErr }
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            center.actions[pressed.id]?()
            return noErr
        }, 1, &eventType, selfPtr, &handlerRef)
    }
}
