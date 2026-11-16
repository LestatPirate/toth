// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit

// Preferências de nomes/formas de execução anteriores (Capture, Toth sem .app) -> atual, antes de qualquer leitura.
LegacyDefaults.migrateAll()

// `--normalize-icon <entrada> <saída.png> [lado]`: prepara um ícone na grelha do macOS (sem abrir a app).
if let i = CommandLine.arguments.firstIndex(of: "--normalize-icon"), CommandLine.arguments.count > i + 2 {
    let side = CommandLine.arguments.count > i + 3 ? Int(CommandLine.arguments[i + 3]) ?? 1024 : 1024
    let ok = AppIcon.normalizeFile(URL(fileURLWithPath: CommandLine.arguments[i + 1]), to: URL(fileURLWithPath: CommandLine.arguments[i + 2]), side: side)
    print(ok ? "NORMALIZE-ICON: OK" : "NORMALIZE-ICON: FALHOU"); exit(ok ? 0 : 1)
}

if CommandLine.arguments.contains("--icon-selftest") {
    let fails = MainActor.assumeIsolated { AppIcon.selfTest() }
    print(fails.isEmpty ? "ICON-SELFTEST: OK" : "ICON-SELFTEST: FALHOU — " + fails.joined(separator: "; ")); exit(fails.isEmpty ? 0 : 1)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    AppIcon.shared.apply()   // o ícone escolhido nas Preferências (por omissão, o original)
    app.setActivationPolicy(.regular)    // app normal: ícone no Dock sempre que estiver a correr
    app.run()
}
