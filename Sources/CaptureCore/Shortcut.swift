// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import Foundation

/// Combinação de teclas para um atalho global (sem depender de AppKit/Carbon, para se poder testar).
public struct Shortcut: Codable, Equatable, Sendable {
    public struct Modifiers: OptionSet, Codable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let control = Modifiers(rawValue: 4)
        public static let shift = Modifiers(rawValue: 8)
    }

    /// Código físico da tecla (o mesmo do macOS, `kVK_*`).
    public var keyCode: UInt32
    public var modifiers: Modifiers
    /// Texto da tecla para mostrar ("4", "C", "F5", "Espaço"…).
    public var keyLabel: String

    public init(keyCode: UInt32, modifiers: Modifiers, keyLabel: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.keyLabel = keyLabel
    }

    /// ⌃⇧4
    public static let `default` = Shortcut(keyCode: 21, modifiers: [.control, .shift], keyLabel: "4")

    /// Como se escreve no macOS: ⌃⌥⇧⌘ + tecla.
    public var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + keyLabel
    }

    public enum Problem: Equatable, Sendable {
        /// Sem ⌘, ⌃ ou ⌥ (e não é uma tecla de função): escrever normalmente dispararia o atalho.
        case needsModifier
        /// Combinação que o sistema já usa (capturas de ecrã do macOS, trocar de app, etc.).
        case reservedBySystem(String)
    }

    private var isFunctionKey: Bool { keyLabel.count <= 3 && keyLabel.hasPrefix("F") && Int(keyLabel.dropFirst()) != nil }

    /// Combinações do sistema que não vale a pena aceitar (o macOS tem prioridade e o atalho nunca dispararia).
    private static let reserved: [(code: UInt32, mods: Modifiers, name: String)] = [
        (20, [.command, .shift], "⇧⌘3"), (21, [.command, .shift], "⇧⌘4"), (23, [.command, .shift], "⇧⌘5"), (22, [.command, .shift], "⇧⌘6"),
        (49, [.command], "⌘Espaço"), (48, [.command], "⌘Tab"), (12, [.command], "⌘Q"), (13, [.command], "⌘W"),
        (4, [.command], "⌘H"), (46, [.command], "⌘M"),
    ]

    public var problem: Problem? {
        if !isFunctionKey && modifiers.intersection([.command, .option, .control]).isEmpty { return .needsModifier }
        if let r = Shortcut.reserved.first(where: { $0.code == keyCode && $0.mods == modifiers }) { return .reservedBySystem(r.name) }
        return nil
    }

    /// Texto da tecla a partir do código, para teclas que não têm um carácter próprio.
    public static func specialLabel(forKeyCode code: UInt32) -> String? {
        let table: [UInt32: String] = [
            49: "Espaço", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        return table[code]
    }
}
