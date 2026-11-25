import Carbon

@MainActor
final class GlobalShortcut {
    private var token: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    func setEnabled(_ enabled: Bool) {
        if !enabled {
            if let token { UnregisterEventHotKey(token) }
            if let handler { RemoveEventHandler(handler) }
            self.token = nil
            self.handler = nil
            return
        }
        guard self.token == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        if self.handler == nil {
            let callback: EventHandlerUPP = { _, _, context in
                guard let context else { return OSStatus(eventNotHandledErr) }
                MainActor.assumeIsolated {
                    Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue().action()
                }
                return noErr
            }
            InstallEventHandler(
                GetApplicationEventTarget(),
                callback,
                1,
                &type,
                Unmanaged.passUnretained(self).toOpaque(),
                &self.handler)
        }
        let id = EventHotKeyID(signature: 0x544C_4544, id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_L),
            UInt32(controlKey | optionKey | cmdKey),
            id,
            GetApplicationEventTarget(),
            0,
            &self.token)
    }
}
