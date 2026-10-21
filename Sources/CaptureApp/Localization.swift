// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import Foundation
import SwiftUI
import CaptureCore

/// Idioma da interface: automático (segue o sistema), português ou inglês. Guarda-se nas preferências.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, pt, en
    var id: String { rawValue }
}

/// Texto traduzido. As chaves são os textos em português; se não houver tradução, mostra-se o próprio texto.
@MainActor
final class Localizer: ObservableObject {
    static let shared = Localizer()
    private static let key = "appLanguage"

    /// Idioma efetivo (`"pt"` ou `"en"`), lido por `L()` de qualquer sítio.
    nonisolated(unsafe) static var effective = "pt"

    @Published private(set) var language: AppLanguage

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.key).flatMap(AppLanguage.init(rawValue:)) ?? .system
        language = stored
        Self.effective = Self.resolve(stored)
    }

    /// "Automático": inglês, salvo se o sistema estiver em português (o idioma em que a app foi feita).
    static func resolve(_ l: AppLanguage) -> String {
        switch l {
        case .pt: return "pt"
        case .en: return "en"
        case .system: return (Locale.preferredLanguages.first ?? "en").hasPrefix("pt") ? "pt" : "en"
        }
    }

    func set(_ l: AppLanguage) {
        guard l != language else { return }
        UserDefaults.standard.set(l.rawValue, forKey: Self.key)
        Self.effective = Self.resolve(l)
        language = l
    }

    var isEnglish: Bool { Self.effective == "en" }
    var locale: Locale { Locale(identifier: Self.effective == "en" ? "en_US" : "pt_PT") }
}

/// Traduz `key` (texto em português) e, se houver argumentos, formata-o (`%@`, `%d`).
func L(_ key: String, _ args: CVarArg...) -> String {
    let text = Localizer.effective == "en" ? (Translations.en[key] ?? key) : key
    return args.isEmpty ? text : String(format: text, arguments: args)
}

extension Shortcut {
    /// Como `display`, com o nome da tecla Espaço no idioma atual.
    var shown: String { display.replacingOccurrences(of: "Espaço", with: L("Espaço")) }
}
