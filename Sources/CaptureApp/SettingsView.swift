// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import SwiftUI
import AppKit
import CaptureCore

struct SettingsView: View {
    @ObservedObject var settings: ShortcutSettings
    @ObservedObject var localizer: Localizer = .shared
    @ObservedObject var updater: Updater = .shared
    /// (Sem @State: refaz o seletor do microfone quando a escolha muda.)
    @StateObject private var micState = MicState()
    private final class MicState: ObservableObject { @Published var tick = 0 }

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
                Text(L("Microfone")).font(.headline)
                Picker("", selection: Binding(get: { MicrophoneChoice.selectedID ?? "" }, set: { MicrophoneChoice.selectedID = $0.isEmpty ? nil : $0; micState.tick += 1 })) {
                    Text(L("Predefinido do sistema")).tag("")
                    ForEach(MicrophoneChoice.available(), id: \.id) { m in Text(m.name).tag(m.id) }
                }
                .labelsHidden().frame(width: 320).id(micState.tick)
                Text(L("Usado ao gravar vídeo com o microfone ligado e na narração do editor de vídeo."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Pasta das capturas")).font(.headline)
                HStack(spacing: 10) {
                    Text(CaptureStore.shortPath(CaptureStore.folder)).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 300, alignment: .leading).id(micState.tick)
                    Button(L("Alterar…")) { chooseFolder() }
                    Button(L("Repor padrão")) { confirmMove(to: CaptureStore.defaultFolder) }.disabled(CaptureStore.customFolder == nil)
                }
                Text(L("Capturas, vídeos, edições e carimbos importados ficam aqui (subpasta «Carimbos»). Ao alterar, tudo é movido para a nova pasta."))
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
        .frame(width: 520, height: 700, alignment: .topLeading)
    }

    /// Escolhe a nova pasta e, depois de confirmar, move tudo para lá.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = CaptureStore.folder.deletingLastPathComponent()
        panel.prompt = L("Escolher")
        panel.message = L("Escolha a pasta onde o Toth guarda as capturas, vídeos e carimbos")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        confirmMove(to: url)
    }

    private func confirmMove(to url: URL) {
        let dest = url.standardizedFileURL
        guard dest != CaptureStore.folder.standardizedFileURL else { return }
        let n = CaptureStore.ownedItems(in: CaptureStore.folder).count
        let alert = NSAlert()
        alert.messageText = L("Mover as capturas para %@?", CaptureStore.shortPath(dest))
        alert.informativeText = n == 0 ? L("A pasta atual não tem capturas. A partir de agora as novas ficam na pasta escolhida.")
            : L("%d itens (capturas, vídeos, edições e carimbos) vão ser movidos de %@ para a nova pasta. Nada é apagado antes de estar no destino.", n, CaptureStore.shortPath(CaptureStore.folder))
        alert.addButton(withTitle: L("Mover"))
        alert.addButton(withTitle: L("Cancelar"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        AppState.shared.changeCaptureFolder(to: dest)
        micState.tick += 1   // refaz o caminho mostrado
    }
}

@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 700), styleMask: [.titled, .closable],
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
