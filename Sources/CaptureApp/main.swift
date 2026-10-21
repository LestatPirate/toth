// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit

// Preferências de nomes/formas de execução anteriores (Capture, Toth sem .app) -> atual, antes de qualquer leitura.
LegacyDefaults.migrateAll()

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    AppLogo.installAsApplicationIcon()
    app.setActivationPolicy(.regular)    // app normal: ícone no Dock sempre que estiver a correr
    app.run()
}
