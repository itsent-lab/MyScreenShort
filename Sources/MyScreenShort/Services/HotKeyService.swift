import Carbon
import Foundation

final class HotKeyService {
    private var eventHotKeyRefs: [EventHotKeyRef] = []
    private var eventHandlerRef: EventHandlerRef?
    private let onPressed: () -> Void

    init(onPressed: @escaping () -> Void) {
        self.onPressed = onPressed
    }

    deinit {
        unregister()
    }

    func registerCaptureHotKeys() throws {
        unregister()

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { _, _, userData in
            guard let userData else {
                return noErr
            }

            let service = Unmanaged<HotKeyService>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                service.onPressed()
            }
            return noErr
        }

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )

        guard installStatus == noErr else {
            throw HotKeyError.handlerInstallFailed(installStatus)
        }

        try registerHotKey(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey | shiftKey), id: 1)
        try registerHotKey(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey | shiftKey), id: 2)
    }

    func unregister() {
        for eventHotKeyRef in eventHotKeyRefs {
            UnregisterEventHotKey(eventHotKeyRef)
        }
        eventHotKeyRefs.removeAll()

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    private func registerHotKey(keyCode: UInt32, modifiers: UInt32, id: UInt32) throws {
        var eventHotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: fourCharCode("MSSM"), id: id)
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &eventHotKeyRef
        )

        guard registerStatus == noErr,
              let eventHotKeyRef else {
            throw HotKeyError.registrationFailed(registerStatus)
        }

        eventHotKeyRefs.append(eventHotKeyRef)
    }

    private func fourCharCode(_ text: String) -> OSType {
        var result: OSType = 0
        for scalar in text.unicodeScalars.prefix(4) {
            result = (result << 8) + OSType(scalar.value)
        }
        return result
    }
}

enum HotKeyError: Error {
    case handlerInstallFailed(OSStatus)
    case registrationFailed(OSStatus)
}
