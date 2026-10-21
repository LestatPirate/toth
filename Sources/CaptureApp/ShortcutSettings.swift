// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit
import CaptureCore

/// Atalho global de captura: guarda-se nas preferências (UserDefaults) e regista-se no sistema.
@MainActor
final class ShortcutSettings: ObservableObject {
    static let shared = ShortcutSettings()
    private static let key = "captureShortcut"

    @Published private(set) var shortcut: Shortcut
    @Published private(set) var recording = false
    @Published var message: String?

    /// Regista o atalho no sistema; devolve `false` se não foi possível (ex.: já em uso por outra app).
    var register: ((Shortcut) -> Bool)?
    /// Desliga/liga o atalho durante a gravação (para carregar na combinação atual não disparar uma captura).
    var suspend: ((Bool) -> Void)?
    private var monitor: Any?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key), let s = try? JSONDecoder().decode(Shortcut.self, from: data), s.problem == nil {
            shortcut = s
        } else {
            shortcut = .default
        }
    }

    // MARK: Gravar uma combinação nova

    func startRecording() {
        guard !recording else { return }
        message = nil
        recording = true
        suspend?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return nil   // engole a tecla: não escreve nem aciona atalhos enquanto se grava
        }
    }

    func stopRecording() {
        guard recording else { return }
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recording = false
        suspend?(false)
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 { stopRecording(); return }   // Esc cancela
        var mods: Shortcut.Modifiers = []
        let f = event.modifierFlags
        if f.contains(.command) { mods.insert(.command) }
        if f.contains(.option) { mods.insert(.option) }
        if f.contains(.control) { mods.insert(.control) }
        if f.contains(.shift) { mods.insert(.shift) }
        let label = Shortcut.specialLabel(forKeyCode: UInt32(event.keyCode))
            ?? (event.charactersIgnoringModifiers ?? "").uppercased()
        guard !label.isEmpty else { message = L("Esta tecla não pode ser usada."); return }
        let candidate = Shortcut(keyCode: UInt32(event.keyCode), modifiers: mods, keyLabel: label)
        if apply(candidate) { stopRecording() }   // se falhar, continua a gravar para tentar outra
    }

    // MARK: Aplicar

    /// Valida, regista no sistema e só então guarda. Em caso de erro, o atalho anterior continua válido.
    @discardableResult
    func apply(_ s: Shortcut) -> Bool {
        switch s.problem {
        case .needsModifier?:
            message = L("Use também ⌘, ⌃ ou ⌥ (ou uma tecla de função, como F5)."); return false
        case let .reservedBySystem(name)?:
            message = L("%@ é usado pelo macOS. Escolha outra combinação.", name.replacingOccurrences(of: "Espaço", with: L("Espaço"))); return false
        case nil: break
        }
        if s == shortcut, register?(s) ?? true { message = nil; return true }
        guard register?(s) ?? true else {
            _ = register?(shortcut)   // repõe o anterior
            if recording { suspend?(true) }   // continua a gravar: o atalho antigo fica desligado até acabar
            message = L("%@ já está em uso (por outra app ou pelo sistema). Escolha outra combinação.", s.shown)
            return false
        }
        shortcut = s
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: Self.key) }
        message = nil
        return true
    }

    func resetToDefault() {
        stopRecording()
        apply(.default)
    }
}

extension Shortcut {
    var nsModifiers: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { f.insert(.command) }
        if modifiers.contains(.option) { f.insert(.option) }
        if modifiers.contains(.control) { f.insert(.control) }
        if modifiers.contains(.shift) { f.insert(.shift) }
        return f
    }
}
