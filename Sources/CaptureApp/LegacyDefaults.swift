// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import Foundation

/// Sem pacote `.app`, o macOS guarda as preferências com o nome do executável ("Capture", depois "Toth"); com o `.app`
/// passa a usar o identificador do pacote. Copiam-se (uma só vez por origem) o atalho, o idioma e as personalizações
/// das ferramentas, para não se perderem. Nunca sobrescreve o que já existe no destino.
enum LegacyDefaults {
    static let keys = ["captureShortcut", "appLanguage", "toolDefaults.v1"]
    static let oldDomains = ["Toth", "Capture"]   // do mais recente para o mais antigo

    static func migrateAll(into defaults: UserDefaults = .standard) {
        for domain in oldDomains { migrate(from: domain, into: defaults) }
    }

    static func migrate(from oldDomain: String, into defaults: UserDefaults = .standard) {
        let flag = "migratedFrom.\(oldDomain)"
        guard !defaults.bool(forKey: flag), let old = UserDefaults(suiteName: oldDomain) else { return }
        for key in keys where defaults.object(forKey: key) == nil {
            if let value = old.object(forKey: key) { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: flag)
    }
}
