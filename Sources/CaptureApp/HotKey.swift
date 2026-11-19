// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import Carbon.HIToolbox
import AppKit

/// Atalho global via Carbon (não exige permissões especiais).
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void
    /// Cada atalho tem o seu número: com mais de um registado (o da captura e o Esc do seletor), cada um só responde ao seu.
    let number: UInt32
    private static var lastNumber: UInt32 = 0

    init?(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, action: @escaping () -> Void) {
        self.action = action
        Self.lastNumber += 1
        number = Self.lastNumber
        var carbonMods: UInt32 = 0
        if modifiers.contains(.command) { carbonMods |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { carbonMods |= UInt32(shiftKey) }
        if modifiers.contains(.option) { carbonMods |= UInt32(optionKey) }
        if modifiers.contains(.control) { carbonMods |= UInt32(controlKey) }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            let me = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            var pressed = EventHotKeyID()
            let got = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard got == noErr, pressed.id == me.number else { return OSStatus(eventNotHandledErr) }   // é de outro atalho
            me.action()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        guard status == noErr else { return nil }

        let id = EventHotKeyID(signature: OSType(0x43415054), id: number)  // 'CAPT'
        guard RegisterEventHotKey(keyCode, carbonMods, id, GetApplicationEventTarget(), 0, &ref) == noErr else { return nil }
    }

    /// Para testes: entrega à app o evento deste atalho, como se o sistema o tivesse detetado.
    func debugFire() {
        var id = EventHotKeyID(signature: OSType(0x43415054), id: number)
        var event: EventRef?
        CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, EventAttributes(kEventAttributeNone), &event)
        guard let event else { return }
        SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &id)
        SendEventToEventTarget(event, GetApplicationEventTarget())
        ReleaseEvent(event)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
