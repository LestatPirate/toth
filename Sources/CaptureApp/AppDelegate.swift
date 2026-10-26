// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit
import ScreenCaptureKit
import Combine
import Carbon.HIToolbox
import CaptureCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var captureMenuItem: NSMenuItem?
    private var languageSub: AnyCancellable?
    private let selector = RegionSelector()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        // Argumentos de teste (ver README): `--library <pasta>` usa outra pasta de capturas.
        if let i = args.firstIndex(of: "--library"), args.count > i + 1 { CaptureStore.overrideFolder = URL(fileURLWithPath: args[i + 1]) }
        if let i = args.firstIndex(of: "--make-demo-library"), args.count > i + 1 {
            do { try SelfTests.makeDemoLibrary(URL(fileURLWithPath: args[i + 1])); print("DEMO-LIBRARY: OK"); exit(0) }
            catch { print("DEMO-LIBRARY: erro \(error)"); exit(1) }
        }
        if let i = args.firstIndex(of: "--compact-selftest"), args.count > i + 1 {
            let fails = SelfTests.compactSelfTest(URL(fileURLWithPath: args[i + 1]))
            print(fails.isEmpty ? "COMPACT-SELFTEST: OK" : "COMPACT-SELFTEST: FALHOU — " + fails.joined(separator: "; "))
            exit(fails.isEmpty ? 0 : 1)
        }
        // `--lang pt|en`: idioma só para esta execução (não grava nas preferências).
        if let i = args.firstIndex(of: "--lang"), args.count > i + 1 { _ = Localizer.shared; Localizer.effective = args[i + 1] }
        if let i = args.firstIndex(of: "--language-selftest"), args.count > i + 1 {
            let fails = SelfTests.languageSelfTest(phase: args[i + 1])
            if !fails.isEmpty { print("LANGUAGE-SELFTEST: FALHOU — " + fails.joined(separator: "; ")) }
            exit(fails.isEmpty ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--render-shapes"), args.count > i + 1 { SelfTests.renderShapes(to: args[i + 1]); print("RENDER-SHAPES: OK"); exit(0) }
        if let i = args.firstIndex(of: "--render-steps"), args.count > i + 1 { SelfTests.renderSteps(to: args[i + 1]); print("RENDER-STEPS: OK"); exit(0) }
        if let i = args.firstIndex(of: "--render-newimage"), args.count > i + 1 {
            SelfTests.renderNewImageSheet(to: args[i + 1]); print("RENDER-NEWIMAGE: OK"); exit(0)
        }
        if let i = args.firstIndex(of: "--render-main"), args.count > i + 2 {
            let sel = args.firstIndex(of: "--select").flatMap { args.count > $0 + 1 ? Int(args[$0 + 1]) : nil }
            var size = NSSize(width: 1360, height: 820)
            if let k = args.firstIndex(of: "--size"), args.count > k + 1 {   // --size 720x520
                let p = args[k + 1].split(separator: "x").compactMap { Double($0) }
                if p.count == 2 { size = NSSize(width: p[0], height: p[1]) }
            }
            var clicks: [(Double, Double)] = []
            for (j, a) in args.enumerated() where a == "--click" && args.count > j + 1 {
                let c = args[j + 1].split(separator: ",").compactMap { Double($0) }
                if c.count == 2 { clicks.append((c[0], c[1])) }
            }
            var scrolls: [Double] = []
            if let k = args.firstIndex(of: "--tools-scroll"), args.count > k + 1 { scrolls = args[k + 1].split(separator: ",").compactMap { Double($0) } }
            AppState.shared.showLibraryStrip = !args.contains("--library-hidden")
            SelfTests.renderMain(to: args[i + 1], capture: URL(fileURLWithPath: args[i + 2]), select: sel, size: size, panelHidden: args.contains("--panel-hidden"), clicks: clicks, toolScroll: scrolls)
            print("RENDER-MAIN: OK"); exit(0)
        }
        if let i = args.firstIndex(of: "--defaults-selftest"), args.count > i + 2 {
            let fails = SelfTests.defaultsSelfTest(phase: args[i + 1], dir: URL(fileURLWithPath: args[i + 2]))
            if !fails.isEmpty { print("DEFAULTS-SELFTEST: FALHOU — " + fails.joined(separator: "; ")) }
            exit(fails.isEmpty ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--make-showcase"), args.count > i + 1 {
            do { try SelfTests.makeDemoLibrary(URL(fileURLWithPath: args[i + 1])); let u = try SelfTests.makeShowcase(URL(fileURLWithPath: args[i + 1])); print("SHOWCASE: \(u.path)"); exit(0) }
            catch { print("SHOWCASE: erro \(error)"); exit(1) }
        }
        // Autotestes de interface: correm depois de o editor abrir (ver MainWindow.show mais abaixo).
        func later(_ name: String, _ run: @escaping () -> [String]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                let fails = run()
                print(fails.isEmpty ? "\(name): OK" : "\(name): FALHOU — " + fails.joined(separator: "; "))
                exit(fails.isEmpty ? 0 : 1)
            }
        }
        if let i = args.firstIndex(of: "--selection-selftest"), args.count > i + 1 {
            let dir = URL(fileURLWithPath: args[i + 1]); later("SELECTION-SELFTEST") { SelfTests.selectionSelfTest(dir: dir) }
        }
        if let i = args.firstIndex(of: "--steps-selftest"), args.count > i + 1 {
            let dir = URL(fileURLWithPath: args[i + 1]); later("STEPS-SELFTEST") { SelfTests.stepsSelfTest(dir: dir) }
        }
        if let i = args.firstIndex(of: "--layout-selftest"), args.count > i + 1 {
            let dir = URL(fileURLWithPath: args[i + 1]); later("LAYOUT-SELFTEST") { SelfTests.layoutSelfTest(dir: dir) }
        }
        if args.contains("--dock-selftest") { later("DOCK-SELFTEST") { SelfTests.dockSelfTest(delegate: self) } }
        if let i = args.firstIndex(of: "--newimage-selftest"), args.count > i + 1 {
            let dir = URL(fileURLWithPath: args[i + 1]); later("NEWIMAGE-SELFTEST") { SelfTests.newImageSelfTest(dir: dir) }
        }
        if args.contains("--perm-check") {   // diagnóstico: estado real da permissão de gravação de ecrã (não captura nada)
            Task { @MainActor in
                let preflight = CGPreflightScreenCaptureAccess()
                var sck = "ok"
                do { _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) } catch { sck = "recusado: \(error.localizedDescription)" }
                let line = "PERM-CHECK: preflight=\(preflight) | ScreenCaptureKit=\(sck) | bundle=\(Bundle.main.bundleIdentifier ?? "nenhum (executável solto)")"
                print(line)
                // `--perm-out <ficheiro>`: escreve lá o resultado (útil quando a app é aberta pelo sistema, sem terminal).
                if let i = args.firstIndex(of: "--perm-out"), args.count > i + 1 { try? line.write(toFile: args[i + 1], atomically: true, encoding: .utf8) }
                exit(0)
            }
        }
        if let i = args.firstIndex(of: "--openfiles-selftest"), args.count > i + 1 {
            let dir = URL(fileURLWithPath: args[i + 1]); later("OPENFILES-SELFTEST") { SelfTests.openFilesSelfTest(dir: dir) }
        }
        if let i = args.firstIndex(of: "--assoc-check"), args.count > i + 1 {   // qual é a app predefinida para este ficheiro?
            let f = URL(fileURLWithPath: args[i + 1])
            let app = NSWorkspace.shared.urlForApplication(toOpen: f)?.path ?? "nenhuma"
            let type = (try? f.resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier) ?? "?"
            print("ASSOC-CHECK: \(f.lastPathComponent) | tipo=\(type) | abre com=\(app)"); exit(0)
        }
        if let i = args.firstIndex(of: "--librarystrip-selftest"), args.count > i + 1 {
            let dir = URL(fileURLWithPath: args[i + 1]); later("LIBRARYSTRIP-SELFTEST") { SelfTests.libraryStripSelfTest(dir: dir) }
        }
        if args.contains("--tools-selftest") {
            let fails = SelfTests.toolsSelfTest()
            print(fails.isEmpty ? "TOOLS-SELFTEST: OK" : "TOOLS-SELFTEST: FALHOU — " + fails.joined(separator: "; "))
            exit(fails.isEmpty ? 0 : 1)
        }
        if args.contains("--panel-selftest") {
            let fails = SelfTests.panelSelfTest()
            print(fails.isEmpty ? "PANEL-SELFTEST: OK" : "PANEL-SELFTEST: FALHOU — " + fails.joined(separator: "; "))
            exit(fails.isEmpty ? 0 : 1)
        }
        if args.contains("--shapes-selftest") {
            let fails = SelfTests.shapesSelfTest()
            print(fails.isEmpty ? "SHAPES-SELFTEST: OK" : "SHAPES-SELFTEST: FALHOU — " + fails.joined(separator: "; "))
            exit(fails.isEmpty ? 0 : 1)
        }
        if args.contains("--effects-selftest") {
            let fails = SelfTests.effectsSelfTest()
            print(fails.isEmpty ? "EFFECTS-SELFTEST: OK" : "EFFECTS-SELFTEST: FALHOU — " + fails.joined(separator: "; "))
            exit(fails.isEmpty ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--archive-selftest"), args.count > i + 1 {
            let fails = SelfTests.archiveSelfTest(URL(fileURLWithPath: args[i + 1]))
            print(fails.isEmpty ? "SELFTEST-ARCHIVE: OK" : "SELFTEST-ARCHIVE: FALHOU — " + fails.joined(separator: "; "))
            exit(fails.isEmpty ? 0 : 1)
        }
        AppState.shared.onCapture = { [weak self] in self?.captureRegion() }
        AppState.shared.refreshLibrary()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Toth")

        statusItem.menu = makeMenu()
        NSApp.mainMenu = MainMenu.build(target: self)
        // Ao mudar o idioma, o menu e o título das Preferências refazem-se.
        languageSub = Localizer.shared.$language.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.statusItem.menu = self?.makeMenu()
                if let self { NSApp.mainMenu = MainMenu.build(target: self) }
                SettingsWindow.refreshTitle()
                ShortcutSettings.shared.message = nil
            }
        }

        // Ctrl+Shift+4
        // Atalho global de captura (configurável em Preferências; por omissão ⌃⇧4).
        let settings = ShortcutSettings.shared
        settings.register = { [weak self] s in self?.registerHotKey(s) ?? false }
        settings.suspend = { [weak self] on in
            guard let self else { return }
            if on { self.hotKey = nil } else { _ = self.registerHotKey(ShortcutSettings.shared.shortcut) }
        }
        if !registerHotKey(settings.shortcut) {
            // O atalho guardado deixou de estar livre: volta ao padrão em vez de ficar sem atalho.
            if !settings.apply(.default) { NSLog("Não foi possível registar nenhum atalho de captura.") }
        }

        // `Capture --render-demo <pacote> <saida.png>`: anota um exemplo de cada ferramenta e exporta (teste do renderer).
        if let i = CommandLine.arguments.firstIndex(of: "--render-demo"), CommandLine.arguments.count > i + 2 {
            renderDemo(CommandLine.arguments[i + 1], CommandLine.arguments[i + 2])
        }

        if args.contains("--shortcut-selftest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                let fails = self.shortcutSelfTest()
                print(fails.isEmpty ? "SHORTCUT-SELFTEST: OK" : "SHORTCUT-SELFTEST: FALHOU — " + fails.joined(separator: "; "))
                exit(fails.isEmpty ? 0 : 1)
            }
        }
        if let i = args.firstIndex(of: "--render-prefs"), args.count > i + 1 {
            SelfTests.renderPreferences(to: args[i + 1]); print("RENDER-PREFS: OK"); exit(0)
        }
        // Como numa app normal, o editor abre ao arrancar (e ao clicar no ícone do Dock; ver applicationShouldHandleReopen).
        if !args.contains("--no-window") { MainWindow.show() }
        // Procura atualizações ao abrir (no máximo uma vez por dia; desligável em Preferências).
        if !args.contains(where: { $0.hasPrefix("--") }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { Updater.shared.checkIfDue() }
        }
        // Ao abrir, valida logo a permissão de gravação de ecrã (guia de 3 passos se faltar). Não nos testes (flags `--…`).
        if !args.contains(where: { $0.hasPrefix("--") }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { Permissions.checkAtLaunch() }
        }
        // Testes visuais: `--window-size LxA` e `--click x,y` (repetível; coordenadas do conteúdo, a partir do topo esquerdo).
        if let k = args.firstIndex(of: "--window-size"), args.count > k + 1 {
            let p = args[k + 1].split(separator: "x").compactMap { Double($0) }
            if p.count == 2 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { MainWindow.placeForTests(width: p[0], height: p[1]) } }
        }
        var delay = 1.6
        for (i, a) in args.enumerated() where a == "--click" && args.count > i + 1 {
            let c = args[i + 1].split(separator: ",").compactMap { Double($0) }
            if c.count == 2 { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainWindow.clickForTests(x: c[0], y: c[1]) }; delay += 0.7 }
        }
        if args.contains("--show-prefs") { SettingsWindow.show() }
        if args.contains("--show-browser") { MainWindow.show(); AppState.shared.openSaved() }

        // `Capture --open <pacote>`: abre a janela já com essa captura.
        if let i = CommandLine.arguments.firstIndex(of: "--open"), CommandLine.arguments.count > i + 1 {
            AppState.shared.open(URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            // `--tool <nome>`: escolhe a ferramenta (para testes visuais).
            if let j = CommandLine.arguments.firstIndex(of: "--tool"), CommandLine.arguments.count > j + 1,
               let t = Tool(rawValue: CommandLine.arguments[j + 1]) { AppState.shared.model?.tool = t }
            // `--select <n>`: seleciona o n-ésimo elemento (por ordem de desenho), para testes visuais.
            if let j = CommandLine.arguments.firstIndex(of: "--select"), CommandLine.arguments.count > j + 1,
               let n = Int(CommandLine.arguments[j + 1]), let m = AppState.shared.model, m.doc.ordered.indices.contains(n) {
                m.selection = m.doc.ordered[n].id
                m.tool = .select
            }
            MainWindow.show()
        }

        // `Capture --open <pacote> --select <n> --edit-selftest`: testa a edição de texto em linha e sai.
        if CommandLine.arguments.contains("--edit-selftest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let canvas = CanvasView.current else { print("SELFTEST: canvas não encontrado"); exit(1) }
                let fails = canvas.selfTestEditing()
                print(fails.isEmpty ? "SELFTEST: OK" : "SELFTEST: FALHOU — " + fails.joined(separator: "; "))
                exit(fails.isEmpty ? 0 : 1)
            }
        }

        if CommandLine.arguments.contains("--edit-hold") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { CanvasView.current?.debugHoldEditing() }
        }

        if CommandLine.arguments.contains("--paste-selftest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let m = AppState.shared.model else { print("PASTE-SELFTEST: sem modelo"); exit(1) }
                let fails = m.selfTestPaste()
                print(fails.isEmpty ? "PASTE-SELFTEST: OK" : "PASTE-SELFTEST: FALHOU — " + fails.joined(separator: "; "))
                exit(fails.isEmpty ? 0 : 1)
            }
        }

        // `Capture --capture-hold`: abre já a seleção de região com uma área pré-escolhida (para capturas de ecrã).
        if CommandLine.arguments.contains("--capture-hold") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.captureRegion() }
        }

        // `Capture --capture-selftest`: congela o ecrã, "confirma" uma área pré-escolhida e grava o recorte (sem rato).
        if let i = CommandLine.arguments.firstIndex(of: "--capture-selftest"), CommandLine.arguments.count > i + 1 {
            let out = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    guard let screen = NSScreen.main, let snap = try? await ScreenCapturer.snapshot(of: screen) else { print("CAPTURE-SELFTEST: sem snapshot"); exit(1) }
                    self.selector.begin(snapshots: [(screen, snap)]) { image in
                        guard let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { print("CAPTURE-SELFTEST: sem imagem"); exit(1) }
                        try? png.write(to: URL(fileURLWithPath: out))
                        print("CAPTURE-SELFTEST: OK \(image.width)x\(image.height) (snapshot \(snap.width)x\(snap.height))")
                        exit(0)
                    }
                    // Com um 2.º argumento (segundos), seleciona o ecrã todo e espera antes de confirmar,
                    // para se poder mudar o ecrã nesse intervalo e provar que a captura é a do instante inicial.
                    let delay = CommandLine.arguments.count > i + 2 ? Double(CommandLine.arguments[i + 2]) : nil
                    self.selector.debugPreselect(delay == nil ? CGRect(x: 300, y: 200, width: 700, height: 420) : CGRect(origin: .zero, size: screen.frame.size))
                    DispatchQueue.main.asyncAfter(deadline: .now() + (delay ?? 0)) { self.selector.debugConfirm() }
                }
            }
        }

        // `--render-selector <saida.png>`: desenha o seletor de região (imagem sintética) fora do ecrã.
        if let i = CommandLine.arguments.firstIndex(of: "--render-selector"), CommandLine.arguments.count > i + 1, let screen = NSScreen.main {
            let size = CGSize(width: 1000, height: 640)
            let img = Self.syntheticSnapshot(for: screen)
            RegionSelector.renderForTests(image: img, size: size, selection: CGRect(x: 180, y: 120, width: 560, height: 360), to: CommandLine.arguments[i + 1])
            print("RENDER-SELECTOR: OK"); exit(0)
        }

        // `--render-hud <saida.png>`: desenha a barra da captura com rolagem nos três estados.
        if let i = CommandLine.arguments.firstIndex(of: "--render-hud"), CommandLine.arguments.count > i + 1 {
            ScrollHUD.renderForTests(to: CommandLine.arguments[i + 1]); print("RENDER-HUD: OK"); exit(0)
        }

        if CommandLine.arguments.contains("--scroll-bench") { print("SCROLL-BENCH: " + ScrollSelfTest.bench()); exit(0) }

        // `--scroll-live x,y,w,h <saida.png> [passos] [delta] [intervalo]`: fluxo real sobre o ecrã, com rolagem automática de teste.
        if let i = CommandLine.arguments.firstIndex(of: "--scroll-live"), CommandLine.arguments.count > i + 2 {
            let v = CommandLine.arguments[i + 1].split(separator: ",").compactMap { Double($0) }
            let out = CommandLine.arguments[i + 2]
            let steps = CommandLine.arguments.count > i + 3 ? Int(CommandLine.arguments[i + 3]) ?? 12 : 12
            let delta = CommandLine.arguments.count > i + 4 ? Int(CommandLine.arguments[i + 4]) ?? 300 : 300
            let interval = CommandLine.arguments.count > i + 5 ? Double(CommandLine.arguments[i + 5]) ?? 0.4 : 0.4
            if v.count == 4 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    Task { @MainActor in
                        let r = await ScrollLiveTest.run(rect: CGRect(x: v[0], y: v[1], width: v[2], height: v[3]), out: out, steps: steps, delta: delta, interval: interval)
                        print("SCROLL-LIVE: " + r); exit(0)
                    }
                }
            }
        }

        // `--scroll-focus-selftest`: com o editor aberto, «Rolagem» não pode deixar janelas do Toth à frente.
        if CommandLine.arguments.contains("--scroll-focus-selftest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    let fails = await SelfTests.scrollFocusSelfTest(delegate: self)
                    print(fails.isEmpty ? "SCROLL-FOCUS-SELFTEST: OK" : "SCROLL-FOCUS-SELFTEST: FALHOU — " + fails.joined(separator: "; "))
                    exit(fails.isEmpty ? 0 : 1)
                }
            }
        }

        // `--scroll-e2e x,y,w,h <app> <saida.png> [passos] [delta]`: seletor real + sessão real, com o editor aberto e a app à frente.
        if let i = CommandLine.arguments.firstIndex(of: "--scroll-e2e"), CommandLine.arguments.count > i + 3 {
            let v = CommandLine.arguments[i + 1].split(separator: ",").compactMap { Double($0) }
            let owner = CommandLine.arguments[i + 2], out = CommandLine.arguments[i + 3]
            let steps = CommandLine.arguments.count > i + 4 ? Int(CommandLine.arguments[i + 4]) ?? 10 : 10
            let delta = CommandLine.arguments.count > i + 5 ? Int(CommandLine.arguments[i + 5]) ?? 300 : 300
            if v.count == 4 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    Task { @MainActor in
                        let r = await ScrollE2ETest.run(rect: CGRect(x: v[0], y: v[1], width: v[2], height: v[3]), owner: owner, out: out, steps: steps, delta: delta)
                        print("SCROLL-E2E: " + r); exit(0)
                    }
                }
            }
        }

        // `--permissions-selftest` (passos do guia de permissões) e `--render-permissions <saida.png>` (aspeto, 3 estados).
        if args.contains("--permissions-selftest") {
            DispatchQueue.main.async {
                let fails = PermissionsSelfTest.run()
                print(fails.isEmpty ? "PERMISSIONS-SELFTEST: OK" : "PERMISSIONS-SELFTEST: FALHOU — " + fails.joined(separator: "; "))
                exit(fails.isEmpty ? 0 : 1)
            }
        }
        if let i = args.firstIndex(of: "--render-permissions"), args.count > i + 1 {
            DispatchQueue.main.async { PermissionsSelfTest.render(to: args[i + 1]); print("RENDER-PERMISSIONS: OK"); exit(0) }
        }

        // Só para testes de ponta a ponta da atualização: `--update-feed <url>`, `--update-auto-accept`, `--update-check-now`.
        if let i = args.firstIndex(of: "--update-feed"), args.count > i + 1 { Updater.feedOverride = URL(string: args[i + 1]) }
        if args.contains("--update-auto-accept") { Updater.autoAccept = true }
        if args.contains("--update-check-now") { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Updater.shared.checkNow() } }

        // `--update-selftest <pasta>`: motor de atualização com uma release falsa em ficheiros locais.
        if let i = args.firstIndex(of: "--update-selftest"), args.count > i + 1 {
            Task { @MainActor in
                let fails = await UpdateSelfTest.run(dir: URL(fileURLWithPath: args[i + 1]))
                print(fails.isEmpty ? "UPDATE-SELFTEST: OK" : "UPDATE-SELFTEST: FALHOU — " + fails.joined(separator: "; "))
                exit(fails.isEmpty ? 0 : 1)
            }
        }

        if let i = args.firstIndex(of: "--render-video-hud"), args.count > i + 1 {
            DispatchQueue.main.async { VideoHUD.renderForTests(to: args[i + 1]); print("RENDER-VIDEO-HUD: OK"); exit(0) }
        }
        if let i = args.firstIndex(of: "--render-videoeditor"), args.count > i + 1 {
            Task { @MainActor in await VideoEditSelfTest.render(to: args[i + 1]); print("RENDER-VIDEOEDITOR: OK"); exit(0) }
        }
        // `--videoedit-selftest <pasta>`: corte de vídeo (o que sobra toca seguido), desfazer, memória dos cortes e exportação.
        if let i = args.firstIndex(of: "--videoedit-selftest"), args.count > i + 1 {
            Task { @MainActor in
                let fails = await VideoEditSelfTest.run(dir: URL(fileURLWithPath: args[i + 1]))
                print(fails.isEmpty ? "VIDEOEDIT-SELFTEST: OK" : "VIDEOEDIT-SELFTEST: FALHOU — " + fails.joined(separator: "; "))
                exit(fails.isEmpty ? 0 : 1)
            }
        }
        // `--video-selftest <pasta>`: gravação de vídeo com fotogramas e sons sintéticos (pausa, microfone ligado/desligado).
        if let i = args.firstIndex(of: "--video-selftest"), args.count > i + 1 {
            Task { @MainActor in
                let fails = await VideoSelfTest.run(dir: URL(fileURLWithPath: args[i + 1]))
                print(fails.isEmpty ? "VIDEO-SELFTEST: OK" : "VIDEO-SELFTEST: FALHOU — " + fails.joined(separator: "; "))
                exit(fails.isEmpty ? 0 : 1)
            }
        }

        // `--video-e2e x,y,w,h <app> <pasta>`: seletor real + gravação real (com pausa), editor aberto e a app à frente.
        if let i = args.firstIndex(of: "--video-e2e"), args.count > i + 3 {
            let v = args[i + 1].split(separator: ",").compactMap { Double($0) }
            if v.count == 4 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    Task { @MainActor in
                        let r = await VideoE2ETest.run(rect: CGRect(x: v[0], y: v[1], width: v[2], height: v[3]), owner: args[i + 2], dir: URL(fileURLWithPath: args[i + 3]))
                        print("VIDEO-E2E: " + r); exit(0)
                    }
                }
            }
        }

        // `--scroll-selftest`: captura por rolagem sobre páginas sintéticas (sem tocar no ecrã real).
        if CommandLine.arguments.contains("--scroll-selftest") {
            Task { @MainActor in
                let fails = await ScrollSelfTest.run()
                print(fails.isEmpty ? "SCROLL-SELFTEST: OK" : "SCROLL-SELFTEST: FALHOU — " + fails.joined(separator: "; "))
                exit(fails.isEmpty ? 0 : 1)
            }
        }

        // `Capture --fullscreen`: captura o ecrã inteiro e termina (útil para testes).
        if CommandLine.arguments.contains("--fullscreen") { runFullScreen(thenQuit: true) }
    }

    /// Menu da barra de menus, no idioma atual.
    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: L("Abrir janela do Toth"), action: #selector(showWindow), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let captureItem = menu.addItem(withTitle: "\(L("Capturar região"))  (\(ShortcutSettings.shared.shortcut.shown))", action: #selector(captureRegion), keyEquivalent: "")
        captureItem.target = self
        captureMenuItem = captureItem
        menu.addItem(withTitle: L("Capturar ecrã inteiro"), action: #selector(captureFullScreen), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Nova imagem em branco…"), action: #selector(newBlankImage), keyEquivalent: "").target = self
        menu.addItem(withTitle: L("Nova imagem da área de transferência"), action: #selector(newFromClipboard), keyEquivalent: "").target = self
        menu.addItem(withTitle: L("Abrir imagem…"), action: #selector(openImage), keyEquivalent: "").target = self
        menu.addItem(withTitle: L("Abrir Biblioteca"), action: #selector(openCapture), keyEquivalent: "").target = self
        menu.addItem(withTitle: L("Abrir pasta de capturas"), action: #selector(openFolder), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Preferências…"), action: #selector(showPreferences), keyEquivalent: ",").target = self
        menu.addItem(withTitle: L("Procurar atualizações…"), action: #selector(checkForUpdates), keyEquivalent: "").target = self
        menu.addItem(withTitle: L("Sair"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc func showWindow() { MainWindow.show() }

    // MARK: Ações do menu principal (e do menu da barra de menus)

    @objc func showAbout() {
        let credits = NSAttributedString(string: L("Captura e anotação de ecrã. Gratuita, local e sem contas.") + "\n© 2026 Alex Felizardo",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Toth", .credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func newBlankImage() { MainWindow.show(); AppState.shared.showNewImage = true }
    @objc func newFromClipboard() { MainWindow.show(); AppState.shared.pasteAsNewCapture() }
    @objc func saveAs() { AppState.shared.model?.exportToFile() }
    @objc func toggleProperties() { PanelLayout.shared.toggle() }
    @objc func toggleLibrary() { AppState.shared.toggleLibraryStrip() }
    @objc func zoomIn() { AppState.shared.model?.zoomIn() }
    @objc func zoomOut() { AppState.shared.model?.zoomOut() }
    @objc func zoomFit() { AppState.shared.model?.zoomFit() }
    @objc func zoomActual() { AppState.shared.model?.zoomActual() }
    // Se o editor não for a "primeira resposta" (por exemplo, depois de mexer num controlo do painel), os atalhos de
    // edição chegam aqui, no fim da cadeia de respostas.
    @objc func undo(_ sender: Any?) { AppState.shared.model?.undo() }
    @objc func redo(_ sender: Any?) { AppState.shared.model?.redo() }
    @objc func cut(_ sender: Any?) { AppState.shared.model?.cutSelection() }
    @objc func copy(_ sender: Any?) { if let m = AppState.shared.model { if m.selection != nil { m.copySelection() } else { m.copyToPasteboard() } } }
    @objc func paste(_ sender: Any?) { AppState.shared.model?.paste() }
    @objc func duplicate(_ sender: Any?) { AppState.shared.model?.duplicateSelection() }

    /// Clique no ícone do Dock: mostra o editor.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindow.show()
        return true
    }
    @objc func showPreferences() { SettingsWindow.show() }
    @objc func checkForUpdates() { Updater.shared.checkNow() }

    func applicationDidBecomeActive(_ notification: Notification) {
        if !CommandLine.arguments.contains(where: { $0.hasPrefix("--") }) { Updater.shared.checkIfDue() }
    }

    /// (Re)regista o atalho global. Se falhar, o registo anterior não é perdido (o chamador repõe-no).
    private func registerHotKey(_ s: Shortcut) -> Bool {
        hotKey = nil   // liberta o registo anterior antes de pedir o novo
        guard let new = HotKey(keyCode: s.keyCode, modifiers: s.nsModifiers, action: { [weak self] in self?.captureRegion() }) else { return false }
        hotKey = new
        captureMenuItem?.title = "\(L("Capturar região"))  (\(s.shown))"
        return true
    }

    /// Congela o ecrã no instante do atalho e deixa escolher/ajustar a área; só ao confirmar vai para o editor.
    /// Quantas vezes a captura de região foi pedida (usado no autoteste do atalho).
    private(set) var captureRequests = 0

    @objc func captureRegion() {
        captureRequests += 1
        guard !selector.isActive else { return }
        Task { @MainActor in
            // (com `--capture-hold` usa-se uma imagem sintética: não precisa de permissão)
            if !CommandLine.arguments.contains("--capture-hold"), !(await Permissions.ensure()) { return }
            do {
                var snapshots: [(screen: NSScreen, image: CGImage)] = []
                for screen in NSScreen.screens {
                    // `--capture-hold` usa uma imagem sintética em vez do ecrã real (testes visuais sem expor o ecrã).
                    let image = CommandLine.arguments.contains("--capture-hold") ? Self.syntheticSnapshot(for: screen) : try await ScreenCapturer.snapshot(of: screen)
                    snapshots.append((screen, image))
                }
                selector.onVideo = { screen, rect in
                    Task { @MainActor in
                        guard let url = await VideoCaptureSession.record(screen: screen, rect: rect) else { return }
                        AppState.shared.open(url)
                        NSSound(named: "Grab")?.play()
                        MainWindow.show()
                    }
                }
                selector.onScroll = { [weak self] screen, rect, first in
                    Task { @MainActor in
                        guard let image = await ScrollCaptureSession.capture(screen: screen, rect: rect, first: first) else { return }
                        self?.finish { image }
                    }
                }
                selector.begin(snapshots: snapshots) { [weak self] image in
                    guard let image else { return }   // cancelado
                    self?.finish { image }
                }
                if CommandLine.arguments.contains("--capture-hold") { selector.debugPreselect(CGRect(x: 300, y: 200, width: 700, height: 420)) }
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    func syntheticSnapshotForTests(for screen: NSScreen) -> CGImage { Self.syntheticSnapshot(for: screen) }

    private static func syntheticSnapshot(for screen: NSScreen) -> CGImage {
        let size = NSSize(width: screen.frame.width * screen.backingScaleFactor, height: screen.frame.height * screen.backingScaleFactor)
        let img = NSImage(size: size, flipped: false) { r in
            NSGradient(colors: [.systemTeal, .systemIndigo])!.draw(in: r, angle: 35)
            ("Ecrã de teste (sintético)" as NSString).draw(at: NSPoint(x: 340, y: r.height - 330), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 40), .foregroundColor: NSColor.white])
            return true
        }
        return img.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }

    @objc func captureFullScreen() { runFullScreen(thenQuit: false) }

    private func runFullScreen(thenQuit: Bool) {
        Task { @MainActor in
            guard await Permissions.ensure() else { if thenQuit { exit(2) }; return }
            let screen = NSScreen.main ?? NSScreen.screens[0]
            finish(thenQuit: thenQuit) { try await ScreenCapturer.snapshot(of: screen) }
        }
    }

    /// Muda o atalho, valida recusas, persiste, e simula a tecla no sistema para ver se dispara a captura.
    private func shortcutSelfTest() -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { fails.append(what) } }
        let settings = ShortcutSettings.shared
        let defaults = UserDefaults.standard
        let savedData = defaults.data(forKey: "captureShortcut")
        defer {   // repõe exatamente o que havia
            if let d = savedData, let s = try? JSONDecoder().decode(Shortcut.self, from: d) { _ = settings.apply(s) }
            else { _ = settings.apply(.default); defaults.removeObject(forKey: "captureShortcut") }
        }

        // 1) combinações inválidas são recusadas e o atalho atual não muda
        let before = settings.shortcut
        check(!settings.apply(Shortcut(keyCode: 21, modifiers: [.command, .shift], keyLabel: "4")) && settings.message != nil, "⇧⌘4 devia ser recusado")
        check(!settings.apply(Shortcut(keyCode: 8, modifiers: [], keyLabel: "C")), "tecla sem modificador devia ser recusada")
        check(settings.shortcut == before, "o atalho mudou apesar de recusas")

        // 2) combinação válida: aplica, persiste, atualiza o menu
        let mine = Shortcut(keyCode: 16, modifiers: [.control, .option, .shift], keyLabel: "Y")   // ⌃⌥⇧Y
        check(settings.apply(mine), "⌃⌥⇧Y devia ser aceite")
        check(settings.shortcut == mine, "atalho não ficou ⌃⌥⇧Y")
        let stored = defaults.data(forKey: "captureShortcut").flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
        check(stored == mine, "não ficou guardado nas preferências")
        check(captureMenuItem?.title.contains("⌃⌥⇧Y") == true, "menu não mostra o atalho novo: \(captureMenuItem?.title ?? "nil")")

        // 3) registo no sistema: o macOS não deixa registar duas vezes a mesma combinação na mesma app.
        //    - a nova já está registada (um 2.º registo é recusado);
        //    - a antiga foi libertada (um registo novo é aceite).
        //    (Simular a tecla ao nível do sistema exigiria permissão de Acessibilidade.)
        let dup = HotKey(keyCode: mine.keyCode, modifiers: mine.nsModifiers) {}
        check(dup == nil, "a combinação nova não ficou registada no sistema")
        var oldProbe: HotKey? = HotKey(keyCode: before.keyCode, modifiers: before.nsModifiers) {}
        check(oldProbe != nil, "a combinação antiga não foi libertada")
        oldProbe = nil   // liberta já: uma sonda viva engoliria o evento do passo seguinte e bloquearia o repor do padrão

        // 4) o evento de atalho chega ao tratador e dispara a captura
        let n0 = captureRequests
        var ref: EventRef?
        var hkID = EventHotKeyID(signature: OSType(0x43415054), id: 1)
        CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, EventAttributes(kEventAttributeNone), &ref)
        if let ref {
            SetEventParameter(ref, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &hkID)
            SendEventToEventTarget(ref, GetApplicationEventTarget())
            ReleaseEvent(ref)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        check(captureRequests > n0, "o evento de atalho não disparou a captura")
        selector.cancelForTests()

        // 5) o gravador: carregar numa combinação (eventos entregues à app, como se o utilizador carregasse)
        func key(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags) {
            guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                           isARepeat: false, keyCode: code) else { return }
            NSApp.sendEvent(e)
        }
        settings.startRecording()
        check(settings.recording, "não começou a gravar")
        key(32, "u", [.control, .option, .shift])                   // ⌃⌥⇧U
        check(!settings.recording && settings.shortcut.display == "⌃⌥⇧U", "gravador não aplicou ⌃⌥⇧U (ficou \(settings.shortcut.display))")
        settings.startRecording()
        key(21, "4", [.command, .shift])                            // ⇧⌘4: recusada, continua a gravar
        check(settings.recording && settings.message != nil && settings.shortcut.display == "⌃⌥⇧U", "⇧⌘4 devia ser recusada sem sair da gravação")
        key(8, "c", [])                                             // sem modificador: recusada
        check(settings.recording && settings.shortcut.display == "⌃⌥⇧U", "tecla sem modificador devia ser recusada")
        key(53, "\u{1b}", [])                                       // Esc cancela, atalho mantém-se
        check(!settings.recording && settings.shortcut.display == "⌃⌥⇧U", "Esc devia cancelar sem mudar o atalho")
        settings.startRecording()
        key(96, "", [])                                             // F5 sozinha é válida
        check(settings.shortcut.display == "F5", "F5 devia ser aceite (ficou \(settings.shortcut.display))")

        // 6) repor padrão
        settings.resetToDefault()
        check(settings.shortcut == .default, "repor padrão falhou")
        return fails
    }

    private func renderDemo(_ pkg: String, _ out: String) {
        do {
            let m = try EditorModel(url: URL(fileURLWithPath: pkg))
            func add(_ shape: CaptureCore.Shape, _ edit: (inout Style) -> Void = { _ in }) {
                var st = Style(); edit(&st)
                m.perform { $0.add(shape, style: st) }
            }
            // 1) Marcadores de lista junto ao texto, com alinhamento centrado e à direita
            add(.textBox(origin: Point(x: 10, y: 10), width: 200, height: 90, string: "Centrado um\nCentrado dois", fontSize: 16)) {
                $0.lineVisible = true; $0.colorHex = "#0A84FF"; $0.text = TextFormat(align: .center, vAlign: .middle, list: .bullet)
            }
            add(.textBox(origin: Point(x: 220, y: 10), width: 200, height: 90, string: "À direita um\nÀ direita dois", fontSize: 16)) {
                $0.lineVisible = true; $0.colorHex = "#34C759"; $0.text = TextFormat(align: .right, vAlign: .middle, list: .numbered)
            }
            // 2) Blur gaussiano (intensidades diferentes) sobre texto da captura
            add(.gaussian(origin: Point(x: 0, y: 70), width: 240, height: 24, intensity: 3))
            add(.gaussian(origin: Point(x: 250, y: 70), width: 290, height: 24, intensity: 9))
            // 3) Imagem colada (gerada aqui) por cima da captura
            let img = NSImage(size: NSSize(width: 160, height: 90), flipped: false) { r in
                NSGradient(colors: [.systemPink, .systemOrange, .systemYellow])!.draw(in: r, angle: 20)
                ("COLADA" as NSString).draw(at: NSPoint(x: 28, y: 32), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 26), .foregroundColor: NSColor.white])
                return true
            }
            if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                m.visibleCenter = Point(x: 120, y: 200)
                m.pasteImage(png)
            }
            // 4) Objetos que passam da área original: a área expande-se (direita/baixo e esquerda/cima)
            m.mutate { $0.backgroundHex = "#DCEBFF" }
            add(.rect(origin: Point(x: 560, y: 360), width: 140, height: 90)) { $0.colorHex = "#FF3B30"; $0.fillHex = "#FFF3B0" }
            if let id = m.doc.ordered.last?.id { m.mutate { _ = $0.expandAreaToFit(ids: [id]) } }
            add(.arrow(from: Point(x: -60, y: -30), to: Point(x: 90, y: 40))) { $0.colorHex = "#AF52DE" }
            if let id = m.doc.ordered.last?.id { m.mutate { _ = $0.expandAreaToFit(ids: [id]) } }
            try m.exportPNG()?.write(to: URL(fileURLWithPath: out))
            exit(0)
        } catch { NSLog("Erro: \(error)"); exit(1) }
    }

    @objc func openCapture() { MainWindow.show(); AppState.shared.openSaved() }   // biblioteca
    @objc func openImage() { MainWindow.show(); AppState.shared.openImages() }

    /// O macOS entrega ficheiros à app: duplo clique num `.capture`, "Abrir com" Toth, ou arrastar para o ícone do Dock.
    func application(_ application: NSApplication, open urls: [URL]) {
        // Diagnóstico (desligado por omissão): `defaults write <id> debugLogOpens -bool YES` escreve num ficheiro o que o macOS entrega.
        if let path = UserDefaults.standard.string(forKey: "debugLogOpensTo") {
            let line = "recebeu \(urls.count) ficheiro(s): " + urls.map(\.lastPathComponent).joined(separator: " | ") + "\n"
            if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
            else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
        }
        MainWindow.show()
        AppState.shared.open(urls: urls)
    }

    @objc func openFolder() {
        NSWorkspace.shared.open(CaptureStore.folder)
    }

    private func finish(thenQuit: Bool = false, _ work: @escaping () async throws -> CGImage) {
        Task { @MainActor in
            do {
                let image = try await work()
                let url = try CaptureStore.save(image)
                CaptureStore.copyToPasteboard(image)
                NSSound(named: "Grab")?.play()
                NSLog("Toth: captura guardada em \(url.path)")
                if thenQuit { exit(0) }
                AppState.shared.open(url)
                MainWindow.show()
            } catch {
                if thenQuit { NSLog("Erro: \(error)"); exit(1) }
                NSAlert(error: error).runModal()
            }
        }
    }
}
