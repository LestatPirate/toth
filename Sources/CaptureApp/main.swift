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

// `--permission-check <ficheiro>`: escreve se a app tem a permissão de gravação de ecrã e se o pacote tem ícone
// personalizado (diagnóstico: correr com `open -n Toth.app --args …`, para a permissão ser avaliada à própria app).
if let i = CommandLine.arguments.firstIndex(of: "--permission-check"), CommandLine.arguments.count > i + 1 {
    let line = "screen=\(CGPreflightScreenCaptureAccess()) customIcon=\(MainActor.assumeIsolated { AppIcon.bundleHasCustomIcon })\n"
    try? line.write(toFile: CommandLine.arguments[i + 1], atomically: true, encoding: .utf8)
    exit(0)
}

// `--uninstall-selftest <pasta>` e `--crash-selftest <pasta>`: em pastas de faz de conta (nunca tocam no sistema).
if let i = CommandLine.arguments.firstIndex(of: "--uninstall-selftest"), CommandLine.arguments.count > i + 1 {
    let fails = Uninstaller.selfTest(dir: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    print(fails.isEmpty ? "UNINSTALL-SELFTEST: OK" : "UNINSTALL-SELFTEST: FALHOU — " + fails.joined(separator: "; ")); exit(fails.isEmpty ? 0 : 1)
}
if let i = CommandLine.arguments.firstIndex(of: "--crash-selftest"), CommandLine.arguments.count > i + 1 {
    let fails = CrashReports.selfTest(dir: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    print(fails.isEmpty ? "CRASH-SELFTEST: OK" : "CRASH-SELFTEST: FALHOU — " + fails.joined(separator: "; ")); exit(fails.isEmpty ? 0 : 1)
}

// Diagnóstico das falhas: `--crash-test` falha de propósito (para o macOS escrever um relatório verdadeiro);
// `--crash-list` mostra o que o Toth lê dos relatórios que o macOS tem desta app.
if CommandLine.arguments.contains("--crash-test") { fatalError("Falha de teste pedida com --crash-test") }
if CommandLine.arguments.contains("--crash-list") {
    let all = CrashReports.reports(in: CrashReports.folder, bundleID: Uninstaller.bundleID)
    print("CRASH-LIST: \(all.count) relatório(s)")
    for r in all.prefix(3) { print("  \(r.url.lastPathComponent) · \(r.version) (\(r.build)) · \(r.exception) · \(r.frames.prefix(4))") }
    exit(0)
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
