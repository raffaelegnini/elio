import AppKit
import Carbon.HIToolbox

/// Global hotkey via Carbon RegisterEventHotKey: works in any app, needs no Accessibility permission.
@MainActor
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private static var instances: [UInt32: HotKey] = [:]
    private static var nextId: UInt32 = 1

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, action: @escaping () -> Void) {
        self.action = action
        let id = Self.nextId
        Self.nextId += 1
        Self.instances[id] = self

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            Task { @MainActor in HotKey.instances[id]?.action() }
            return noErr
        }, 1, &spec, nil, &handler)

        let hotKeyId = EventHotKeyID(signature: OSType(0x4A525653) /* JRVS */, id: id)
        RegisterEventHotKey(keyCode, Self.carbonFlags(modifiers), hotKeyId, GetApplicationEventTarget(), 0, &ref)
    }

    private static func carbonFlags(_ m: NSEvent.ModifierFlags) -> UInt32 {
        var flags: UInt32 = 0
        if m.contains(.command) { flags |= UInt32(cmdKey) }
        if m.contains(.option) { flags |= UInt32(optionKey) }
        if m.contains(.control) { flags |= UInt32(controlKey) }
        if m.contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }
}
