// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import SwiftUI
import AppKit
import CaptureCore

struct SettingsView: View {
    @ObservedObject var settings: ShortcutSettings
    @ObservedObject var localizer: Localizer = .shared
    @ObservedObject var updater: Updater = .shared

    private var language: Binding<AppLanguage> { Binding(get: { localizer.language }, set: { localizer.set($0) }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                LogoView(size: 44)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Toth").font(.title2.weight(.bold))
                    Text(L("Preferências")).font(.callout).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L("Atalho de captura")).font(.headline)
                Text(L("Congela o ecrã no instante do atalho e só captura a área depois de a confirmar."))
                    .font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button {
                        if settings.recording { settings.stopRecording() } else { settings.startRecording() }
                    } label: {
                        Text(settings.recording ? L("Carregue na nova combinação…") : settings.shortcut.shown)
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .frame(minWidth: 220, minHeight: 28)
                    }
                    .buttonStyle(.bordered)
                    .tint(settings.recording ? .accentColor : nil)
                    .help(L("Clique e carregue na combinação que quer usar (Esc cancela)"))

                    Button(L("Repor padrão (%@)", Shortcut.default.shown)) { settings.resetToDefault() }
                        .disabled(settings.shortcut == .default && !settings.recording)
                }
                if let m = settings.message {
                    Label(m, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                } else {
                    Text(L("Use ⌘, ⌃ ou ⌥ (ou uma tecla de função). Evite combinações que o macOS já usa, como ⇧⌘3, ⇧⌘4 ou ⇧⌘5."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L("Idioma")).font(.headline)
                Picker("", selection: language) {
                    Text(L("Automático (sistema)")).tag(AppLanguage.system)
                    Text("Português").tag(AppLanguage.pt)
                    Text("English").tag(AppLanguage.en)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 380)
                Text(L("O idioma muda já. Os diálogos do sistema (como o de abrir ficheiros) seguem o idioma do macOS."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Atualizações")).font(.headline)
                Toggle(L("Procurar atualizações automaticamente"), isOn: $updater.automatic)
                HStack(spacing: 10) {
                    Button(L("Procurar agora")) { updater.checkNow() }
                    Text(L("Versão %@", updater.currentVersionText)).font(.callout).foregroundStyle(.secondary)
                }
                Text(L("Pergunta ao GitHub, no máximo uma vez por dia, se há uma versão nova (sem enviar dados pessoais). Só atualiza se você confirmar."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(L("© 2026 Alex Felizardo. Software livre, licença MIT."))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(width: 520, height: 520, alignment: .topLeading)
    }
}

@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 520), styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = L("Preferências")
            w.contentView = NSHostingView(rootView: SettingsView(settings: .shared))
            w.isReleasedWhenClosed = false
            w.center()
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated { ShortcutSettings.shared.stopRecording() }   // fechar a janela cancela a gravação
            }
            window = w
        }
        window?.title = L("Preferências")
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Atualiza o título quando o idioma muda.
    static func refreshTitle() { window?.title = L("Preferências") }
}
