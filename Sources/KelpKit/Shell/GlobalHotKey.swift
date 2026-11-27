import AppKit
import Carbon.HIToolbox

/// ⌃⌥⌘ and `key` from any app, calling `action`: a Carbon hot key, so no Accessibility permission is needed. Kelp's hot
/// keys (⌃⌥⌘K, ⌃⌥⌘T) all come to the one application target, so each takes only its own `signature`.
@MainActor
package final class GlobalHotKey {
    nonisolated let signature: OSType
    private let key: Int, action: @MainActor () -> Void
    private var hotKey: EventHotKeyRef?, handler: EventHandlerRef?

    package init(key: Int, signature: OSType, action: @escaping @MainActor () -> Void) {
        (self.key, self.signature, self.action) = (key, signature, action)
    }

    /// The result is the system's answer: an error when the keys can't be had. The handler is a C function, so it
    /// finds this object through the pointer it's handed: whoever registers keeps the object.
    @discardableResult package func register() -> OSStatus {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, me in
                var id = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard let me else { return OSStatus(eventNotHandledErr) }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(me).takeUnretainedValue()
                guard id.signature == hotKey.signature else { return OSStatus(eventNotHandledErr) }
                DispatchQueue.main.async { MainActor.assumeIsolated { hotKey.action() } }   // the main queue
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let id = EventHotKeyID(signature: signature, id: 1)
        return RegisterEventHotKey(
            UInt32(key), UInt32(controlKey | optionKey | cmdKey), id, GetApplicationEventTarget(), 0, &hotKey)
    }

    /// Gives the keys back, for a test that took them.
    func unregister() {
        hotKey.map { _ = UnregisterEventHotKey($0) }
        handler.map { _ = RemoveEventHandler($0) }
    }
}
