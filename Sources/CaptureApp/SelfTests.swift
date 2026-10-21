// Copyright © 2026 Alex Felizardo. Todos os direitos reservados.
// Software gratuito, de código fechado: ver LICENSE.md. Proprietary freeware — see LICENSE.md.

import AppKit
import SwiftUI
import CaptureCore

/// Verificações sem rato, ativadas por argumentos de linha de comando (ver README).
@MainActor
enum SelfTests {
    /// Imagem sintética com exatamente `w × h` píxeis (independente da escala do ecrã: num Retina o `NSImage` desenharia a 2×).
    static func image(_ w: Int, _ h: Int, _ c1: NSColor, _ c2: NSColor, label: String) -> CGImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let r = NSRect(x: 0, y: 0, width: w, height: h)
        NSGradient(colors: [c1, c2])!.draw(in: r, angle: 30)
        (label as NSString).draw(at: NSPoint(x: 24, y: r.height - 64), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 34), .foregroundColor: NSColor.white])
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }

    /// Biblioteca sintética: capturas novas (arquivos, algumas anotadas) e capturas antigas (pastas).
    static func makeDemoLibrary(_ dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        CaptureStore.overrideFolder = dir
        let palette: [(NSColor, NSColor, String)] = [(.systemTeal, .systemIndigo, "Arquivo 1"), (.systemOrange, .systemPink, "Arquivo 2"),
                                                      (.systemGreen, .systemBlue, "Arquivo 3"), (.systemPurple, .systemRed, "Arquivo 4")]
        for (i, p) in palette.enumerated() {
            let url = try CaptureStore.save(image(900 + i * 60, 560, p.0, p.1, label: p.2))
            if i % 2 == 0 {   // anotada: o preview tem de mostrar as anotações
                let m = try EditorModel(url: url)
                _ = m.addAnnotation(.arrow(from: Point(x: 60, y: 480), to: Point(x: 380, y: 300)))
                _ = m.addAnnotation(.textBox(origin: Point(x: 400, y: 120), width: 320, height: 70, string: "Anotada", fontSize: 30))
            }
        }
        // antigas (pastas)
        for n in 1...2 {
            let folder = dir.appendingPathComponent("Capture 2020-01-0\(n) 10.00.00.capture")
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("assets"), withIntermediateDirectories: true)
            let cg = image(800, 500, .systemYellow, .systemBrown, label: "Pasta antiga \(n)")
            let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
            try CapturePackage.encode(CaptureDocument(canvasWidth: 800, canvasHeight: 500)).write(to: folder.appendingPathComponent("document.json"))
            try png.write(to: folder.appendingPathComponent("assets/original.png"))
        }
    }

    /// Ciclo completo num arquivo: criar, anotar, colar imagem, desfazer, reabrir, validar com o `unzip` do sistema.
    static func archiveSelfTest(_ dir: URL) -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { fails.append(what) } }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            CaptureStore.overrideFolder = dir
            let url = try CaptureStore.save(image(640, 400, .systemTeal, .systemIndigo, label: "teste"))
            var isDir: ObjCBool = true
            check(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue, "a captura nova não é um ficheiro único")
            let originalBefore = CaptureContainer.readEntry(CapturePackage.originalFile, at: url)

            let m = try EditorModel(url: url)
            let arrow = m.addAnnotation(.arrow(from: Point(x: 10, y: 10), to: Point(x: 200, y: 120)))
            m.pasteImage(NSBitmapImageRep(cgImage: image(120, 80, .systemPink, .systemOrange, label: "colada")).representation(using: .png, properties: [:])!)
            let pastedAsset = m.selected?.shape.imageAsset
            m.undo(); m.redo()
            m.delete(arrow)
            check(m.doc.annotations.count == 1, "esperava 1 anotação (a imagem colada); há \(m.doc.annotations.count)")

            // reabrir de raiz: tudo tem de estar no ficheiro
            let again = try EditorModel(url: url)
            check(again.doc.annotations.count == 1 && again.doc.annotations[0].shape.imageAsset == pastedAsset, "reabrir não trouxe a imagem colada")
            check(pastedAsset.flatMap { again.assets.image(named: $0) } != nil, "imagem colada não carrega ao reabrir")
            check(CaptureContainer.readEntry(CapturePackage.originalFile, at: url) == originalBefore, "o original foi alterado")
            check(CaptureContainer.readEntry(CapturePackage.previewFile, at: url) != nil, "sem preview")

            // validação por uma ferramenta externa e independente
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            p.arguments = ["-tq", url.path]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            try p.run(); p.waitUntilExit()
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            check(p.terminationStatus == 0, "unzip -t falhou: \(out)")
            print("SELFTEST-ARCHIVE unzip: \(out.trimmingCharacters(in: .whitespacesAndNewlines))  | tamanho \(((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0) / 1024) KB")
        } catch { fails.append("erro: \(error)") }
        return fails
    }

    /// Compactação das pastas antigas: confere que viram ficheiros únicos legíveis e que as pastas foram para o Lixo.
    /// Limpa do Lixo só os itens sintéticos que criou (nomes `Capture 2020-01-0N 10.00.00.capture`).
    static func compactSelfTest(_ dir: URL) -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { fails.append(what) } }
        do {
            try makeDemoLibrary(dir)
            let state = AppState.shared
            state.refreshLibrary()
            check(state.folderCaptureCount == 2, "esperava 2 pastas antigas, há \(state.folderCaptureCount)")
            let docsBefore = state.library.count

            state.compactOldCaptures()
            check(state.folderCaptureCount == 0, "ainda há pastas antigas")
            check(state.library.count == docsBefore, "o número de capturas mudou")
            for n in 1...2 {
                let url = dir.appendingPathComponent("Capture 2020-01-0\(n) 10.00.00.capture")
                var isDir: ObjCBool = true
                check(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue, "\(url.lastPathComponent) não é ficheiro")
                let c = try CaptureContainer(url: url)
                check(c.kind == .archive && c.exists(CapturePackage.originalFile) && c.exists(CapturePackage.documentFile), "\(url.lastPathComponent) incompleto")
                check(Thumbnails.load(url) != nil, "sem miniatura para \(url.lastPathComponent)")
            }
            check(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("Capture 2020-01-01 10.00.00.capture.tmp").path), "ficheiro .tmp esquecido")
            // limpar do Lixo os 2 itens sintéticos
            let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
            var removedFromTrash = 0
            for n in 1...2 {
                let item = trash.appendingPathComponent("Capture 2020-01-0\(n) 10.00.00.capture")
                if FileManager.default.fileExists(atPath: item.path) { try? FileManager.default.removeItem(at: item); removedFromTrash += 1 }
            }
            check(removedFromTrash == 2, "as 2 pastas não chegaram ao Lixo (\(removedFromTrash))")
            print("COMPACT-SELFTEST: \(state.errorMessage ?? "")")
        } catch { fails.append("erro: \(error)") }
        return fails
    }

    /// Desenha a janela de Preferências para uma imagem (sem tocar no ecrã), nos estados normal e a gravar.
    static func renderPreferences(to path: String) {
        let settings = ShortcutSettings.shared
        func snapshot() -> NSBitmapImageRep? {
            let host = NSHostingView(rootView: SettingsView(settings: settings))
            host.frame = NSRect(x: 0, y: 0, width: 520, height: 520)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)   // aparência fixa (teste determinístico)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
            host.cacheDisplay(in: host.bounds, to: rep)
            return rep
        }
        guard let normal = snapshot() else { return }
        settings.startRecording()
        _ = settings.apply(Shortcut(keyCode: 21, modifiers: [.command, .shift], keyLabel: "4"))   // gera a mensagem de aviso
        guard let recording = snapshot() else { return }
        settings.stopRecording()
        settings.message = nil
        let out = NSImage(size: NSSize(width: 520, height: 1050))
        out.lockFocus()
        NSColor.windowBackgroundColor.setFill(); NSRect(x: 0, y: 0, width: 520, height: 1050).fill()
        recording.draw(in: NSRect(x: 0, y: 0, width: 520, height: 520))
        normal.draw(in: NSRect(x: 0, y: 530, width: 520, height: 520))
        out.unlockFocus()
        if let tiff = out.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

    // MARK: Memória das ferramentas entre sessões (2 execuções: `write`, depois `verify`)

    private static let backupKey = "toolDefaults.selftest.backup"

    static func defaultsSelfTest(phase: String, dir: URL) -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { fails.append(what) } }
        let defaults = UserDefaults.standard
        let td = ToolDefaults.shared

        if phase == "write" {
            // guarda o que havia, para o `verify` repor
            if let d = defaults.data(forKey: "toolDefaults.v1") { defaults.set(d, forKey: backupKey) } else { defaults.removeObject(forKey: backupKey) }
            td.resetAll()
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                CaptureStore.overrideFolder = dir
                let m = try EditorModel(url: try CaptureStore.save(image(400, 300, .systemTeal, .systemIndigo, label: "defaults")))

                // 1) editar um elemento SELECIONADO (com a ferramenta Mover) atualiza o padrão da ferramenta que o criou
                m.tool = .rect
                let id = m.addAnnotation(.rect(origin: Point(x: 10, y: 10), width: 50, height: 40))
                m.selection = id; m.tool = .select
                var st = m.currentStyle; st.colorHex = "#123456"; st.fillHex = "#ABCDEF"; st.lineVisible = false
                m.setStyle(st)
                check(td.style(for: .rect).colorHex == "#123456", "editar um retângulo selecionado não atualizou o padrão do retângulo")
                check(td.style(for: .select) == Tool.select.initialStyle, "a ferramenta Mover não devia guardar estilo")

                // 2) escolher com a ferramenta ativa e nada selecionado
                m.selection = nil
                m.tool = .arrow; m.setStyle(Style(colorHex: "#00AA55", lineWidth: 9, shadow: true, opacity: 0.8))
                m.tool = .text
                var tx = m.style; tx.text = TextFormat(fontName: "Georgia", bold: true, align: .center, vAlign: .middle, list: .numbered); tx.fillHex = "#FFF3B0"
                m.setStyle(tx); m.setFontSize(40)
                m.tool = .callout; var cs = m.style; cs.fillHex = "#FFEEAA"; cs.colorHex = "#FF8800"; m.setStyle(cs); m.setFontSize(31)
                m.tool = .rect; m.setFontSize(27)                               // tamanho do texto dentro do retângulo
                m.tool = .step; var ss = m.style; ss.stepFormat = .romanUpper; ss.text.colorHex = "#FFD60A"; ss.text.fontName = "Menlo"; m.setStyle(ss)
                m.tool = .highlight; var hs = m.style; hs.colorHex = "#FF00FF"; hs.opacity = 0.6; m.setStyle(hs)
                m.tool = .blur; m.setPixelSize(33)
                m.tool = .gaussian; m.setBlurIntensity(21)
            } catch { fails.append("erro: \(error)") }
            print("DEFAULTS-SELFTEST[write]: \(fails.isEmpty ? "gravado" : "falhou")")
        } else {
            // processo novo: tudo tem de vir das preferências
            check(td.style(for: .rect).colorHex == "#123456" && td.style(for: .rect).fillHex == "#ABCDEF" && !td.style(for: .rect).lineVisible, "retângulo não persistiu")
            let a = td.style(for: .arrow)
            check(a.colorHex == "#00AA55" && a.lineWidth == 9 && a.shadow && a.opacity == 0.8, "seta não persistiu")
            let t = td.style(for: .text)
            check(t.text.fontName == "Georgia" && t.text.bold && t.text.align == .center && t.text.vAlign == .middle && t.text.list == .numbered && t.fillHex == "#FFF3B0", "texto não persistiu")
            check(td.value("fontSize", for: .text, default: 24) == 40, "tamanho do texto não persistiu")
            let c = td.style(for: .callout)
            check(c.fillHex == "#FFEEAA" && c.colorHex == "#FF8800" && td.value("fontSize", for: .callout, default: 24) == 31, "balão não persistiu")
            check(td.style(for: .rect).text.size == 27, "tamanho do texto do retângulo não persistiu")
            let st = td.style(for: .step)
            check(st.stepFormat == .romanUpper && st.text.colorHex == "#FFD60A" && st.text.fontName == "Menlo", "etapa não persistiu")
            let h = td.style(for: .highlight)
            check(h.colorHex == "#FF00FF" && h.opacity == 0.6, "marcador não persistiu")
            check(td.value("pixelSize", for: .blur, default: 12) == 33 && td.value("intensity", for: .gaussian, default: 8) == 21, "pixelização/blur não persistiram")
            check(td.style(for: .ellipse) == Tool.ellipse.initialStyle, "uma ferramenta nunca usada devia ter o estilo inicial")

            // vale para QUALQUER captura aberta depois (não só a que se editou)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                CaptureStore.overrideFolder = dir
                let other = try EditorModel(url: try CaptureStore.save(image(300, 200, .systemOrange, .systemRed, label: "outra")))
                other.tool = .arrow
                check(other.style.colorHex == "#00AA55" && other.style.lineWidth == 9, "a seta não herdou o padrão numa captura nova")
                other.tool = .callout
                check(other.defaultFontSize == 31, "o balão não herdou o tamanho da letra")
                other.tool = .text
                let id = other.addAnnotation(.textBox(origin: Point(x: 5, y: 5), width: 100, height: 40, string: "x", fontSize: other.defaultFontSize))
                check(other.doc.annotations.first { $0.id == id }?.style.text.fontName == "Georgia", "um texto novo não nasceu com o último formato")
            } catch { fails.append("erro: \(error)") }

            // repõe o que havia antes do teste
            if let b = defaults.data(forKey: backupKey) { defaults.set(b, forKey: "toolDefaults.v1") } else { defaults.removeObject(forKey: "toolDefaults.v1") }
            defaults.removeObject(forKey: backupKey)
            print("DEFAULTS-SELFTEST[verify]: \(fails.isEmpty ? "OK" : "FALHOU")")
        }
        return fails
    }

    // MARK: Idioma

    private static let langBackupKey = "appLanguage.selftest.backup"

    /// Fase `check`: traduções completas e coerentes, nos dois idiomas.
    /// Fases `write`/`verify` (2 execuções): a escolha de idioma sobrevive a fechar a app.
    static func languageSelfTest(phase: String) -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { fails.append(what) } }
        let defaults = UserDefaults.standard
        let loc = Localizer.shared
        switch phase {
        case "check":
            let saved = Localizer.effective
            defer { Localizer.effective = saved }
            Localizer.effective = "en"
            check(L("Capturar") == "Capture" && L("Preferências") == "Preferences", "tradução básica para inglês falhou")
            check(L("Próxima etapa: %@", "III") == "Next step: III", "formatação com %@ falhou")
            check(L("Número desta etapa: %d", 7) == "This step's number: 7", "formatação com %d falhou")
            check(L("texto sem tradução") == "texto sem tradução", "texto sem tradução devia ficar como está")
            for (k, v) in Translations.en {
                check(L(k) == v || k.contains("%"), "L(\(k)) não devolve a tradução")
                check((k.components(separatedBy: "%@").count + k.components(separatedBy: "%d").count) == (v.components(separatedBy: "%@").count + v.components(separatedBy: "%d").count), "marcadores diferentes em «\(k)»")
                check(!v.isEmpty, "tradução vazia de «\(k)»")
            }
            Localizer.effective = "pt"
            check(L("Capturar") == "Capturar" && L("Próxima etapa: %@", "III") == "Próxima etapa: III", "em português devia devolver o original")
            for t in Tool.allCases { Localizer.effective = "en"; check(L(t.title) != "" && !t.title.contains("Mover") , "ferramenta \(t.rawValue) sem tradução (\(t.title))") }
            check(Localizer.resolve(.pt) == "pt" && Localizer.resolve(.en) == "en", "resolve falhou")
            print("LANGUAGE-SELFTEST[check]: \(Translations.en.count) traduções conferidas")
        case "write":
            if let v = defaults.string(forKey: "appLanguage") { defaults.set(v, forKey: langBackupKey) } else { defaults.removeObject(forKey: langBackupKey) }
            loc.set(.en)
            check(Localizer.effective == "en" && loc.language == .en, "set(.en) não mudou o idioma")
            print("LANGUAGE-SELFTEST[write]: idioma = en")
        default:   // verify
            check(loc.language == .en && Localizer.effective == "en", "o idioma não persistiu (\(loc.language), \(Localizer.effective))")
            check(L("Abrir") == "Open", "L() não usa o idioma guardado")
            if let b = defaults.string(forKey: langBackupKey) { defaults.set(b, forKey: "appLanguage") } else { defaults.removeObject(forKey: "appLanguage") }
            defaults.removeObject(forKey: langBackupKey)
            print("LANGUAGE-SELFTEST[verify]: idioma lido das preferências = en")
        }
        return fails
    }

    /// Desenha a janela principal para uma imagem (sem tocar no ecrã), no idioma efetivo.
    static func renderMain(to path: String, capture: URL, select: Int?, size: NSSize = NSSize(width: 1360, height: 820), panelHidden: Bool = false,
                           clicks: [(Double, Double)] = [], toolScroll: [Double] = []) {
        PanelLayout.shared.setWidthForTests(panelHidden ? 0 : PanelLayout.defaultWidth)
        let state = AppState.shared
        if capture.lastPathComponent != "none" { state.open(capture) }   // "none": ecrã vazio (sem captura aberta)
        if let n = select, let m = state.model, m.doc.ordered.indices.contains(n) { m.selection = m.doc.ordered[n].id; m.tool = .select }
        let host = NSHostingView(rootView: MainView(state: state))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        // Janela de verdade (para o SwiftUI correr o ciclo normal de desenho e medidas), mas longe de qualquer ecrã.
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.makeKeyAndOrderFront(nil)
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))   // deixa carregar as miniaturas e as medidas
            host.layoutSubtreeIfNeeded()
        }
        settle()
        // Cliques de rato (x, y a partir do topo esquerdo do conteúdo), entregues à janela virtual.
        for (x, y) in clicks {
            let p = host.convert(NSPoint(x: x, y: size.height - y), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.sendEvent(e) }
                RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            }
            settle()
        }
        // Deslize das ferramentas chamado diretamente (a mesma função que as setas e a roda usam).
        for dx in toolScroll { ToolsScroll.current?.scroll(by: CGFloat(dx)); settle() }
        host.display()   // 1.ª passagem: aplica as medidas (preferências) ao estado
        settle()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        window.orderOut(nil)
    }

    // MARK: Captura de demonstração (imagens do README)

    /// Cria uma captura sintética (uma "janela de app" desenhada aqui, sem conteúdo real) com exemplos das ferramentas.
    @discardableResult
    static func makeShowcase(_ dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        CaptureStore.overrideFolder = dir
        let w = 1280, h = 800
        let base = NSImage(size: NSSize(width: w, height: h), flipped: true) { r in
            NSColor(white: 0.96, alpha: 1).setFill(); r.fill()
            NSColor(white: 0.88, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 1280, height: 54).fill()           // barra de título
            for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() { c.setFill(); NSBezierPath(ovalIn: NSRect(x: 20 + i * 24, y: 19, width: 16, height: 16)).fill() }
            NSColor(white: 0.91, alpha: 1).setFill(); NSRect(x: 0, y: 54, width: 260, height: 746).fill()           // barra lateral
            let label: (String, CGFloat, CGFloat, CGFloat, NSColor) -> Void = { t, x, y, size, color in
                (t as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color])
            }
            for (i, t) in ["Painel", "Clientes", "Faturas", "Definições"].enumerated() { label(t, 36, CGFloat(90 + i * 52), 20, NSColor(white: 0.25, alpha: 1)) }
            label("Novo cliente", 320, 84, 30, .black)
            for (i, t) in ["Nome", "Email", "Telefone"].enumerated() {
                label(t, 320, CGFloat(160 + i * 96), 16, NSColor(white: 0.4, alpha: 1))
                NSColor.white.setFill(); NSBezierPath(roundedRect: NSRect(x: 320, y: CGFloat(188 + i * 96), width: 520, height: 44), xRadius: 8, yRadius: 8).fill()
            }
            label("Maria Silva", 336, 198, 20, .black)
            label("maria.silva@exemplo.com", 336, 294, 20, .black)
            label("+351 900 000 000", 336, 390, 20, .black)
            NSColor.systemBlue.setFill(); NSBezierPath(roundedRect: NSRect(x: 320, y: 520, width: 200, height: 52), xRadius: 10, yRadius: 10).fill()
            label("Guardar", 378, 534, 22, .white)
            label("Os dados do cliente ficam guardados neste computador.", 320, 620, 18, NSColor(white: 0.45, alpha: 1))
            return true
        }
        guard let cg = base.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw CocoaError(.fileWriteUnknown) }
        let url = try CaptureStore.save(cg)
        let m = try EditorModel(url: url)
        func add(_ shape: CaptureCore.Shape, _ edit: (inout Style) -> Void = { _ in }, caption: String = "") {
            var st = Style(); edit(&st)
            let a = Annotation(z: (m.doc.annotations.map(\.z).max() ?? -1) + 1, shape: shape, style: st, caption: caption)
            m.perform { $0.insert(a) }
        }
        add(.gaussian(origin: Point(x: 322, y: 286), width: 300, height: 36, intensity: 9))                                   // ocultar o email
        add(.highlight(origin: Point(x: 316, y: 606), width: 540, height: 40)) { $0.colorHex = "#FFD60A"; $0.opacity = 0.45 }
        add(.arrow(from: Point(x: 880, y: 440), to: Point(x: 530, y: 540))) { $0.colorHex = "#FF3B30"; $0.lineWidth = 6; $0.shadow = true }
        add(.callout(origin: Point(x: 820, y: 360), width: 330, height: 84, tail: Point(x: 790, y: 470), string: "Clique em Guardar\npara terminar", fontSize: 24)) {
            $0.colorHex = "#FF9500"; $0.fillHex = "#FFF3B0"; $0.lineWidth = 4; $0.text = TextFormat(bold: true, align: .center, vAlign: .middle)
        }
        for (n, p) in [(1, Point(x: 20, y: 114)), (2, Point(x: 296, y: 210)), (3, Point(x: 296, y: 546))] {
            add(.step(center: p, number: n)) { $0.colorHex = "#0A84FF" }
        }
        add(.rect(origin: Point(x: 880, y: 150), width: 340, height: 150), { $0.colorHex = "#34C759"; $0.fillHex = "#E7F9EC"; $0.text = TextFormat(align: .left, vAlign: .middle, list: .numbered); $0.text.size = 24 },
            caption: "Escolha o cliente\nPreencha os dados\nGuarde")
        return url
    }

    // MARK: Efeitos sobre camadas

    /// Blur e Pixelização têm de atuar sobre os objetos que estão por baixo deles (e só sobre esses).
    static func effectsSelfTest() -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { fails.append(what) } }
        let base = image(500, 240, .lightGray, .lightGray, label: "")

        enum Effect { case none, gaussian, pixelate }
        /// `above`: o efeito é inserido depois do texto (fica por cima); senão, antes (fica por baixo).
        func render(_ effect: Effect, above: Bool, hidden: Bool = false) -> NSBitmapImageRep? {
            var doc = CaptureDocument(canvasWidth: 500, canvasHeight: 240)
            func addEffect() {
                let shape: CaptureCore.Shape = effect == .gaussian
                    ? .gaussian(origin: Point(x: 30, y: 50), width: 440, height: 120, intensity: 10)
                    : .blur(origin: Point(x: 30, y: 50), width: 440, height: 120, radius: 14)
                let a = doc.add(shape)
                if hidden { doc.setVisible(id: a.id, false) }
            }
            if effect != .none && !above { addEffect() }
            var st = Style(lineVisible: false); st.text = TextFormat(bold: true, colorHex: "#000000")
            doc.add(.textBox(origin: Point(x: 40, y: 60), width: 420, height: 100, string: "WWWW", fontSize: 64), style: st)
            if effect != .none && above { addEffect() }
            guard let png = Renderer.png(doc, base: base) else { return nil }
            return NSBitmapImageRep(data: png)
        }
        func luma(_ r: NSBitmapImageRep, _ x: Int, _ y: Int) -> Double { Double(r.colorAt(x: x, y: y)?.brightnessComponent ?? 0) }
        /// "Nitidez" da zona do texto: soma das diferenças entre pixels vizinhos.
        func sharpness(_ r: NSBitmapImageRep) -> Double {
            var t = 0.0
            for y in stride(from: 60, to: 160, by: 2) { for x in 40..<460 { t += abs(luma(r, x + 1, y) - luma(r, x, y)) } }
            return t
        }
        func meanDiff(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Double {
            var t = 0.0, n = 0.0
            for y in stride(from: 50, to: 170, by: 3) { for x in stride(from: 30, to: 470, by: 3) { t += abs(luma(a, x, y) - luma(b, x, y)); n += 1 } }
            return t / n
        }
        guard let plain = render(.none, above: true), let blurAbove = render(.gaussian, above: true), let blurBelow = render(.gaussian, above: false),
              let pixAbove = render(.pixelate, above: true), let pixBelow = render(.pixelate, above: false),
              let hiddenFx = render(.gaussian, above: true, hidden: true) else { return ["não foi possível desenhar os casos"] }

        let s0 = sharpness(plain)
        let sBlur = sharpness(blurAbove)
        print("EFFECTS-SELFTEST: nitidez sem efeito \(Int(s0)) | blur por cima \(Int(sBlur)) | blur por baixo \(Int(sharpness(blurBelow)))")
        check(s0 > 50, "o texto de teste devia ter contraste (nitidez \(s0))")
        check(sBlur < s0 * 0.45, "blur POR CIMA do texto devia desfocá-lo (\(Int(sBlur)) vs \(Int(s0)))")
        check(meanDiff(blurBelow, plain) < 0.004, "blur POR BAIXO do texto não devia mexer no texto (diferença \(meanDiff(blurBelow, plain)))")
        check(meanDiff(pixAbove, plain) > 0.02, "pixelização POR CIMA do texto devia alterá-lo (diferença \(meanDiff(pixAbove, plain)))")
        // (o filtro altera ~1% o tom do fundo liso por gestão de cor; o que importa é o texto continuar nítido)
        let sPixBelow = sharpness(pixBelow), sPixAbove = sharpness(pixAbove)
        print("EFFECTS-SELFTEST: nitidez pixelização por cima \(Int(sPixAbove)) | por baixo \(Int(sPixBelow))")
        check(abs(sPixBelow - s0) / s0 < 0.03, "pixelização POR BAIXO do texto não devia mexer no texto (nitidez \(Int(sPixBelow)) vs \(Int(s0)))")
        check(abs(sPixAbove - s0) / s0 > 0.15, "pixelização POR CIMA devia mudar a nitidez do texto (\(Int(sPixAbove)) vs \(Int(s0)))")
        check(meanDiff(hiddenFx, plain) < 0.004, "efeito oculto não devia ter efeito")
        // fora da região do efeito, nada muda
        check(abs(luma(blurAbove, 5, 5) - luma(plain, 5, 5)) < 0.01 && abs(luma(blurAbove, 495, 235) - luma(plain, 495, 235)) < 0.01, "o efeito alterou pixels fora da sua região")
        return fails
    }

    // MARK: Seleção pelo rato

    /// Clique sobre objeto existente com uma ferramenta de desenho ativa: seleciona-o; arrastar continua a desenhar.
    static func selectionSelfTest(dir: URL) -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { fails.append(what) } }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        CaptureStore.overrideFolder = dir
        let state = AppState.shared
        if let e = state.createBlankImage(width: 800, height: 500, backgroundHex: "#FFFFFF", transparent: false) { return ["não criou a imagem: \(e)"] }
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))   // layout do editor
        guard let m = state.model, let canvas = CanvasView.current else { return ["sem editor"] }
        m.zoomFit()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        var idA = UUID(), idB = UUID()
        m.perform { idA = $0.add(.rect(origin: Point(x: 100, y: 100), width: 200, height: 120)).id; idB = $0.add(.rect(origin: Point(x: 450, y: 100), width: 200, height: 120)).id }
        let inA = Point(x: 200, y: 160), inB = Point(x: 550, y: 160), empty = Point(x: 400, y: 400)
        func count() -> Int { m.doc.annotations.count }

        // 1) seta ativa, clique dentro de A -> seleciona A, passa a Mover, não cria nada
        m.tool = .arrow; m.selection = nil
        let n0 = count()
        canvas.debugMouse(at: inA)
        check(m.selection == idA, "clique sobre A com a seta devia selecionar A")
        check(m.tool == .select, "depois de selecionar um objeto existente a ferramenta devia ser Mover (é \(m.tool))")
        check(count() == n0, "o clique não devia criar objetos (\(count()) vs \(n0))")
        check(m.selected?.shape.kindName == "Retângulo", "as opções atuais devem ser as do retângulo selecionado")

        // 2) arrastar a partir de dentro de A continua a desenhar uma seta nova
        m.tool = .arrow; m.selection = nil
        canvas.debugMouse(at: Point(x: 150, y: 140), dragTo: Point(x: 380, y: 300))
        check(count() == n0 + 1, "arrastar sobre A devia criar uma seta (\(count()) vs \(n0 + 1))")
        check(m.tool == .arrow, "criar por arrasto mantém a ferramenta")
        if case .arrow? = m.selected?.shape {} else { fails.append("o objeto novo devia ser uma seta") }

        // 3) recém-inserido; clicar noutro objeto existente (B) com a ferramenta de desenho ainda ativa -> passa para B
        m.tool = .rect
        canvas.debugMouse(at: Point(x: 100, y: 300), dragTo: Point(x: 220, y: 380))      // insere um retângulo novo
        let afterNew = count()
        let newId = m.selection
        canvas.debugMouse(at: inB)                                                      // clica por cima de B
        check(m.selection == idB && m.selection != newId, "clicar noutro objeto devia passar a seleção para ele")
        check(m.tool == .select, "a ferramenta devia passar a Mover")
        check(count() == afterNew, "o clique em B não devia criar objetos")

        // 4) clique em espaço vazio com a seta: não cria nada, nada fica selecionado
        m.tool = .arrow; m.selection = nil
        let n1 = count()
        canvas.debugMouse(at: empty)
        check(count() == n1 && m.selection == nil, "clique no vazio não devia criar nem selecionar")

        // 5) etapa: clique sobre objeto seleciona; ⌥ + clique cria a etapa por cima
        m.tool = .step; m.selection = nil
        let n2 = count()
        canvas.debugMouse(at: inA)
        check(m.selection == idA && count() == n2 && m.tool == .select, "a etapa sobre um objeto devia selecioná-lo")
        m.tool = .step; m.selection = nil
        canvas.debugMouse(at: inA, option: true)
        check(count() == n2 + 1 && m.selected?.shape.stepNumber != nil, "⌥+clique devia criar a etapa por cima do objeto")
        check(m.tool == .step, "criar a etapa mantém a ferramenta")

        // 6) balão: clique sobre objeto existente seleciona-o (não abre o editor de texto); no vazio cria o balão
        m.tool = .callout; m.selection = nil
        let n3 = count()
        canvas.debugMouse(at: inB)
        check(m.selection == idB && count() == n3, "o balão sobre um objeto devia selecioná-lo")
        m.tool = .callout; m.selection = nil
        canvas.debugMouse(at: Point(x: 650, y: 420))
        check(count() == n3 + 1, "o balão no vazio devia criar-se (\(count()) vs \(n3 + 1))")
        if case let .callout(_, _, _, tail, _, _)? = m.selected?.shape {
            check(abs(tail.x - 650) < 1 && abs(tail.y - 420) < 1, "a ponta do balão devia ficar no ponto do clique (\(tail))")
        } else { fails.append("o objeto novo devia ser um balão") }
        // sem escrever nada: ao clicar fora, o balão vazio continua lá
        m.tool = .select
        canvas.debugMouse(at: Point(x: 60, y: 460))
        check(count() == n3 + 1, "um balão sem texto não devia desaparecer (\(count()) vs \(n3 + 1))")

        // 7) Tela: clicar fora da área confirma (volta a Mover)
        m.tool = .canvas
        canvas.debugMouse(at: Point(x: 2000, y: 2000))
        check(m.tool == .select, "clicar fora da área da Tela devia confirmar (ferramenta \(m.tool))")
        return fails
    }

    // MARK: Dock e menus

    static func dockSelfTest(delegate: AppDelegate) -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { fails.append(what) } }
        check(NSApp.activationPolicy() == .regular, "a app devia ter ícone no Dock (política \(NSApp.activationPolicy().rawValue))")
        check(MainWindow.isVisible, "o editor devia abrir ao arrancar")
        check(NSApp.applicationIconImage != nil && (NSApp.applicationIconImage?.size.width ?? 0) > 0, "sem ícone da aplicação")
        // fechar a janela não tira a app do Dock; clicar no ícone volta a abrir o editor
        MainWindow.closeForTests()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        check(!MainWindow.isVisible, "a janela devia ter fechado")
        check(NSApp.activationPolicy() == .regular, "fechar a janela não devia tirar o ícone do Dock")
        _ = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        check(MainWindow.isVisible, "clicar no ícone do Dock devia abrir o editor")
        // menu principal
        let titles = NSApp.mainMenu?.items.map { $0.title } ?? []
        check(titles.count == 5, "menu principal devia ter 5 menus (tem \(titles))")
        let edit = NSApp.mainMenu?.items.first { $0.submenu?.items.contains { $0.keyEquivalent == "v" } == true }
        check(edit != nil, "falta o menu Editar com Colar")
        check(edit?.submenu?.items.contains { $0.keyEquivalent == "z" } == true, "falta Desfazer no menu Editar")
        let file = NSApp.mainMenu?.items.first { $0.submenu?.items.contains { $0.keyEquivalent == "n" } == true }
        check(file != nil, "falta Nova imagem no menu Ficheiro")
        print("DOCK-SELFTEST: menus = \(titles.joined(separator: ", "))")
        return fails
    }

    // MARK: Imagem nova

    /// Bytes reais do pixel (sRGB, alfa não pré-multiplicado), desenhando-o num contexto de 1×1.
    static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int)? {
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setBlendMode(.copy)
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        let a = Int(bytes[3])
        func un(_ v: UInt8) -> Int { a == 0 ? 0 : min(255, Int((Double(v) * 255 / Double(a)).rounded())) }
        return (un(bytes[0]), un(bytes[1]), un(bytes[2]), a)
    }

    static func newImageSelfTest(dir: URL) -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { fails.append(what) } }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        CaptureStore.overrideFolder = dir
        let state = AppState.shared

        // do zero: tamanho e cor
        check(state.createBlankImage(width: 640, height: 360, backgroundHex: "#336699", transparent: false) == nil, "criar imagem em branco falhou")
        if let m = state.model {
            check(m.base.width == 640 && m.base.height == 360, "tamanho errado (\(m.base.width)×\(m.base.height))")
            let px = pixel(m.base, 10, 10)
            check(px != nil && abs((px?.r ?? 0) - 0x33) <= 2 && abs((px?.g ?? 0) - 0x66) <= 2 && abs((px?.b ?? 0) - 0x99) <= 2 && px?.a == 255,
                  "cor de fundo errada (esperava 33 66 99, lido \(String(describing: px)))")
            check(m.doc.backgroundHex == "#336699" && !m.doc.transparentBackground, "o fundo não ficou guardado no documento")
            // e é um documento normal: dá para anotar e a área de trabalho expande-se com a cor escolhida
            m.tool = .rect; _ = m.addAnnotation(.rect(origin: Point(x: 600, y: 300), width: 100, height: 100))
            check(m.doc.area.width >= 640, "a área devia poder expandir")
        } else { fails.append("a imagem nova não abriu no editor") }

        // transparente
        check(state.createBlankImage(width: 200, height: 100, backgroundHex: "#FFFFFF", transparent: true) == nil, "criar transparente falhou")
        if let m = state.model {
            check(pixel(m.base, 50, 50)?.a == 0, "a imagem transparente devia ter alfa 0 (lido \(String(describing: pixel(m.base, 50, 50))))")
            check(m.doc.transparentBackground, "devia ficar marcado como fundo transparente")
        }

        // limites
        check(state.createBlankImage(width: 0, height: 100, backgroundHex: "#FFFFFF", transparent: false) != nil, "largura 0 devia ser recusada")
        check(state.createBlankImage(width: 20000, height: 100, backgroundHex: "#FFFFFF", transparent: false) != nil, "20000 px devia ser recusado")
        check(state.createBlankImage(width: 16384, height: 16384, backgroundHex: "#FFFFFF", transparent: false) != nil, "mais de 100 milhões de pixels devia ser recusado")

        // da área de transferência (repõe a do utilizador no fim)
        let pb = NSPasteboard.general
        let saved: [[(NSPasteboard.PasteboardType, Data)]] = (pb.pasteboardItems ?? []).map { item in item.types.compactMap { t in item.data(forType: t).map { (t, $0) } } }
        defer {
            pb.clearContents()
            let items = saved.map { entries -> NSPasteboardItem in let i = NSPasteboardItem(); for (t, d) in entries { i.setData(d, forType: t) }; return i }
            if !items.isEmpty { pb.writeObjects(items) }
        }
        pb.clearContents(); pb.setString("só texto", forType: .string)
        state.errorMessage = nil
        state.pasteAsNewCapture()
        check(state.errorMessage != nil, "sem imagem na área de transferência devia dar erro")

        let src = NSImage(size: NSSize(width: 120, height: 80), flipped: false) { r in NSColor.red.withAlphaComponent(0.5).setFill(); r.fill(); return true }
        if let tiff = src.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            pb.clearContents(); pb.setData(png, forType: .png)
            state.errorMessage = nil
            state.pasteAsNewCapture()
            check(state.errorMessage == nil, "colar imagem como nova falhou: \(state.errorMessage ?? "")")
            if let m = state.model {
                check(m.base.width == 120 && m.base.height == 80, "a imagem colada devia ter 120×80 (tem \(m.base.width)×\(m.base.height))")
                let a = pixel(m.base, 10, 10)?.a ?? 255
                check(a > 110 && a < 145, "a transparência da imagem colada devia manter-se (alfa \(a) de 255, esperava ~128)")
            }
        } else { fails.append("sem PNG de teste") }
        return fails
    }

    /// Desenha o diálogo "Imagem em branco" para uma imagem (sem tocar no ecrã).
    static func renderNewImageSheet(to path: String) {
        // Teste: nunca escreve na biblioteca real (o botão "Criar" é o botão por omissão do diálogo).
        CaptureStore.overrideFolder = FileManager.default.temporaryDirectory.appendingPathComponent("toth-render-newimage-\(UUID().uuidString)")
        let host = NSHostingView(rootView: NewImageSheet(state: AppState.shared))
        host.frame = NSRect(x: 0, y: 0, width: 460, height: 290)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    // MARK: Abrir imagens de qualquer sítio, nomes e formatos de gravação

    static func openFilesSelfTest(dir: URL) -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { fails.append(what) } }
        let fm = FileManager.default
        let lib = dir.appendingPathComponent("lib"), src = dir.appendingPathComponent("origem")
        try? fm.createDirectory(at: lib, withIntermediateDirectories: true)
        try? fm.createDirectory(at: src, withIntermediateDirectories: true)
        CaptureStore.overrideFolder = lib

        // ficheiros de origem em sítios "quaisquer": PNG, JPEG com etiqueta de orientação EXIF (rodado 90°) e TIFF
        let base = image(200, 100, .systemTeal, .systemIndigo, label: "origem")
        let png = src.appendingPathComponent("foto com espaços.png")
        try? NSBitmapImageRep(cgImage: base).representation(using: .png, properties: [:])?.write(to: png)
        let jpg = src.appendingPathComponent("telemóvel.jpg")
        let out = NSMutableData()
        if let d = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) {
            CGImageDestinationAddImage(d, base, [kCGImagePropertyOrientation: 6] as CFDictionary)   // 6 = rodar 90° para a direita
            CGImageDestinationFinalize(d)
            try? (out as Data).write(to: jpg)
        }
        let tif = src.appendingPathComponent("digitalização.tiff")
        try? NSBitmapImageRep(cgImage: base).representation(using: .tiff, properties: [:])?.write(to: tif)
        let notImage = src.appendingPathComponent("notas.txt")
        try? "não sou uma imagem".write(to: notImage, atomically: true, encoding: .utf8)
        let before = [png, jpg, tif].map { try? Data(contentsOf: $0) }

        let state = AppState.shared
        state.errorMessage = nil
        state.open(urls: [png, jpg, tif])
        state.refreshLibrary()
        check(state.errorMessage == nil, "abrir imagens válidas não devia dar erro: \(state.errorMessage ?? "")")
        check(state.library.count == 3, "cada imagem devia virar uma captura (biblioteca tem \(state.library.count))")
        check(state.model != nil, "devia ficar uma captura aberta no editor")

        // tamanhos (a orientação EXIF tem de ser aplicada: o JPEG 200×100 "rodado" abre como 100×200)
        var sizes: [String] = []
        for item in state.library { if let m = try? EditorModel(url: item.url) { sizes.append("\(m.base.width)x\(m.base.height)") } }
        check(sizes.sorted() == ["100x200", "200x100", "200x100"], "tamanhos inesperados: \(sizes.sorted()) (esperava 100x200, 200x100, 200x100)")

        // os originais não são tocados
        check([png, jpg, tif].map { try? Data(contentsOf: $0) } == before, "os ficheiros originais foram alterados")

        // nomes sem espaços
        let pattern = try! NSRegularExpression(pattern: "^Toth_\\d{4}-\\d{2}-\\d{2}_\\d{2}\\.\\d{2}\\.\\d{2}(_\\d+)?\\.capture$")
        for item in state.library {
            let n = item.url.lastPathComponent
            check(!n.contains(" "), "o nome «\(n)» tem espaços")
            check(pattern.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)) != nil, "o nome «\(n)» não segue o padrão Toth_AAAA-MM-DD_HH.MM.SS[_n].capture")
        }

        // um ficheiro que não é imagem dá erro e não cria nada
        state.errorMessage = nil
        state.open(urls: [notImage])
        state.refreshLibrary()
        check(state.errorMessage != nil && state.library.count == 3, "um ficheiro que não é imagem devia dar erro sem criar captura")

        // abrir uma captura existente por URL (como no duplo clique do Finder)
        state.errorMessage = nil
        if let first = state.library.first {
            state.open(urls: [first.url])
            check(state.model?.url == first.url, "abrir um .capture por URL devia abri-lo no editor")
        }

        // título legível na biblioteca: nomes novos e antigos (com espaços) mostram a mesma data
        let novo = LibraryNames.title(forFileName: "Toth_2026-10-15_17.43.28")
        check(novo != "Toth_2026-10-15_17.43.28" && novo.contains("2026"), "nome novo sem título legível: \(novo)")
        check(LibraryNames.title(forFileName: "Toth_2026-10-15_17.43.28_2") == novo, "o sufixo _2 devia dar a mesma data")
        check(LibraryNames.title(forFileName: "Toth 2026-10-15 17.43.28") == novo, "nome antigo «Toth …» devia dar a mesma data")
        check(LibraryNames.title(forFileName: "Capture 2026-10-15 17.43.28 (2)") == novo, "nome antigo «Capture …» devia dar a mesma data")
        check(LibraryNames.title(forFileName: "minha_foto") == "minha_foto", "um nome que não é de captura fica como está")

        // formatos de gravação
        guard let transparent = {
            let ctx = CGContext(data: nil, width: 60, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(NSColor.red.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 30, height: 40))   // metade esquerda vermelha, resto transparente
            return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])
        }() else { return fails + ["sem PNG de teste"] }
        func load(_ d: Data) -> CGImage? { CGImageSourceCreateWithData(d as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } }
        for f in ImageFiles.Format.allCases {
            guard let data = ImageFiles.encode(png: transparent, as: f), let img = load(data) else { fails.append("exportar em \(f.title) falhou"); continue }
            check(img.width == 60 && img.height == 40, "\(f.title): tamanho \(img.width)×\(img.height)")
            let px = pixel(img, 50, 20)   // zona que era transparente
            switch f {
            case .jpeg: check(px.map { $0.r > 240 && $0.g > 240 && $0.b > 240 } == true, "JPEG: o transparente devia passar a branco (lido \(String(describing: px)))")
            case .png, .tiff: check(px?.a == 0, "\(f.title): devia manter a transparência (lido \(String(describing: px)))")
            case .heic: break   // o HEIC pode ou não guardar alfa conforme o sistema
            }
            let magic = data.prefix(12).map { String(format: "%02x", $0) }.joined()
            switch f {
            case .png: check(magic.hasPrefix("89504e47"), "PNG: assinatura errada")
            case .jpeg: check(magic.hasPrefix("ffd8ff"), "JPEG: assinatura errada")
            case .tiff: check(magic.hasPrefix("49492a00") || magic.hasPrefix("4d4d002a"), "TIFF: assinatura errada")
            case .heic: check(magic.contains("66747970"), "HEIC: assinatura (ftyp) errada")
            }
        }
        return fails
    }

    // MARK: Etapas: tamanho e centragem

    private static func rgba(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    static func stepsSelfTest(dir: URL) -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { fails.append(what) } }

        // 1) O número/letra tem de ficar centrado no círculo, para qualquer tamanho e tipo de etiqueta.
        let size = 520, c = Double(size) / 2
        let base = image(size, size, .white, .white, label: "")
        struct Case { let label: StepFormat; let n: Int; let name: String; let lower: Bool }
        let cases: [Case] = [
            Case(label: .arabic, n: 1, name: "1", lower: false), Case(label: .arabic, n: 7, name: "7", lower: false),
            Case(label: .arabic, n: 10, name: "10", lower: false), Case(label: .arabic, n: 18, name: "18", lower: false),
            Case(label: .romanUpper, n: 4, name: "IV", lower: false), Case(label: .romanUpper, n: 18, name: "XVIII", lower: false),
            Case(label: .alphaUpper, n: 1, name: "A", lower: false), Case(label: .alphaUpper, n: 13, name: "M", lower: false),
            Case(label: .romanLower, n: 3, name: "iii", lower: true), Case(label: .alphaLower, n: 1, name: "a", lower: true),
            Case(label: .alphaLower, n: 3, name: "c", lower: true),
        ]
        var heightRatios: [Double] = []
        for radius in [10.0, 16.0, 24.0, 48.0, 100.0] {
            for k in cases {
                var doc = CaptureDocument(canvasWidth: Double(size), canvasHeight: Double(size))
                var st = Style(colorHex: "#0A84FF"); st.stepFormat = k.label
                doc.add(.step(center: Point(x: c, y: c), number: k.n, radius: radius), style: st)
                guard let png = Renderer.png(doc, base: base), let src = CGImageSourceCreateWithData(png as CFData, nil),
                      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fails.append("não desenhou r=\(radius) \(k.name)"); continue }
                let px = rgba(img)
                var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
                let y0 = Int(c - radius) - 1, y1 = Int(c + radius) + 1
                for y in y0...y1 { for x in y0...y1 {
                    let o = (y * img.width + x) * 4
                    // pixel "do texto": claro, dentro do círculo (o fundo e o contorno anti-serrilhado ficam de fora)
                    guard px[o] > 215, px[o + 1] > 215, px[o + 2] > 215, hypot(Double(x) + 0.5 - c, Double(y) + 0.5 - c) < radius * 0.92 else { continue }
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                } }
                guard maxX >= 0 else { fails.append("sem texto visível r=\(radius) \(k.name)"); continue }
                let cx = Double(minX + maxX + 1) / 2, cy = Double(minY + maxY + 1) / 2
                let w = Double(maxX - minX + 1), h = Double(maxY - minY + 1)
                let tol = 0.9 + radius * 0.035 + (radius < 14 ? 1.3 : 0)   // texto de ~6 px: o contorno anti-serrilhado pesa mais
                // horizontal: centro da tinta; vertical: centro da altura de maiúsculas/dígitos (minúsculas: tolerância maior)
                check(abs(cx - c) <= tol, "r=\(Int(radius)) «\(k.name)»: horizontalmente descentrado \(String(format: "%.1f", cx - c)) px (tol \(String(format: "%.1f", tol)))")
                check(abs(cy - c) <= tol, "r=\(Int(radius)) «\(k.name)»: verticalmente descentrado \(String(format: "%.1f", cy - c)) px (tol \(String(format: "%.1f", tol)))")
                // cabe sempre dentro do círculo e ocupa no máximo ~75% do diâmetro em largura
                check(w <= radius * 1.6, "r=\(Int(radius)) «\(k.name)»: largura \(Int(w)) excede 80% do diâmetro")
                if k.name == "7" || k.name == "1" { heightRatios.append(h / radius) }
            }
        }
        // escala: a altura do dígito é proporcional ao raio (a mesma razão em todos os tamanhos, ±12%)
        if let lo = heightRatios.min(), let hi = heightRatios.max() {
            check(hi / lo < 1.35, "o número não escala em proporção ao raio (razão altura/raio entre \(String(format: "%.2f", lo)) e \(String(format: "%.2f", hi)))")
            check(lo > 0.5, "o número ficou pequeno demais (altura/raio \(String(format: "%.2f", lo)))")
        }

        // 2) Redimensionar com o rato (alças): proporção mantida, canto oposto fixo, tamanho lembrado.
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        CaptureStore.overrideFolder = dir
        let state = AppState.shared
        if let e = state.createBlankImage(width: 900, height: 600, backgroundHex: "#FFFFFF", transparent: false) { return fails + ["sem imagem: \(e)"] }
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        guard let m = state.model, let canvas = CanvasView.current else { return fails + ["sem editor"] }
        m.zoomFit(); RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        ToolDefaults.shared.setValue(Shape.defaultStepRadius, "stepRadius", for: .step)

        m.tool = .step
        m.addStep(at: Point(x: 300, y: 250))
        guard let id = m.selection, let before = m.selected?.shape else { return fails + ["a etapa não foi criada"] }
        check(before.stepRadius == 16, "etapa nova devia ter o raio padrão (16), tem \(String(describing: before.stepRadius))")
        let fixedCorner = before.handles[0]                        // canto superior esquerdo: fica fixo ao arrastar o inferior direito
        m.tool = .select
        let handle = before.handles[2]
        canvas.debugMouse(at: handle, dragTo: Point(x: handle.x + 60, y: handle.y + 24))
        guard let after = m.doc.annotations.first(where: { $0.id == id })?.shape else { return fails + ["a etapa desapareceu"] }
        let b = after.bounds
        check(abs(b.width - b.height) < 0.01, "a etapa deixou de ser circular (\(b.width)×\(b.height))")
        check(abs(b.minX - fixedCorner.x) < 0.5 && abs(b.minY - fixedCorner.y) < 0.5, "o canto oposto devia ficar fixo (agora em \(b.minX), \(b.minY); era \(fixedCorner.x), \(fixedCorner.y))")
        check((after.stepRadius ?? 0) > 30, "arrastar o canto devia aumentar o raio (raio \(String(describing: after.stepRadius)))")
        check(abs((after.stepRadius ?? 0) - (m.defaultStepRadius)) < 0.01, "o tamanho devia ficar como padrão das próximas etapas")
        m.tool = .step; m.selection = nil
        m.addStep(at: Point(x: 600, y: 250))
        check(abs((m.selected?.shape.stepRadius ?? 0) - (after.stepRadius ?? -1)) < 0.01, "a etapa seguinte devia nascer com o tamanho lembrado")
        // pelo painel
        m.setStepRadius(40)
        check(m.selected?.shape.stepRadius == 40, "o controlo de tamanho devia mudar a etapa selecionada")
        // desfazer repõe o tamanho anterior
        m.undo()
        check(m.selected?.shape.stepRadius != 40, "desfazer devia repor o tamanho anterior")
        ToolDefaults.shared.setValue(Shape.defaultStepRadius, "stepRadius", for: .step)   // não deixar o teste como padrão do utilizador
        return fails
    }

    /// Desenha etapas de vários tamanhos e formatos para uma imagem (conferência visual).
    static func renderSteps(to path: String) {
        let base = image(1100, 460, .white, .white, label: "")
        var doc = CaptureDocument(canvasWidth: 1100, canvasHeight: 460)
        let formats: [(StepFormat, String, [Int])] = [(.arabic, "#FF3B30", [1, 2, 7, 10, 18]), (.romanUpper, "#0A84FF", [1, 4, 9, 18, 38]),
                                                       (.alphaUpper, "#34C759", [1, 2, 13, 26, 27]), (.alphaLower, "#AF52DE", [1, 7, 16, 25, 3])]
        let radii: [Double] = [12, 16, 24, 38, 60]
        for (row, f) in formats.enumerated() {
            var x = 70.0
            for (i, n) in f.2.enumerated() {
                let r = radii[i]
                x += r
                var st = Style(colorHex: f.1); st.stepFormat = f.0
                doc.add(.step(center: Point(x: x, y: 70 + Double(row) * 105), number: n, radius: r), style: st)
                x += r + 40
            }
        }
        if let png = Renderer.png(doc, base: base) { try? png.write(to: URL(fileURLWithPath: path)) }
    }

    // MARK: Seta sem junção, pixelização sem faixas, ponteiro do balão

    static func shapesSelfTest() -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { fails.append(what) } }
        func render(_ doc: CaptureDocument, base: CGImage) -> (px: [UInt8], w: Int)? {
            guard let png = Renderer.png(doc, base: base), let src = CGImageSourceCreateWithData(png as CFData, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
            return (rgba(img), img.width)
        }

        // 1) Seta: ao longo do eixo (haste + junção + ponta) a cor tem de ser constante, mesmo com opacidade (uma sobreposição
        //    dupla ou uma junção deixariam uma faixa mais escura).
        let white = image(420, 320, .white, .white, label: "")
        let cases: [(name: String, from: Point, to: Point)] = [
            ("→ horizontal", Point(x: 40, y: 100), Point(x: 330, y: 100)),
            ("← horizontal", Point(x: 330, y: 100), Point(x: 40, y: 100)),
            ("↘ diagonal", Point(x: 50, y: 40), Point(x: 330, y: 260)),
            ("↑ vertical", Point(x: 200, y: 300), Point(x: 200, y: 30)),
        ]
        for lw in [4.0, 8.0, 14.0] {
            for c in cases {
                var doc = CaptureDocument(canvasWidth: 420, canvasHeight: 320)
                var st = Style(colorHex: "#0000FF", lineWidth: lw); st.opacity = 0.5
                doc.add(.arrow(from: c.from, to: c.to), style: st)
                guard let r = render(doc, base: white) else { fails.append("seta não desenhada"); continue }
                let head = max(14, lw * 4)
                let len = hypot(c.to.x - c.from.x, c.to.y - c.from.y)
                // amostras ao longo do eixo, da haste (após o extremo redondo) até pouco antes da ponta
                var values: [Int] = []
                var t = lw
                while t < len - head * 0.35 {
                    let x = c.from.x + (c.to.x - c.from.x) * t / len, y = c.from.y + (c.to.y - c.from.y) * t / len
                    values.append(Int(r.px[(Int(y) * r.w + Int(x)) * 4 + 1]))   // canal verde (em azul a 50% sobre branco = 128)
                    t += 1
                }
                if let lo = values.min(), let hi = values.max() {
                    check(hi - lo <= 2, "seta \(c.name) (espessura \(Int(lw))): a cor varia ao longo do eixo (\(lo)…\(hi)): há junção ou dupla sobreposição")
                    check(abs(Double(values[values.count / 2]) - 127.5) < 3, "seta \(c.name): opacidade errada (\(values[values.count / 2]))")
                } else { fails.append("sem amostras na seta") }
            }
        }

        // 2) Pixelização: as células têm de ter todas o mesmo tamanho (±1 px). Não pode sobrar uma faixa fina no topo.
        func gradient(_ angle: CGFloat) -> CGImage {
            let img = NSImage(size: NSSize(width: 320, height: 320), flipped: false) { rect in
                NSGradient(colors: [.white, .black])!.draw(in: rect, angle: angle); return true }
            return img.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        }
        func runs(_ values: [UInt32]) -> [Int] {
            var out: [Int] = []; var n = 0; var last: UInt32?
            for v in values { if v == last { n += 1 } else { if n > 0 { out.append(n) }; n = 1; last = v } }
            out.append(n); return out
        }
        for (axis, angle) in [("vertical", CGFloat(90)), ("horizontal", CGFloat(0))] {
            for (rw, rh, cell) in [(200.0, 77.0, 14.0), (150.0, 131.0, 12.0), (97.0, 61.0, 20.0)] {
                var doc = CaptureDocument(canvasWidth: 320, canvasHeight: 320)
                doc.add(.blur(origin: Point(x: 50, y: 40), width: rw, height: rh, radius: cell))
                guard let r = render(doc, base: gradient(angle)) else { fails.append("pixelização não desenhada"); continue }
                func px(_ x: Int, _ y: Int) -> UInt32 { let o = (y * r.w + x) * 4; return UInt32(r.px[o]) << 16 | UInt32(r.px[o + 1]) << 8 | UInt32(r.px[o + 2]) }
                let list = axis == "vertical" ? (40..<(40 + Int(rh))).map { px(50 + Int(rw) / 2, $0) } : (50..<(50 + Int(rw))).map { px($0, 40 + Int(rh) / 2) }
                let rs = runs(list)
                if let lo = rs.min(), let hi = rs.max() {
                    check(hi - lo <= 1, "pixelização \(axis) \(Int(rw))×\(Int(rh)) bloco \(Int(cell)): células de tamanhos diferentes \(rs) (há uma faixa fina)")
                    check(abs(rs.first! - hi) <= 1 && abs(rs.last! - hi) <= 1, "pixelização \(axis): a primeira/última célula é diferente das outras \(rs)")
                    let expected = Int((Double(axis == "vertical" ? rh : rw) / cell).rounded())
                    check(rs.count == expected, "pixelização \(axis): \(rs.count) células, esperava \(expected)")
                }
            }
        }

        // 3) Ponteiro do balão: segue o raio centro→ponta; desliza com continuidade e fica perto do centro.
        let box = CGRect(x: 100, y: 100, width: 220, height: 64)
        check(Renderer.calloutAnchor(box: box, tail: CGPoint(x: 200, y: 130)) == nil, "ponta dentro da caixa não devia ter ponteiro")
        var last: CGFloat?
        var lastSide: Renderer.CalloutSide?
        var maxStep: CGFloat = 0
        for x in stride(from: 150.0, through: 270.0, by: 1.0) {   // ponta bem abaixo, a deslizar 120 px na horizontal
            guard let a = Renderer.calloutAnchor(box: box, tail: CGPoint(x: x, y: 420)) else { fails.append("sem âncora"); break }
            check(a.side == .bottom, "ponta por baixo devia ligar-se à base")
            if let l = last { maxStep = max(maxStep, abs(a.coordinate - l)); check(a.coordinate >= l - 0.001, "o ponto de ligação devia mover-se no mesmo sentido da ponta") }
            last = a.coordinate; lastSide = a.side
        }
        _ = lastSide
        check(maxStep < 0.15, "o ponteiro devia deslizar devagar (a ponta anda 1 px, o ponto de ligação andou \(maxStep))")
        let near = Renderer.calloutAnchor(box: box, tail: CGPoint(x: 120, y: 420))!, far = Renderer.calloutAnchor(box: box, tail: CGPoint(x: 300, y: 420))!
        check(abs((far.coordinate - near.coordinate)) < 0.3 * 180, "a ligação devia mover-se bem menos que a ponta (ponta 180 px, ligação \(far.coordinate - near.coordinate))")
        check(abs(near.coordinate - box.midX) < 60 && abs(far.coordinate - box.midX) < 60, "a ligação devia ficar perto do centro da caixa")
        let left = Renderer.calloutAnchor(box: box, tail: CGPoint(x: -150, y: 140))!, right = Renderer.calloutAnchor(box: box, tail: CGPoint(x: 600, y: 120))!
        check(left.side == .left && right.side == .right, "pontas à esquerda/direita devem ligar-se aos lados")
        let path = Renderer.calloutPath(box, tail: CGPoint(x: 210, y: 300))
        check(path.boundingBoxOfPath.contains(CGPoint(x: 210, y: 300)) || path.boundingBoxOfPath.maxY >= 299, "o contorno devia chegar à ponta")
        return fails
    }

    /// Setas, pixelização e balões desenhados para uma imagem (conferência visual).
    static func renderShapes(to path: String) {
        let base = NSImage(size: NSSize(width: 1000, height: 560), flipped: true) { r in
            NSColor(white: 0.97, alpha: 1).setFill(); r.fill()
            for i in 0..<9 {
                ("Linha de texto de exemplo número \(i + 1) para ver a pixelização" as NSString).draw(at: NSPoint(x: 560, y: 40 + CGFloat(i) * 26),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 17), .foregroundColor: NSColor.black])
            }
            return true
        }.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        var doc = CaptureDocument(canvasWidth: 1000, canvasHeight: 560)
        func st(_ hex: String, _ w: Double, shadow: Bool = false, opacity: Double = 1) -> Style { var s = Style(colorHex: hex, lineWidth: w, shadow: shadow); s.opacity = opacity; return s }
        doc.add(.arrow(from: Point(x: 40, y: 60), to: Point(x: 460, y: 60)), style: st("#FF3B30", 6))
        doc.add(.arrow(from: Point(x: 40, y: 110), to: Point(x: 460, y: 150)), style: st("#FF3B30", 10, shadow: true))
        doc.add(.arrow(from: Point(x: 460, y: 200), to: Point(x: 40, y: 200)), style: st("#0A84FF", 12, opacity: 0.5))
        doc.add(.arrow(from: Point(x: 80, y: 260), to: Point(x: 300, y: 420)), style: st("#34C759", 18, shadow: true))
        doc.add(.blur(origin: Point(x: 555, y: 60), width: 380, height: 111, radius: 14))     // não é múltiplo do bloco
        var cs = st("#FF9500", 3); cs.fillHex = "#FFF3B0"; cs.text = TextFormat(align: .center, vAlign: .middle)
        for (i, tail) in [Point(x: 640, y: 400), Point(x: 740, y: 470), Point(x: 900, y: 420), Point(x: 520, y: 330), Point(x: 960, y: 330)].enumerated() {
            _ = i
            doc.add(.callout(origin: Point(x: 620, y: 300), width: 220, height: 64, tail: tail, string: "Ponteiro", fontSize: 18), style: cs)
        }
        if let png = Renderer.png(doc, base: base) { try? png.write(to: URL(fileURLWithPath: path)) }
    }

    // MARK: Layout da janela

    /// Desenha a janela principal ao tamanho `size` e devolve os píxeis (RGBA) e a largura.
    @MainActor private static func renderMainWindow(_ state: AppState, size: NSSize) -> (px: [UInt8], w: Int, h: Int)? {
        let host = NSHostingView(rootView: MainView(state: state))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let cg = rep.cgImage else { return nil }
        return (rgba(cg), cg.width, cg.height)
    }

    /// A área de trabalho não pode desenhar por cima da barra de ferramentas: numa janela pequena, com uma imagem enorme e
    /// ampliada (que transborda), a faixa da barra tem de ficar igual à de uma imagem pequena.
    static func layoutSelfTest(dir: URL) -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { fails.append(what) } }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        CaptureStore.overrideFolder = dir
        let state = AppState.shared
        let size = NSSize(width: 900, height: 520)

        // referência: imagem pequena (a área de trabalho não transborda)
        guard state.createBlankImage(width: 64, height: 64, backgroundHex: "#FFFFFF", transparent: false) == nil, let small = renderMainWindow(state, size: size) else { return ["sem referência"] }
        // imagem enorme, muito escura, ampliada: se a área de trabalho transbordar, escurece a barra
        guard state.createBlankImage(width: 3000, height: 2000, backgroundHex: "#101010", transparent: false) == nil, let m = state.model else { return fails + ["sem imagem grande"] }
        m.zoom = 3; m.pan = CGSize(width: 0, height: 0)
        guard let big = renderMainWindow(state, size: size) else { return fails + ["sem render da imagem grande"] }
        check(small.w == big.w && small.h == big.h, "tamanhos de render diferentes")

        // faixa da barra de ferramentas (topo) e faixa do rodapé/biblioteca (fundo): têm de ser iguais nos dois casos
        func differing(_ rows: Range<Int>, columns: [Range<Int>]? = nil) -> Double {
            var n = 0, total = 0
            for y in rows { for x in (columns ?? [0..<small.w]).flatMap({ Array($0) }) {
                let o = (y * small.w + x) * 4
                total += 1
                if abs(Int(small.px[o]) - Int(big.px[o])) > 8 || abs(Int(small.px[o + 1]) - Int(big.px[o + 1])) > 8 || abs(Int(small.px[o + 2]) - Int(big.px[o + 2])) > 8 { n += 1 }
            } }
            return Double(n) / Double(max(total, 1))
        }
        let top = differing(0..<58)
        // rodapé: só a linha do zoom, fora do texto central (a biblioteca de miniaturas e o texto de zoom mudam de propósito)
        let footerTop = small.h - 92 - 30
        let bottom = differing(footerTop..<(footerTop + 28), columns: [0..<260, 640..<small.w])
        print("LAYOUT-SELFTEST: píxeis da barra superior alterados pela imagem grande: \(String(format: "%.2f", top * 100))% | rodapé: \(String(format: "%.2f", bottom * 100))%")
        check(top < 0.01, "a área de trabalho desenha por cima da barra de ferramentas (\(String(format: "%.1f", top * 100))% dos píxeis da barra mudaram)")
        check(bottom < 0.01, "a área de trabalho desenha por cima do rodapé/biblioteca (\(String(format: "%.1f", bottom * 100))% dos píxeis mudaram)")
        return fails
    }

    // MARK: Painel de Propriedades

    static func panelSelfTest() -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { fails.append(what) } }
        let suite = "toth.selftest.panel"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let p = PanelLayout(defaults: defaults)
        check(p.width == PanelLayout.defaultWidth && p.isVisible, "o painel devia começar visível com a largura padrão (\(p.width))")

        // arrastar a divisória para a esquerda aumenta; para a direita diminui
        p.drag(translationX: -100); check(p.width == 370, "arrastar 100 px para a esquerda: 370 (é \(p.width))")
        p.drag(translationX: -1000); check(p.width == PanelLayout.maxWidth, "o máximo é \(PanelLayout.maxWidth) (é \(p.width))")
        p.endDrag()
        check(PanelLayout(defaults: defaults).width == PanelLayout.maxWidth, "a largura devia ficar guardada")

        // entre o limite de esconder e a largura mínima, fica na mínima
        p.drag(translationX: 520 - 180)        // início 520 → proposto 180
        check(p.width == PanelLayout.minOpen, "proposto 180 devia ficar na largura mínima (\(p.width))")
        // arrastar até "sumir" na lateral
        p.drag(translationX: 520 - 90)         // proposto 90 < 120
        check(p.width == 0 && !p.isVisible, "abaixo de \(PanelLayout.collapseBelow) o painel devia esconder-se (\(p.width))")
        p.endDrag()
        check(PanelLayout(defaults: defaults).width == 0, "o painel escondido devia continuar escondido ao reabrir a app")

        // e voltar a aparecer arrastando a mesma divisória
        p.drag(translationX: -60); check(p.width == 0, "um arrasto curto (60 px) ainda não devia abrir")
        p.drag(translationX: -150); check(p.width == PanelLayout.minOpen, "arrastar 150 px devia abrir na largura mínima (\(p.width))")
        p.drag(translationX: -300); check(p.width == 300, "continuar a arrastar aumenta (\(p.width))")
        p.endDrag()

        // duplo clique / menu: alterna
        p.toggle(); check(!p.isVisible, "alternar devia esconder")
        p.toggle(); check(p.width == PanelLayout.defaultWidth, "alternar devia mostrar com a largura padrão")

        // valores guardados fora dos limites
        defaults.set(5000.0, forKey: "propertiesPanelWidth"); check(PanelLayout(defaults: defaults).width == PanelLayout.maxWidth, "valor guardado enorme devia limitar-se")
        defaults.set(40.0, forKey: "propertiesPanelWidth"); check(PanelLayout(defaults: defaults).width == 0, "valor guardado minúsculo devia ficar escondido")

        // a janela já pode ser estreita
        check(MainWindow.minContentSize.width <= 760, "a janela devia poder estreitar até ≤ 760 px (mínimo \(MainWindow.minContentSize.width))")
        check(MainWindow.minContentSize.height <= 560, "a janela devia poder baixar até ≤ 560 px")
        return fails
    }

    // MARK: Deslize das ferramentas e pega do painel

    @MainActor static func toolsSelfTest() -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { fails.append(what) } }
        func close(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat = 0.01) -> Bool { abs(a - b) <= tol }

        let s = ToolsScroll()
        s.viewport = 200                                   // 12 ferramentas (66 px com a margem) numa área visível de 200 px
        let content = CGFloat(Tool.allCases.count) * ToolsScroll.slot - ToolsScroll.spacing
        let maxOff = content - 200
        check(close(s.contentWidth, content) && close(s.maxOffset, maxOff) && s.overflows, "limites: maxOffset \(maxOff) (é \(s.maxOffset))")
        check(s.offset == 0 && !s.canScrollLeft && s.canScrollRight, "no início só se pode ir para a direita")

        // 1) deslize contínuo: passos iguais e pequenos (nada de saltos de página), até à ponta
        let dt = 1.0 / 60.0
        let expectedStep = ToolsScroll.speed * CGFloat(dt)
        var last = s.offset, steps = 0, maxJump: CGFloat = 0, increasing = true
        while s.canScrollRight && steps < 400 {
            s.advance(dt: dt, direction: 1)
            maxJump = max(maxJump, s.offset - last); if s.offset < last { increasing = false }
            last = s.offset; steps += 1
        }
        check(increasing, "o deslize devia ser sempre para a frente")
        check(maxJump <= expectedStep + 0.001, "um passo de \(dt) s moveu \(maxJump) px (o esperado é \(expectedStep)): há saltos")
        check(steps > 60, "chegar ao fim devia demorar vários passos (foram \(steps)): não pode ser um salto")
        check(close(s.offset, maxOff, 0.5) && !s.canScrollRight, "devia parar na ponta (offset \(s.offset))")
        s.advance(dt: 1, direction: 1); check(close(s.offset, maxOff), "não passa da ponta")
        // ...e de volta
        var back = 0
        while s.canScrollLeft && back < 400 { s.advance(dt: dt, direction: -1); back += 1 }
        check(s.offset == 0 && back > 60, "o regresso também devia ser gradual (\(back) passos)")
        s.advance(dt: 1, direction: -1); check(s.offset == 0, "não passa do início")

        // 2) clique rápido = passo pequeno, e não um salto até ao fim
        s.scroll(by: ToolsScroll.clickStep)
        check(close(s.offset, ToolsScroll.clickStep), "um clique devia mover \(ToolsScroll.clickStep) px (moveu \(s.offset))")
        check(ToolsScroll.clickStep < ToolsScroll.slot * 2, "o passo de um clique devia ser menor que 2 ferramentas")
        s.scroll(by: 99999); check(close(s.offset, maxOff), "limita à ponta"); s.scroll(by: -99999); check(s.offset == 0, "limita ao início")

        // 3) roda do rato e trackpad (qualquer eixo desliza; para baixo/esquerda avança)
        s.wheel(dx: -30, dy: 0); check(close(s.offset, 30), "trackpad horizontal: 30 px (é \(s.offset))")
        s.wheel(dx: 0, dy: -20); check(close(s.offset, 50), "roda vertical também desliza na horizontal (é \(s.offset))")
        s.wheel(dx: 12, dy: 0); check(close(s.offset, 38), "no sentido contrário recua (é \(s.offset))")
        let wide = ToolsScroll(); wide.viewport = 900     // cabe tudo: nada desliza
        wide.wheel(dx: -50, dy: 0); check(wide.offset == 0 && !wide.overflows, "se cabe tudo, a roda não move nada")

        // 4) trazer uma ferramenta para a vista com o mínimo de movimento
        s.scroll(by: -9999)
        s.reveal(index: 9, animated: false)     // à direita da área visível
        let right9 = ToolsScroll.slot * 10 - ToolsScroll.spacing - 200
        check(close(s.offset, right9), "revelar a 10.ª ferramenta: offset \(right9) (é \(s.offset))")
        let at = s.offset
        s.reveal(index: 8, animated: false)     // já visível
        check(close(s.offset, at), "uma ferramenta já visível não mexe (é \(s.offset))")
        s.reveal(index: 0, animated: false); check(s.offset == 0, "revelar a 1.ª volta ao início")

        // 5) a janela cresce: o deslocamento passa a caber e é reposto dentro dos limites
        s.scroll(by: 500); s.viewport = 600; s.reclamp()
        check(s.offset <= s.maxOffset + 0.001 && close(s.maxOffset, content - 600), "ao alargar a janela o deslocamento limita-se (offset \(s.offset), máx \(s.maxOffset))")

        // 6) premir e manter (temporizador real): desliza continuamente; soltar para; um clique rápido dá só um passo
        let h = ToolsScroll(); h.viewport = 200
        h.pressBegan(direction: 1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        let during = h.offset
        h.pressEnded()
        let afterRelease = h.offset
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        check(during > 80 && during < 260, "manter premido 0,6 s devia deslizar ~180 px (deslizou \(during))")
        check(h.offset == afterRelease, "ao soltar devia parar (\(afterRelease) → \(h.offset))")
        check(abs(during - ToolsScroll.clickStep) > 10, "manter premido não é um clique")
        let before = h.offset
        h.pressBegan(direction: 1); h.pressEnded()   // clique rápido
        check(close(h.offset, before + ToolsScroll.clickStep), "clique rápido: um passo de \(ToolsScroll.clickStep) px (moveu \(h.offset - before))")

        // pega do painel escondido: larga o bastante para não se confundir com a borda da janela
        check(PanelLayout.hiddenHandleWidth >= 18, "a pega do painel escondido devia ter ≥ 18 px (tem \(PanelLayout.hiddenHandleWidth))")
        check(PanelLayout.hiddenHandleWidth >= 2 * PanelLayout.dividerWidth, "a pega escondida devia ser bem mais larga que a divisória normal")
        return fails
    }

    // MARK: Faixa da biblioteca (mostrar/ocultar)

    @MainActor static func libraryStripSelfTest(dir: URL) -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { fails.append(what) } }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        CaptureStore.overrideFolder = dir
        let state = AppState.shared
        let defaults = UserDefaults.standard
        let original = state.showLibraryStrip
        defer { state.showLibraryStrip = original }

        // criar capturas para a faixa ter miniaturas
        for _ in 0..<3 { _ = state.createBlankImage(width: 300, height: 200, backgroundHex: "#3366CC", transparent: false) }
        state.refreshLibrary()

        let size = NSSize(width: 900, height: 560)
        state.showLibraryStrip = true
        check(defaults.object(forKey: "libraryStripVisible") as? Bool == true, "o estado visível devia ficar guardado")
        guard let shown = renderMainWindow(state, size: size) else { return ["sem render (visível)"] }
        state.toggleLibraryStrip()
        check(state.showLibraryStrip == false && defaults.object(forKey: "libraryStripVisible") as? Bool == false, "ocultar devia ficar guardado")
        guard let hidden = renderMainWindow(state, size: size) else { return ["sem render (oculta)"] }

        // zona do canto inferior esquerdo (onde estariam as miniaturas): com a faixa visível tem conteúdo variado; oculta, é só a barra do rodapé
        func distinctColors(_ r: (px: [UInt8], w: Int, h: Int), rows: Range<Int>, columns: Range<Int>) -> Int {
            var set = Set<UInt32>()
            for y in rows { for x in columns { let o = (y * r.w + x) * 4; set.insert(UInt32(r.px[o]) << 16 | UInt32(r.px[o + 1]) << 8 | UInt32(r.px[o + 2])) } }
            return set.count
        }
        let bottom = (shown.h - 70)..<(shown.h - 10), left = 12..<240
        let withStrip = distinctColors(shown, rows: bottom, columns: left)
        let without = distinctColors(hidden, rows: bottom, columns: left)
        print("LIBRARYSTRIP-SELFTEST: cores distintas na zona de baixo: visível \(withStrip), oculta \(without)")
        check(withStrip >= without + 15, "com a faixa visível devia haver miniaturas em baixo (\(withStrip) cores contra \(without) sem a faixa)")
        check(without < 8, "com a faixa oculta não devia haver miniaturas em baixo (\(without) cores)")

        // a faixa oculta mantém o botão para a voltar a mostrar (o rodapé continua lá)
        state.toggleLibraryStrip()
        check(state.showLibraryStrip, "voltar a mostrar")
        return fails
    }
}

extension SelfTests {
    /// Com o editor do Toth aberto, escolher «Rolagem» no seletor não pode deixar nenhuma janela do Toth à frente.
    @MainActor
    static func scrollFocusSelfTest(delegate: AppDelegate) async -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { fails.append(what) } }
        MainWindow.show()
        try? await Task.sleep(nanoseconds: 800_000_000)
        check(MainWindow.isVisible && MainWindow.onScreenNormalWindowCount() >= 1, "o editor devia estar aberto no início")
        guard let screen = NSScreen.main else { return ["sem ecrã"] }
        let sel = RegionSelector()
        var gotScroll = false
        sel.onScroll = { _, _, _ in gotScroll = true }
        let img = delegate.syntheticSnapshotForTests(for: screen)
        sel.begin(snapshots: [(screen, img)]) { _ in }
        sel.debugPreselect(CGRect(x: 100, y: 100, width: 400, height: 300))
        try? await Task.sleep(nanoseconds: 400_000_000)
        check(!MainWindow.isVisible, "o editor devia estar escondido enquanto se escolhe a área")
        sel.debugScroll()
        try? await Task.sleep(nanoseconds: 600_000_000)
        check(gotScroll, "«Rolagem» devia chamar o tratador")
        check(MainWindow.onScreenNormalWindowCount() == 0, "depois de «Rolagem» ficaram \(MainWindow.onScreenNormalWindowCount()) janelas do Toth no ecrã (cobririam a app a capturar)")
        return fails
    }
}
