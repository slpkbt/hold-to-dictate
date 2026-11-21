import ApplicationServices
import Carbon

@MainActor
final class Hotkey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var releaseTimer: Timer?
    private var isDown = false
    private let shortcut: Shortcut
    private let changed: (Bool) -> Void

    init(_ shortcut: Shortcut, changed: @escaping (Bool) -> Void) throws {
        self.shortcut = shortcut
        self.changed = changed

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let status = InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr, id.signature == 0x48444943 else { return OSStatus(eventNotHandledErr) }
            let hotkey = Unmanaged<Hotkey>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                hotkey.handle(pressed: GetEventKind(event) == UInt32(kEventHotKeyPressed))
            }
            return noErr
        }, eventTypes.count, &eventTypes, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { throw DictationError("Не удалось настроить глобальный хоткей.") }
        let registration = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers,
                                               EventHotKeyID(signature: 0x48444943, id: 1),
                                               GetEventDispatcherTarget(), 0, &reference)
        guard registration == noErr else {
            invalidate()
            throw DictationError("Сочетание занято: смените shortcut в настройках.")
        }
    }

    func invalidate() {
        releaseTimer?.invalidate()
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        reference = nil
        handler = nil
        isDown = false
    }

    private func handle(pressed: Bool) {
        guard pressed != isDown else { return }
        isDown = pressed
        if pressed {
            let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let flags = CGEventSource.flagsState(.combinedSessionState)
                    if !flags.contains(self.shortcut.flags) { self.handle(pressed: false) }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            releaseTimer = timer
        } else {
            releaseTimer?.invalidate()
            releaseTimer = nil
        }
        changed(pressed)
    }
}
