// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Permissão de gravação de ecrã do macOS.
///
/// Dois detalhes do macOS explicam a maior parte dos "autorizei e continua a pedir":
/// 1. a permissão só passa a valer para a app **quando ela volta a abrir** (`CGPreflightScreenCaptureAccess` continua a
///    dizer "não" no processo que já estava a correr), por isso se oferece "Reiniciar";
/// 2. numa app com assinatura *ad hoc*, cada versão nova tem outra "identidade": a entrada que ficou ativada nas Definições
///    pode ser da versão anterior. Por isso se oferece "Repor a permissão" (apaga a entrada e pede-a de novo).
enum Permissions {
    /// `true` se se pode capturar. Se não, mostra o guia de permissões e devolve `false`.
    @MainActor static func ensure() async -> Bool {
        if await isGranted() { return true }
        presentHelp()
        return false
    }

    /// Estado real: o `CGPreflight…` é rápido mas pode estar desatualizado; o ScreenCaptureKit diz a verdade.
    static func isGranted() async -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        do { _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true); return true }
        catch { return false }
    }

    /// Consulta rápida, sem mostrar nada ao utilizador (usada ao abrir a app e pelo guia).
    static func preflight() -> Bool { CGPreflightScreenCaptureAccess() }

    private static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    /// Só existe "Reiniciar" e "Repor" dentro de um `.app` (um executável solto não tem identificador próprio).
    private static var bundleID: String? { Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleIdentifier : nil }

    /// Ao abrir a app: se falta a permissão, mostra logo o guia (3 passos). Na primeira execução com as boas-vindas.
    @MainActor static func checkAtLaunch() {
        let key = "didShowWelcome"
        let first = !UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        if !preflight() { PermissionsGuideWindow.show(firstRun: first) }
    }

    @MainActor static func presentHelp() { PermissionsGuideWindow.show(firstRun: false) }

    /// Pede a permissão ao macOS (que mostra o seu aviso, com «Abrir Definições do Sistema») e abre já a lista.
    @MainActor static func requestAccess() {
        CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(settingsURL)
    }

    /// Apaga a entrada desta app (fica ligada à versão anterior quando a assinatura muda). Depois pede-se de novo.
    @MainActor static func reset() {
        guard let id = bundleID else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "ScreenCapture", id]
        try? p.run(); p.waitUntilExit()
    }

    /// Volta a abrir a app (já com a permissão) e fecha esta instância.
    @MainActor static func relaunch() {
        let path = Bundle.main.bundleURL.path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }
}
