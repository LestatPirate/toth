// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit
import SwiftUI

/// Guia de 3 passos para dar ao Toth a permissão de Gravação de Ecrã (a única de que precisa):
/// 1. «Conceder permissão» (o macOS abre as Definições); 2. ativar o Toth na lista; 3. reiniciar o Toth
/// (o macOS só aplica a permissão quando a app volta a abrir).
///
/// O modelo não toca no sistema diretamente: as ações entram por closures, por isso os passos testam-se sem o ecrã.
@MainActor
final class PermissionsGuide: ObservableObject {
    enum Step: Equatable { case request, restart, done }

    @Published private(set) var step = Step.request
    let firstRun: Bool

    // Ações (por omissão, as reais)
    var isGranted: () -> Bool = { Permissions.preflight() }
    var requestAccess: () -> Void = { Permissions.requestAccess() }
    var restart: () -> Void = { Permissions.relaunch() }
    var resetEntry: () -> Void = { Permissions.reset() }
    var onClose: () -> Void = {}

    private var timer: Timer?

    init(firstRun: Bool) { self.firstRun = firstRun }

    /// Passo 1: pede a permissão ao sistema (abre também as Definições) e passa a esperar que o utilizador a ative.
    func grant() {
        requestAccess()
        if isGranted() { step = .done } else { step = .restart }
    }

    /// Passo 3 (ou a pedido, se a permissão ficou presa a uma versão anterior): apaga a entrada e pede de novo.
    func resetAndAsk() {
        resetEntry()
        requestAccess()
        step = .restart
    }

    func restartApp() { restart() }

    func finish() { stopPolling(); onClose() }

    /// Enquanto o guia está aberto, vê de segundo a segundo se a permissão já passou a valer.
    func startPolling() {
        stopPolling()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stopPolling() { timer?.invalidate(); timer = nil }

    func poll() { if step != .done, isGranted() { step = .done } }
}

struct PermissionsGuideView: View {
    @ObservedObject var guide: PermissionsGuide

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                LogoView(size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(guide.step == .done ? L("Tudo pronto!") : (guide.firstRun ? L("Bem-vindo ao Toth") : L("O Toth precisa de uma permissão")))
                        .font(.title2.weight(.bold))
                    Text(L("Para capturar o ecrã, o macOS exige a sua autorização. O Toth só captura quando você pede, e nada sai do seu computador."))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                stepRow(1, title: L("Autorizar"),
                        detail: L("Clique em «Conceder permissão». O macOS abre as Definições do Sistema."),
                        done: guide.step != .request, active: guide.step == .request)
                stepRow(2, title: L("Ativar o Toth na lista"),
                        detail: L("Em «Gravação de Ecrã e Áudio do Sistema», ative o interruptor junto a «Toth»."),
                        done: guide.step == .done, active: guide.step == .restart)
                stepRow(3, title: L("Reiniciar o Toth"),
                        detail: L("O macOS só aplica a permissão quando a app volta a abrir. Se perguntar, escolha «Sair e reabrir»."),
                        done: guide.step == .done, active: guide.step == .restart)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))

            HStack(spacing: 10) {
                switch guide.step {
                case .request:
                    Button(L("Conceder permissão")) { guide.grant() }
                        .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                    Button(L("Agora não")) { guide.finish() }.controlSize(.large)
                case .restart:
                    Button(L("Reiniciar o Toth")) { guide.restartApp() }
                        .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                    Button(L("Abrir as Definições outra vez")) { guide.grant() }.controlSize(.large)
                    Button(L("Agora não")) { guide.finish() }.controlSize(.large)
                case .done:
                    Button(L("Começar")) { guide.finish() }
                        .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                }
                Spacer()
            }

            if guide.step == .restart {
                HStack(alignment: .top, spacing: 6) {
                    Text(L("Já ativou e continua a falhar? A permissão pode ter ficado ligada a uma versão anterior da app."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button(L("Repor a permissão")) { guide.resetAndAsk() }.controlSize(.small)
                }
            } else {
                Text(L("O Toth não precisa de mais nenhuma permissão (nem Acessibilidade, nem microfone) e não usa a internet, a não ser para procurar atualizações."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(width: 540, alignment: .topLeading)
    }

    private func stepRow(_ n: Int, title: String, detail: String, done: Bool, active: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : (active ? Color.accentColor : Color.secondary.opacity(0.25))).frame(width: 24, height: 24)
                if done { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white) }
                else { Text("\(n)").font(.system(size: 12, weight: .bold)).foregroundStyle(active ? .white : .secondary) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(active || done ? .primary : .secondary)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

@MainActor
enum PermissionsGuideWindow {
    private static var window: NSWindow?
    private static var guide: PermissionsGuide?

    static var isVisible: Bool { window?.isVisible ?? false }

    /// Mostra o guia (se já está aberto, só o traz para a frente).
    static func show(firstRun: Bool = false) {
        if let w = window, w.isVisible { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let g = PermissionsGuide(firstRun: firstRun)
        g.onClose = { close() }
        let host = NSHostingController(rootView: PermissionsGuideView(guide: g))
        let w = NSWindow(contentViewController: host)
        w.title = "Toth"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        window = w; guide = g
        g.startPolling()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func close() {
        guide?.stopPolling()
        window?.orderOut(nil)
        window = nil; guide = nil
    }
}
