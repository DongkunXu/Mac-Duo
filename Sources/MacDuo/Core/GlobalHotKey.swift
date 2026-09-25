import Carbon.HIToolbox

enum HotKeyError: Error, CustomStringConvertible {
    case handlerInstallation(OSStatus)
    case registration(OSStatus)

    var description: String {
        switch self {
        case .handlerInstallation(let status): String(localized: "could not install the shortcut handler (\(status))")
        case .registration(let status): String(localized: "could not register the shortcut (\(status)); another app may already use it")
        }
    }
}

/// A system-wide shortcut via Carbon `RegisterEventHotKey`, which needs no Accessibility permission
/// and only receives this one key combination.
@MainActor
final class GlobalHotKey {
    private static let signature: OSType = 0x4D_44_75_6F // "MDuo"
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let identifier: UInt32
    fileprivate let action: @MainActor () -> Void

    static let pauseKeyCode = UInt32(kVK_ANSI_D)
    static let pauseModifiers = UInt32(controlKey | optionKey | cmdKey)
    static let pauseDescription = "⌃⌥⌘D"

    init(keyCode: UInt32, modifiers: UInt32, identifier: UInt32 = 1, action: @escaping @MainActor () -> Void) throws(HotKeyError) {
        self.identifier = identifier
        self.action = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            // Carbon dispatches hot-key events on the main thread.
            return MainActor.assumeIsolated {
                let owner = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                guard hotKeyID.signature == GlobalHotKey.signature, hotKeyID.id == owner.identifier else {
                    return OSStatus(eventNotHandledErr)
                }
                owner.action()
                return noErr
            }
        }, 1, &eventType, context, &handlerRef)
        guard installStatus == noErr else { throw .handlerInstallation(installStatus) }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: identifier)
        let registerStatus = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registerStatus == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            handlerRef = nil
            throw .registration(registerStatus)
        }
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }

    isolated deinit {
        unregister()
    }
}
