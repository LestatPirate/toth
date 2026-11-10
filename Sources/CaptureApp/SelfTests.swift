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
            host.frame = NSRect(x: 0, y: 0, width: 520, height: 600)
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
        recording.draw(in: NSRect(x: 0, y: 0, width: 520, height: 600))
        normal.draw(in: NSRect(x: 0, y: 610, width: 520, height: 600))
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
                           clicks: [(Double, Double)] = [], toolScroll: [Double] = [], tool: Tool? = nil, canvasImage: Bool = false, editHold: Bool = false) {
        PanelLayout.shared.setWidthForTests(panelHidden ? 0 : PanelLayout.defaultWidth)
        let state = AppState.shared
        if capture.lastPathComponent != "none" { state.open(capture) }   // "none": ecrã vazio (sem captura aberta)
        if let n = select, let m = state.model, m.doc.ordered.indices.contains(n) { m.selection = m.doc.ordered[n].id; m.tool = .select }
        if select == -1, let m = state.model { m.selectAll(); m.tool = .select }   // --select -1: tudo
        if let tool, let m = state.model { m.tool = tool }
        if canvasImage, let m = state.model { m.tool = .canvas; m.canvasTarget = .image }
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
        if editHold { CanvasView.current?.debugHoldEditing(); settle() }
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
        add(.patch(origin: Point(x: 330, y: 384), width: 300, height: 40))                                                    // Reparo: o telefone desaparece
        add(.stamp(origin: Point(x: 540, y: 516), width: 60, height: 60, symbol: StampLibrary.symbolKey("checkmark.circle.fill"))) { $0.colorHex = "#34C759" }
        add(.stamp(origin: Point(x: 1180, y: 60), width: 64, height: 64, symbol: "🔒"))
        return url
    }

    // MARK: Efeitos sobre camadas

    /// Blur e Pixelização têm de atuar sobre os objetos que estão por baixo deles (e só sobre esses).
    /// Alfa (0…255) dos quatro cantos de uma imagem (para saber se há margem transparente, por exemplo a sombra de uma janela).
    static func cornerAlpha(_ img: CGImage) -> [Int] {
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        guard let d = ctx.data else { return [] }
        let p = d.assumingMemoryBound(to: UInt8.self)
        func a(_ x: Int, _ y: Int) -> Int { Int(p[(y * img.width + x) * 4 + 3]) }
        // cantos e meio das bordas (os cantos de uma janela são redondos: transparentes mesmo sem sombra)
        return [a(0, 0), a(img.width - 1, 0), a(0, img.height - 1), a(img.width - 1, img.height - 1), a(img.width / 2, 0), a(0, img.height / 2), a(img.width / 2, img.height - 1)]
    }

    /// Selecionar área: retângulo, elipse e varinha; levantar como objeto (com o sítio apagado), duplicar, apagar, preencher,
    /// copiar píxeis, juntar com ⇧ e fundo transparente.
    static func areaSelfTest(dir: URL) -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { fails.append(what) } }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        CaptureStore.overrideFolder = dir
        let state = AppState.shared
        if let e = state.createBlankImage(width: 600, height: 400, backgroundHex: "#FFFFFF", transparent: false) { return ["não criou a imagem: \(e)"] }
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        guard let m = state.model, let canvas = CanvasView.current else { return ["sem editor"] }
        // base: quadrado azul (100…200) e zona vermelha (300…500 × 100…300) sobre branco
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 400, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 600, height: 400).fill()
        NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1).setFill(); NSRect(x: 100, y: 200, width: 100, height: 100).fill()   // (y de baixo) → imagem y 100…200
        NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill(); NSRect(x: 300, y: 100, width: 200, height: 200).fill()  // imagem y 100…300
        NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1).setFill(); NSRect(x: 140, y: 140, width: 20, height: 20).fill()    // ponto verde: imagem (150, 250) — fora das máscaras, para apanhar máscaras viradas
        NSGraphicsContext.restoreGraphicsState()
        m.base = rep.cgImage!
        m.zoomFit(); RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int, Int)? {
            guard let png = m.exportPNG(), let src = CGImageSourceCreateWithData(png as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil), let p = pixel(img, x, y) else { return nil }
            return (p.r, p.g, p.b, p.a)
        }
        func isBlue(_ p: (Int, Int, Int, Int)?) -> Bool { p.map { $0.2 > 200 && $0.0 < 60 && $0.1 < 60 } ?? false }
        func isWhite(_ p: (Int, Int, Int, Int)?) -> Bool { p.map { $0.0 > 235 && $0.1 > 235 && $0.2 > 235 } ?? false }
        check(isBlue(rgb(150, 150)), "base azul em (150,150)")

        // 1) retângulo: arrastar seleciona; Return levanta como objeto (sítio apagado); mover o objeto
        m.tool = .area; m.areaMode = .rect
        canvas.debugMouse(at: Point(x: 120, y: 120), dragTo: Point(x: 180, y: 180))
        check(m.areaSelection?.rect == Rect(x: 120, y: 120, width: 60, height: 60), "seleção retangular (\(String(describing: m.areaSelection?.rect)))")
        let n0 = m.doc.annotations.count
        m.liftSelection(erase: true)
        check(m.doc.annotations.count == n0 + 2 && m.tool == .select && m.selected?.shape.imageAsset != nil, "levantar cria o apagado e a imagem, e passa a Mover")
        check(m.areaSelection == nil, "a seleção de área limpa-se ao levantar")
        check(isBlue(rgb(150, 150)), "no sítio continua azul (a imagem está por cima do apagado)")
        m.nudgeSelection(dx: 300, dy: 0)
        check(isWhite(rgb(150, 150)), "depois de mover, o sítio de origem ficou apagado (\(String(describing: rgb(150, 150))))")
        check(isBlue(rgb(450, 150)), "a imagem levantada mostra o azul no destino (\(String(describing: rgb(450, 150))))")
        m.undo(); m.undo()
        check(m.doc.annotations.count == n0 && isBlue(rgb(150, 150)), "desfazer repõe tudo")

        // 1b) a área segue sempre o conteúdo: cresce quando o objeto levantado sai, encolhe quando volta ou é apagado
        m.tool = .area; m.areaMode = .rect
        canvas.debugMouse(at: Point(x: 120, y: 120), dragTo: Point(x: 180, y: 180))
        m.liftSelection(erase: true)
        m.nudgeSelection(dx: 500, dy: 0)
        check(m.doc.area.maxX >= 680, "mover para fora faz a área crescer (\(m.doc.area))")
        m.nudgeSelection(dx: -500, dy: 0)
        check(m.doc.area == Rect(x: 0, y: 0, width: 600, height: 400), "voltar para dentro encolhe-a outra vez (\(m.doc.area))")
        m.nudgeSelection(dx: 500, dy: 0)
        if let id = m.selection { m.setVisible(id, false) }
        check(m.doc.area == Rect(x: 0, y: 0, width: 600, height: 400), "esconder o objeto encolhe-a (\(m.doc.area))")
        if let id = m.selection { m.setVisible(id, true) }
        check(m.doc.area.maxX >= 680, "mostrar outra vez volta a crescer (\(m.doc.area))")
        m.deleteSelection()
        check(m.doc.area == Rect(x: 0, y: 0, width: 600, height: 400), "apagar o objeto encolhe-a (\(m.doc.area))")
        while m.doc.annotations.count > n0 { m.undo() }
        m.undo()   // (a seleção/levantar)
        while m.doc.annotations.count > n0 { m.undo() }
        check(m.doc.annotations.count == n0 && isBlue(rgb(150, 150)), "desfazer repõe a imagem")

        // 2) arrastar de dentro da seleção levanta e move de uma vez
        m.tool = .area
        canvas.debugMouse(at: Point(x: 110, y: 110), dragTo: Point(x: 190, y: 190))
        canvas.debugMouse(at: Point(x: 150, y: 150), dragTo: Point(x: 350, y: 150))
        check(m.tool == .select && m.selected?.shape.imageAsset != nil && abs((m.selected?.shape.bounds.minX ?? 0) - 310) < 0.5, "arrastar de dentro levanta e move (\(String(describing: m.selected?.shape.bounds)))")
        check(isWhite(rgb(150, 150)) && isBlue(rgb(350, 150)), "o azul mudou de sítio")
        m.undo(); m.undo()

        // um clique (sem arrastar) dentro da seleção não a levanta
        m.tool = .area; m.areaMode = .rect
        canvas.debugMouse(at: Point(x: 110, y: 110), dragTo: Point(x: 190, y: 190))
        canvas.debugMouse(at: Point(x: 150, y: 150))
        check(m.tool == .area && m.areaSelection != nil && m.doc.annotations.count == n0, "um clique dentro da seleção não levanta nada")
        m.clearAreaSelection()

        // 3) elipse: a máscara tem os cantos de fora
        m.tool = .area; m.areaMode = .ellipse
        canvas.debugMouse(at: Point(x: 100, y: 100), dragTo: Point(x: 200, y: 200))
        guard let el = m.areaSelection else { return fails + ["sem seleção elíptica"] }
        check(el.value(atX: 101, y: 101) == 0 && el.value(atX: 150, y: 150) == 255, "elipse: canto fora, centro dentro (\(el.value(atX: 101, y: 101)), \(el.value(atX: 150, y: 150)))")
        m.liftSelection(erase: false)
        check(m.doc.annotations.count == n0 + 1, "duplicar como objeto não apaga o original")
        if let name = m.selected?.shape.imageAsset, let img = m.assets.image(named: name), let c = pixel(img, 1, 1), let mid = pixel(img, 50, 50) {
            check(c.a == 0 && mid.a == 255 && mid.b > 200, "a imagem levantada tem a forma da elipse (canto a=\(c.a), centro a=\(mid.a))")
        } else { fails.append("sem imagem levantada da elipse") }
        m.undo()

        // 4) varinha: o quadrado azul exato; ⇧ junta a zona vermelha
        m.tool = .area; m.areaMode = .wand; m.wandTolerance = 32; m.wandContiguous = true
        canvas.debugMouse(at: Point(x: 150, y: 150))
        check(m.areaSelection?.rect == Rect(x: 100, y: 100, width: 100, height: 100) && m.areaSelection?.count == 10000, "varinha apanha o quadrado azul (\(String(describing: m.areaSelection?.rect)))")
        canvas.debugMouse(at: Point(x: 400, y: 200), shift: true)
        check(m.areaSelection?.rect == Rect(x: 100, y: 100, width: 400, height: 200), "⇧ junta a zona vermelha (\(String(describing: m.areaSelection?.rect)))")
        func isGreen(_ p: (Int, Int, Int, Int)?) -> Bool { p.map { $0.1 > 200 && $0.0 < 60 && $0.2 < 60 } ?? false }
        // apagar a união (máscara com forma): o ponto verde, dentro da caixa mas fora da máscara, fica
        m.eraseSelection()
        check(isWhite(rgb(150, 150)) && isWhite(rgb(400, 200)) && isGreen(rgb(150, 250)), "apagar a união respeita a forma da máscara (verde: \(String(describing: rgb(150, 250))))")
        m.undo()
        canvas.debugMouse(at: Point(x: 150, y: 150)); canvas.debugMouse(at: Point(x: 400, y: 200), shift: true)
        m.fillSelection()
        check(isWhite(rgb(150, 150)) && isGreen(rgb(150, 250)), "preencher a união respeita a forma da máscara (azul: \(String(describing: rgb(150, 150))), verde: \(String(describing: rgb(150, 250))))")
        m.undo()
        canvas.debugMouse(at: Point(x: 150, y: 150)); canvas.debugMouse(at: Point(x: 400, y: 200), shift: true)
        m.liftSelection(erase: false)
        if let name = m.selected?.shape.imageAsset, let img = m.assets.image(named: name), let g = pixel(img, 50, 150), let b = pixel(img, 50, 50) {
            check(g.a == 0 && b.a == 255 && b.b > 200, "a imagem levantada da união tem a forma (fora: a=\(g.a); azul: a=\(b.a))")
        } else { fails.append("sem imagem levantada da união") }
        m.undo(); m.tool = .area   // (levantar passa a Mover; desfazer não muda de ferramenta)
        canvas.debugMouse(at: Point(x: 150, y: 150)); canvas.debugMouse(at: Point(x: 400, y: 200), shift: true)
        canvas.debugMouse(at: Point(x: 400, y: 200), option: true)
        check(m.areaSelection?.rect == Rect(x: 100, y: 100, width: 100, height: 100), "⌥ tira-a outra vez")
        // varinha a arrastar: do azul (150,150) ao vermelho (400,150) passa pelo branco; as três zonas ficam selecionadas
        m.clearAreaSelection(); m.areaCombineMode = .add
        canvas.debugMouse(at: Point(x: 150, y: 150), dragTo: Point(x: 400, y: 150))
        check(m.areaSelection.map { $0.contains(Point(x: 150, y: 150)) && $0.contains(Point(x: 400, y: 150)) && $0.contains(Point(x: 250, y: 150)) } ?? false, "arrastar com a varinha vai apanhando as zonas por onde passa")
        // modo «Nova» substitui mesmo com seleção existente; modo «Tirar» retira
        m.areaCombineMode = .replace
        canvas.debugMouse(at: Point(x: 400, y: 200))
        check(m.areaSelection?.rect == Rect(x: 300, y: 100, width: 200, height: 200), "modo Nova substitui (\(String(describing: m.areaSelection?.rect)))")
        m.areaCombineMode = .add
        canvas.debugMouse(at: Point(x: 150, y: 150))
        check(m.areaSelection?.rect == Rect(x: 100, y: 100, width: 400, height: 200), "modo Juntar acrescenta")
        m.areaCombineMode = .subtract
        canvas.debugMouse(at: Point(x: 400, y: 200))
        check(m.areaSelection?.rect == Rect(x: 100, y: 100, width: 100, height: 100), "modo Tirar retira (\(String(describing: m.areaSelection?.rect)))")
        m.areaCombineMode = .replace
        canvas.debugMouse(at: Point(x: 150, y: 150))
        // apagar: o azul passa a branco
        m.eraseSelection()
        check(isWhite(rgb(150, 150)) && isWhite(rgb(199, 199)) && !isWhite(rgb(400, 200)), "apagar deixa o quadrado branco e o resto intacto")
        m.undo()
        // preencher (Reparo): o azul desaparece, preenchido pelo branco à volta
        canvas.debugMouse(at: Point(x: 150, y: 150))
        m.fillSelection()
        check(isWhite(rgb(150, 150)), "preencher apaga o quadrado a partir do branco à volta (\(String(describing: rgb(150, 150))))")
        m.undo()
        // copiar píxeis: PNG 100×100 na área de transferência
        canvas.debugMouse(at: Point(x: 150, y: 150))
        m.copySelectionPixels()
        if let d = NSPasteboard.general.data(forType: .png), let r = NSBitmapImageRep(data: d) { check(r.pixelsWide == 100 && r.pixelsHigh == 100, "copiar píxeis: PNG 100×100 (\(r.pixelsWide)×\(r.pixelsHigh))") } else { fails.append("copiar píxeis não pôs PNG") }
        // 5) fundo transparente: apagar fica transparente
        m.setTransparentBackground(true)
        canvas.debugMouse(at: Point(x: 150, y: 150))
        m.eraseSelection()
        check(rgb(150, 150)?.3 == 0, "com fundo transparente, apagado fica transparente (a=\(String(describing: rgb(150, 150)?.3)))")
        m.undo(); m.setTransparentBackground(false)
        // Esc limpa; ⌘A seleciona tudo
        canvas.debugMouse(at: Point(x: 150, y: 150)); m.escape()
        check(m.areaSelection == nil && m.tool == .area, "Esc limpa a seleção sem mudar de ferramenta")
        m.selectAll()
        check(m.areaSelection?.rect == Rect(x: 0, y: 0, width: 600, height: 400), "⌘A seleciona a área toda")
        m.clearAreaSelection(); m.tool = .select
        return fails
    }

    /// Alinhar, distribuir, agrupar e transformar o grupo (redimensionar em proporção e rodar) com o rato.
    static func arrangeSelfTest(dir: URL) -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { fails.append(what) } }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        CaptureStore.overrideFolder = dir
        let state = AppState.shared
        if let e = state.createBlankImage(width: 800, height: 500, backgroundHex: "#FFFFFF", transparent: false) { return ["não criou a imagem: \(e)"] }
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        guard let m = state.model, let canvas = CanvasView.current else { return ["sem editor"] }
        m.zoomFit(); RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        var st = Style(); st.lineVisible = false
        let a = m.addAnnotation(.rect(origin: Point(x: 100, y: 100), width: 100, height: 60))
        let b = m.addAnnotation(.rect(origin: Point(x: 300, y: 150), width: 60, height: 60))
        let c = m.addAnnotation(.rect(origin: Point(x: 600, y: 200), width: 80, height: 40))
        func ann(_ id: UUID) -> Annotation { m.doc.annotations.first { $0.id == id }! }
        for id in [a, b, c] { var x = ann(id); x.style = st; m.perform { $0.update(x) } }

        // 1) alinhar entre si e distribuir
        m.selectIDs([a, b, c])
        m.alignSelection(.left)
        check([a, b, c].allSatisfy { ann($0).shape.bounds.minX == 100 }, "alinhar à esquerda")
        m.alignSelection(.centerY)
        let midY = ann(a).shape.bounds.minY + 30
        check([b, c].allSatisfy { abs(ann($0).shape.bounds.minY + ann($0).shape.bounds.height / 2 - midY) < 0.01 }, "alinhar ao meio")
        m.undo(); m.undo()
        m.selectIDs([a, b, c])
        m.distributeSelection(horizontal: true)
        let bs = [a, b, c].map { ann($0).shape.bounds }
        let g1 = bs[1].minX - bs[0].maxX, g2 = bs[2].minX - bs[1].maxX
        check(abs(g1 - g2) < 0.01 && bs[0].minX == 100 && bs[2].maxX == 680, "distribuir na horizontal (intervalos \(g1) e \(g2))")
        m.undo()
        // um só: alinha-se à área
        m.selectIDs([c])
        m.alignSelection(.right)
        check(ann(c).shape.bounds.maxX == 800, "um só alinha-se à área (\(ann(c).shape.bounds))")
        m.undo()

        // 2) agrupar: clicar num membro seleciona o grupo; ⇧+clique tira o grupo todo; desagrupar
        m.tool = .select
        m.selectIDs([a, b]); m.groupSelection()
        check(ann(a).group != nil && ann(a).group == ann(b).group && ann(c).group == nil, "agrupar a e b")
        m.selection = nil
        canvas.debugMouse(at: Point(x: 150, y: 130))
        check(m.selectedIDs == [a, b], "clicar num membro seleciona o grupo (\(m.selectedIDs.count))")
        canvas.debugMouse(at: Point(x: 640, y: 220), shift: true)
        check(m.selectedIDs == [a, b, c], "⇧+clique junta o terceiro")
        canvas.debugMouse(at: Point(x: 330, y: 180), shift: true)
        check(m.selectedIDs == [c], "⇧+clique num membro tira o grupo todo (\(m.selectedIDs.count))")
        // laço que apanha só um membro apanha o grupo
        m.selection = nil
        canvas.debugMouse(at: Point(x: 80, y: 80), dragTo: Point(x: 220, y: 180))
        check(m.selectedIDs == [a, b], "o laço estende-se ao grupo (\(m.selectedIDs.count))")
        // duplicar: as cópias formam um grupo novo
        m.duplicateSelection()
        let copies = m.selectedAll
        check(copies.count == 2 && copies[0].group != nil && copies[0].group == copies[1].group && copies[0].group != ann(a).group, "as cópias ficam num grupo novo")
        m.undo()
        m.selectIDs([a, b]); m.ungroupSelection()
        check(ann(a).group == nil && ann(b).group == nil, "desagrupar")

        // 3) redimensionar o grupo em proporção pelo canto inferior direito (o superior esquerdo fica fixo)
        m.selectIDs([a, b])
        guard let gb = m.selectionBounds else { return fails + ["sem caixa do grupo"] }
        check(gb == Rect(x: 100, y: 100, width: 260, height: 110), "caixa do grupo (\(gb))")
        canvas.debugMouse(at: Point(x: gb.maxX, y: gb.maxY), dragTo: Point(x: gb.minX + gb.width * 2, y: gb.minY + gb.height * 2))
        let gb2 = m.selectionBounds!
        check(abs(gb2.width - 520) < 0.5 && abs(gb2.height - 220) < 0.5 && gb2.x == 100 && gb2.y == 100, "o grupo devia duplicar (\(gb2))")
        check(abs(ann(b).shape.bounds.width - 120) < 0.5 && abs(ann(b).shape.bounds.minX - 500) < 0.5, "cada membro escala à volta do canto fixo (\(ann(b).shape.bounds))")
        m.undo()
        check(m.selectionBounds == gb, "desfazer repõe o grupo")

        // 4) rodar o grupo 90°: cada membro roda e gira à volta do centro do grupo
        m.selectIDs([a, b])
        let gc = Point(x: gb.x + gb.width / 2, y: gb.y + gb.height / 2)
        let handle = Point(x: gc.x, y: gb.minY - 22 / m.fitScale)
        canvas.debugMouse(at: handle, dragTo: Point(x: gc.x + (gc.y - handle.y), y: gc.y))   // 90° para a direita
        check(abs(ann(a).rotation - 90) < 0.5 && abs(ann(b).rotation - 90) < 0.5, "os membros rodam 90° (\(ann(a).rotation), \(ann(b).rotation))")
        let ca = ann(a).shape.rotationCenter
        let expected = Geometry.rotate(Point(x: 150, y: 130), around: gc, degrees: 90)
        check(abs(ca.x - expected.x) < 0.5 && abs(ca.y - expected.y) < 0.5, "o centro de a gira à volta do centro do grupo (\(ca) vs \(expected))")
        m.undo()
        check(ann(a).rotation == 0 && ann(a).shape.rotationCenter == Point(x: 150, y: 130), "desfazer repõe a rotação")
        return fails
    }

    /// Carimbos e Reparo: desenho do símbolo e do emoji, preenchimento por vizinhança, clonagem; e o fluxo no editor.
    static func stampsRepairSelfTest(dir: URL) -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { fails.append(what) } }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        CaptureStore.overrideFolder = dir
        StampLibrary.overrideFolder = dir.appendingPathComponent("stamps")
        // base 600×400 branca com um retângulo vermelho pintado nos píxeis
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 400, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 600, height: 400).fill()
        NSColor.red.setFill(); NSRect(x: 100, y: 200, width: 200, height: 100).fill()   // (y de baixo: fica em y 100…200 da imagem)
        NSColor.black.setFill(); NSRect(x: 400, y: 100, width: 60, height: 60).fill()   // mancha a apagar: imagem y 240…300
        NSGraphicsContext.restoreGraphicsState()
        guard let base = rep.cgImage else { return ["sem imagem base"] }
        func rgb(_ png: Data?, _ x: Int, _ y: Int) -> (Int, Int, Int)? {
            guard let png, let src = CGImageSourceCreateWithData(png as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil), let p = pixel(img, x, y) else { return nil }
            return (p.r, p.g, p.b)
        }

        // 1) Reparo por preenchimento: a mancha preta sobre fundo branco desaparece (fica branco)
        var doc = CaptureDocument(canvasWidth: 600, canvasHeight: 400)
        doc.add(.patch(origin: Point(x: 395, y: 235), width: 70, height: 70))
        var png = Renderer.png(doc, base: base)
        if let p = rgb(png, 430, 270) { check(p.0 > 245 && p.1 > 245 && p.2 > 245, "o preenchimento devia apagar a mancha (ficou \(p))") } else { fails.append("sem PNG do preenchimento") }
        // uma faixa vertical que atravessa o retângulo vermelho: no meio fica vermelho (vizinhos vermelhos), em cima branco
        doc = CaptureDocument(canvasWidth: 600, canvasHeight: 400)
        doc.add(.patch(origin: Point(x: 180, y: 60), width: 40, height: 180))
        png = Renderer.png(doc, base: base)
        if let p = rgb(png, 200, 150) { check(p.0 > 200 && p.1 < 80 && p.2 < 80, "dentro do retângulo o preenchimento devia ser vermelho (ficou \(p))") }
        if let p = rgb(png, 200, 70) { check(p.0 > 230 && p.1 > 230 && p.2 > 230, "acima do retângulo o preenchimento devia ser branco (ficou \(p))") }

        // 2) Clonagem: a região em branco passa a ter o vermelho da origem
        doc = CaptureDocument(canvasWidth: 600, canvasHeight: 400)
        doc.add(.clone(origin: Point(x: 400, y: 20), width: 80, height: 60, source: Point(x: 120, y: 110)))
        png = Renderer.png(doc, base: base)
        if let p = rgb(png, 440, 50) { check(p.0 > 200 && p.1 < 80 && p.2 < 80, "a clonagem devia copiar o vermelho (ficou \(p))") }
        // a 5.ª alça é a origem e move-a
        let cl = Annotation(z: 0, shape: .clone(origin: Point(x: 400, y: 20), width: 80, height: 60, source: Point(x: 120, y: 110)))
        check(cl.shape.handles.count == 5 && cl.shape.handles[4] == Point(x: 160, y: 140), "alça da origem (\(cl.shape.handles))")
        check(cl.shape.movingHandle(4, to: Point(x: 300, y: 300)).cloneSource == Point(x: 260, y: 270), "mover a alça da origem")
        check(cl.shape.asRepair(clone: false).isRepair && cl.shape.asRepair(clone: false).cloneSource == nil, "trocar para preenchimento")

        // 3) Carimbos: símbolo azul e emoji desenham-se dentro da caixa
        doc = CaptureDocument(canvasWidth: 600, canvasHeight: 400)
        doc.add(.stamp(origin: Point(x: 20, y: 20), width: 80, height: 80, symbol: StampLibrary.symbolKey("checkmark.circle.fill")), style: Style(colorHex: "#0000FF"))
        doc.add(.stamp(origin: Point(x: 480, y: 300), width: 80, height: 80, symbol: "🔥"))
        png = Renderer.png(doc, base: base)
        if let p = rgb(png, 40, 60) { check(p.2 > 200 && p.0 < 80, "o símbolo devia ser azul (ficou \(p))") }
        if let p = rgb(png, 520, 345) { check(!(p.0 > 245 && p.1 > 245 && p.2 > 245), "o emoji devia pintar a caixa (ficou \(p))") }
        if let p = rgb(png, 10, 10) { check(p.0 > 245 && p.1 > 245 && p.2 > 245, "fora da caixa do carimbo fica a imagem (ficou \(p))") }
        // redimensionar mantém a proporção
        let st = Annotation(z: 0, shape: .stamp(origin: Point(x: 20, y: 20), width: 80, height: 40, symbol: "x"))
        let r = st.shape.movingHandle(2, to: Point(x: 200, y: 100)).bounds   // canto inferior direito; o superior esquerdo fica fixo
        check(abs(r.width / r.height - 2) < 0.01 && r.x == 20 && r.y == 20, "o carimbo devia manter a proporção (\(r))")

        // 4) No editor: ferramenta Carimbo com clique e arrasto, Reparo por arrasto, imagem importada como carimbo
        let state = AppState.shared
        if let e = state.createBlankImage(width: 600, height: 400, backgroundHex: "#FFFFFF", transparent: false) { return fails + ["não criou a imagem: \(e)"] }
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        guard let m = state.model, let canvas = CanvasView.current else { return fails + ["sem editor"] }
        m.zoomFit(); RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        m.tool = .stamp; m.chooseStamp("⭐️"); m.defaultStampSize = 50
        canvas.debugMouse(at: Point(x: 300, y: 200))
        check(m.doc.annotations.count == 1 && m.selected?.shape.stampSymbol == "⭐️" && m.selected?.shape.bounds == Rect(x: 275, y: 175, width: 50, height: 50), "clique devia pôr um carimbo de 50 centrado (\(String(describing: m.selected?.shape)))")
        check(m.tool == .select, "depois do carimbo volta a Mover")
        m.tool = .stamp
        canvas.debugMouse(at: Point(x: 100, y: 100), dragTo: Point(x: 220, y: 160))
        check(m.selected?.shape.bounds == Rect(x: 100, y: 100, width: 120, height: 120), "arrastar devia dar um carimbo quadrado de 120 (\(String(describing: m.selected?.shape.bounds)))")
        check(m.defaultStampSize == 120, "o tamanho arrastado passa a ser o padrão")
        m.tool = .repair; m.setRepairClones(false)
        canvas.debugMouse(at: Point(x: 400, y: 100), dragTo: Point(x: 460, y: 150))
        check(m.selected?.shape.isRepair == true && m.selected?.shape.cloneSource == nil, "arrastar com Reparo cria um preenchimento")
        m.setRepairClones(true)
        check(m.selected?.shape.cloneSource != nil, "trocar para Clonar no painel muda o elemento")
        m.undo()
        check(m.selected?.shape.cloneSource == nil, "desfazer repõe o preenchimento")
        // imagem importada: fica na biblioteca de carimbos e entra como imagem
        let imgURL = dir.appendingPathComponent("logo.png")
        try? NSBitmapImageRep(cgImage: image(120, 60, .systemPink, .systemOrange, label: "")).representation(using: .png, properties: [:])?.write(to: imgURL)
        let lib = StampLibrary.shared; lib.reload()
        check(lib.importImages([imgURL]).isEmpty && lib.images.count == 1, "importar a imagem para a biblioteca (\(lib.images))")
        let n = m.doc.annotations.count
        if let u = lib.images.first { m.addImageStamp(u, at: Point(x: 300, y: 300)) }
        check(m.doc.annotations.count == n + 1 && m.selected?.shape.imageAsset != nil && m.selected?.shape.bounds.width == 120 && m.selected?.shape.bounds.height == 60, "a imagem entra como `image` com a proporção (\(String(describing: m.selected?.shape.bounds)))")
        if let u = lib.images.first { lib.remove(u) }
        check(lib.images.isEmpty, "remover da biblioteca")
        // 5) bordas dos efeitos na vista, a vários zooms
        fails += canvas.selfTestEffectEdges()
        return fails
    }

    static func effectsSelfTest() -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { fails.append(what) } }
        // Efeitos encostados à borda da imagem: ficam opacos até à ponta (a margem de trabalho não entra na transparência de fora)
        do {
            let base = image(400, 300, .systemBlue, .systemOrange, label: "")
            for (name, shape) in [("blur", Shape.gaussian(origin: Point(x: 50, y: 0), width: 200, height: 120, intensity: 10)),
                                  ("pixelização", .blur(origin: Point(x: 50, y: 0), width: 200, height: 120, radius: 12)),
                                  ("reparo", .patch(origin: Point(x: 50, y: 0), width: 200, height: 120))] {
                var doc = CaptureDocument(canvasWidth: 400, canvasHeight: 300)
                doc.add(shape)
                guard let png = Renderer.png(doc, base: base), let src = CGImageSourceCreateWithData(png as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
                      let top = pixel(img, 150, 0), let inner = pixel(img, 150, 6) else { fails.append("\(name): sem imagem"); continue }
                check(top.a == 255 && abs(top.r - inner.r) < 6 && abs(top.b - inner.b) < 6, "\(name) na borda de cima devia ficar opaco e contínuo (linha 0: \(top), linha 6: \(inner))")
            }
        }
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
        check(m.tool == .select, "depois de desenhar, a ferramenta volta a Mover (é \(m.tool))")
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
        check(m.tool == .select, "depois da etapa volta a Mover")
        // ferramenta presa: continua ativa
        m.tool = .step; m.toolLocked = true; m.selection = nil
        canvas.debugMouse(at: Point(x: 700, y: 60))
        check(m.tool == .step && m.toolLocked, "com a ferramenta presa, continua ativa depois de desenhar")
        m.tool = .select

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
        // 8) Esc em dois tempos: ferramenta → Mover → sem seleção
        m.tool = .rect; m.selection = idA
        m.escape(); check(m.tool == .select && m.selection == idA, "primeiro Esc volta a Mover e mantém a seleção")
        m.escape(); check(m.selection == nil, "segundo Esc limpa a seleção")
        // 9) Tela: Esc cancela o que foi feito nela
        let areaBefore = m.doc.area, autoBefore = m.doc.autoExpand
        m.tool = .canvas
        m.setAreaSize(width: 900, height: 600); m.setAreaSize(width: 950, height: 650)
        check(!m.doc.autoExpand, "mudar a área à mão devia desligar o ajuste automático")
        m.escape()
        check(m.tool == .select && m.doc.area == areaBefore && m.doc.autoExpand == autoBefore, "Esc na Tela devia desfazer as alterações (área \(m.doc.area))")
        // 10) setas deslocam o elemento selecionado
        m.selection = idA
        let x0 = m.selected!.shape.bounds.x
        m.nudgeSelection(dx: 10, dy: 0)
        check(m.selected!.shape.bounds.x == x0 + 10, "setas deviam deslocar o objeto")
        m.undo()
        // 11) começar a escrever num objeto de texto abre a edição com essa letra
        let tid = m.addAnnotation(.textBox(origin: Point(x: 100, y: 400), width: 200, height: 50, string: "abc", fontSize: 20))
        m.tool = .select; m.selection = tid
        if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: canvas.window?.windowNumber ?? 0, context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6) {
            canvas.keyDown(with: e)
        }
        check(canvas.debugEditorString == "z", "escrever devia abrir a edição com a letra (\(canvas.debugEditorString ?? "nil"))")
        canvas.debugFinishEditing()
        check(m.selected?.editableString == "z", "o texto devia ficar gravado")
        // 12) passar por cima destaca o objeto
        canvas.debugHover(at: inA)
        check(m.hover != nil && m.hover == m.doc.topmost(at: inA, tolerance: 1)?.id, "passar por cima devia marcar o objeto de cima como hover (\(String(describing: m.hover)))")
        canvas.debugHover(at: empty)
        check(m.hover == nil, "no vazio não há hover")
        // 13) seleção múltipla: ⇧+clique junta; laço apanha; mover em grupo; ⌥+arrastar duplica; guias encostam
        m.tool = .select; m.selection = nil
        for a in m.doc.annotations where a.id != idA && a.id != idB { m.perform { $0.remove(id: a.id) } }   // só A e B
        canvas.debugMouse(at: inA)
        canvas.debugMouse(at: inB, shift: true)
        check(m.selectedIDs == [idA, idB], "⇧+clique devia juntar B à seleção (\(m.selectedIDs.count))")
        canvas.debugMouse(at: inB, shift: true)
        check(m.selectedIDs == [idA], "⇧+clique num selecionado devia tirá-lo")
        canvas.debugMouse(at: Point(x: 50, y: 50), dragTo: Point(x: 700, y: 260))             // laço à volta de A e B
        check(m.selectedIDs == [idA, idB], "o laço devia apanhar A e B (\(m.selectedIDs.count))")
        let ax = m.doc.annotations.first { $0.id == idA }!.shape.bounds.x, bx = m.doc.annotations.first { $0.id == idB }!.shape.bounds.x
        canvas.debugMouse(at: inA, dragTo: Point(x: inA.x + 100, y: inA.y + 100), command: true)   // ⌘: sem encosto
        check(m.doc.annotations.first { $0.id == idA }!.shape.bounds.x == ax + 100 && m.doc.annotations.first { $0.id == idB }!.shape.bounds.x == bx + 100, "arrastar um selecionado devia mover o grupo")
        m.undo()
        let n4 = count()
        canvas.debugMouse(at: inA, dragTo: Point(x: inA.x + 50, y: inA.y + 300), option: true, command: true)
        check(count() == n4 + 2 && m.selectedIDs.count == 2 && !m.selectedIDs.contains(idA), "⌥+arrastar devia duplicar os dois e arrastar as cópias (\(count()) vs \(n4 + 2))")
        check(m.doc.annotations.first { $0.id == idA }!.shape.bounds.x == ax, "os originais ficam no sítio")
        m.undo(); m.undo()   // o arrasto e a duplicação
        check(count() == n4, "desfazer duas vezes devia tirar as cópias (\(count()) vs \(n4))")
        // guias: mover B para perto do lado esquerdo de A encosta exatamente (A em x=100; B em x=450, largura 200)
        m.selection = idB
        canvas.debugMouse(at: inB, dragTo: Point(x: inB.x - 346, y: inB.y + 200))   // B.x ficaria em 104: encosta a 100
        check(m.doc.annotations.first { $0.id == idB }!.shape.bounds.x == 100, "mover B devia encostar à borda esquerda de A (x=\(m.doc.annotations.first { $0.id == idB }!.shape.bounds.x))")
        m.undo()
        m.selection = nil
        return fails
    }

    // MARK: Rotação dos elementos e enquadramento da imagem (Tela → Imagem)

    static func rotateSelfTest(dir: URL) -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { fails.append(what) } }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        CaptureStore.overrideFolder = dir
        let state = AppState.shared
        // imagem 800×500: metade esquerda verde, direita branca (para ver a rotação da imagem)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 500, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 800, height: 500).fill()
        NSColor.green.setFill(); NSRect(x: 0, y: 0, width: 400, height: 500).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let url = try? CaptureStore.save(rep.cgImage!) else { return ["não criou a captura"] }
        state.open(url)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        guard let m = state.model, let canvas = CanvasView.current else { return ["sem editor"] }
        m.zoomFit(); RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        func export() -> NSBitmapImageRep? { m.exportPNG().flatMap { NSBitmapImageRep(data: $0) } }
        func isRed(_ r: NSBitmapImageRep, _ x: Int, _ y: Int) -> Bool { guard let c = r.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }; return c.redComponent > 0.8 && c.greenComponent < 0.3 }
        func isGreen(_ r: NSBitmapImageRep, _ x: Int, _ y: Int) -> Bool { guard let c = r.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }; return c.greenComponent > 0.8 && c.redComponent < 0.3 }
        func isWhite(_ r: NSBitmapImageRep, _ x: Int, _ y: Int) -> Bool { guard let c = r.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }; return c.redComponent > 0.9 && c.greenComponent > 0.9 && c.blueComponent > 0.9 }

        // 1) retângulo vermelho 200×60 centrado em (400,250), rodado 90°: fica vertical (200 de altura, 60 de largura)
        var id = UUID()
        m.perform { id = $0.add(.rect(origin: Point(x: 300, y: 220), width: 200, height: 60), style: Style(colorHex: "#FF0000", lineWidth: 2, fillHex: "#FF0000")).id }
        m.selection = id; m.tool = .select
        m.setRotation(90)
        check(m.selected?.rotation == 90, "a rotação devia ficar em 90°")
        if let r = export() {
            check(isRed(r, 400, 330) && isRed(r, 400, 170), "rodado 90°, o retângulo devia ocupar (400,330) e (400,170)")
            check(!isRed(r, 480, 250) && !isRed(r, 320, 250), "rodado 90°, (480,250) e (320,250) deviam ficar livres")
        } else { fails.append("sem exportação") }
        // 2) o toque segue a rotação
        m.selection = nil
        canvas.debugMouse(at: Point(x: 400, y: 330))
        check(m.selection == id, "clicar no retângulo rodado devia selecioná-lo")
        canvas.debugMouse(at: Point(x: 480, y: 250))
        check(m.selection == nil, "clicar onde o retângulo já não está não devia selecionar")
        // 3) a alça redonda roda o elemento: de 90° para 180° (alça arrastada para baixo do centro)
        m.selection = id
        if let a = m.selected {
            let h = canvas.rotationHandlePoint(a)
            check(abs(h.x - 400 - (30 + 22 / m.fitScale)) < 1 && abs(h.y - 250) < 1, "com 90° a alça devia estar à direita do centro (\(h))")
            canvas.debugMouse(at: h, dragTo: Point(x: 400, y: 400))
            check(m.selected?.rotation == 180, "arrastar a alça para baixo devia dar 180° (\(m.selected?.rotation ?? -1))")
            canvas.debugMouse(at: canvas.rotationHandlePoint(m.selected!), dragTo: Point(x: 250, y: 100))   // ⌥: sem encostar
            let free = m.selected?.rotation ?? 0
            check(abs(free - (-45)) < 6, "a alça devia seguir o rato (\(free))")
            m.undo(); m.undo()
            check(m.selected?.rotation == 90, "desfazer devia repor 90°")
        }
        // 4) redimensionar rodado: a alça do canto oposto fica no sítio
        if let a = m.selected {
            let before = a.handlePoints[0], h2 = a.handlePoints[2]
            canvas.debugMouse(at: h2, dragTo: Point(x: h2.x - 20, y: h2.y + 40))
            let after = m.selected?.handlePoints[0] ?? Point(x: -1, y: -1)
            check(abs(after.x - before.x) < 1 && abs(after.y - before.y) < 1, "o canto oposto não devia mexer (\(before) → \(after))")
            check((m.selected?.shape.bounds.width ?? 0) > 200, "o retângulo devia ter crescido")
            m.undo()
        }
        // 5) rotação guardada e relida
        m.perform { _ in }
        if let re = try? EditorModel(url: url) { check(re.doc.annotations.first { $0.id == id }?.rotation == 90, "a rotação devia ficar no ficheiro") }

        // 6) Tela → Imagem: rodar a imagem 90° para a direita: a área passa a 500×800 e o verde (esquerda) vai para cima
        m.tool = .canvas; m.canvasTarget = .image
        m.rotateImage(by: 90)
        check(m.imageRotation == 90, "a imagem devia estar a 90°")
        check(abs(m.doc.area.width - 500) < 1 && abs(m.doc.area.height - 800) < 1, "a área devia seguir a imagem rodada (\(m.doc.area))")
        if let r = export() {
            check(r.pixelsWide == 500 && r.pixelsHigh == 800, "a exportação devia ter 500×800 (\(r.pixelsWide)×\(r.pixelsHigh))")
            check(isGreen(r, 250, 100) && isWhite(r, 250, 700), "rodada para a direita, a metade verde devia ficar em cima")
        }
        m.undo()
        check(m.imageIsNatural, "desfazer devia repor a imagem natural")
        // 7) redimensionar pela alça do canto inferior direito, em proporção: 800×500 → 400×250
        canvas.debugMouse(at: canvas.imageHandlePoints()[4], dragTo: Point(x: 400, y: 250))
        let p = m.imagePlacement
        check(abs(p.width - 400) < 1 && abs(p.height - 250) < 1 && abs(p.x) < 1 && abs(p.y) < 1, "em proporção devia ficar 400×250 na origem (\(p))")
        // a área ajusta-se ao conteúdo: a imagem (400×250) mais o retângulo rodado (370…430 × 150…350, com a linha)
        check(abs(m.doc.area.width - 431) < 1.5 && abs(m.doc.area.height - 351) < 1.5 && abs(m.doc.area.x) < 1, "a área devia seguir a imagem e o retângulo (\(m.doc.area))")
        m.undo()
        // 8) com ⇧: livre (400×300)
        canvas.debugMouse(at: canvas.imageHandlePoints()[4], dragTo: Point(x: 400, y: 300), shift: true)
        let f = m.imagePlacement
        check(abs(f.width - 400) < 1 && abs(f.height - 300) < 1, "com ⇧ devia ficar 400×300 (\(f))")
        m.undo()
        // 9) a alça de um lado muda só uma medida
        canvas.debugMouse(at: canvas.imageHandlePoints()[3], dragTo: Point(x: 600, y: 250))
        check(abs(m.imagePlacement.width - 600) < 1 && abs(m.imagePlacement.height - 500) < 1, "o lado direito devia mudar só a largura (\(m.imagePlacement))")
        m.undo()
        // 10) mover a imagem: arrastar de dentro
        canvas.debugMouse(at: Point(x: 400, y: 250), dragTo: Point(x: 450, y: 280))
        check(abs(m.imagePlacement.x - 50) < 1 && abs(m.imagePlacement.y - 30) < 1, "arrastar devia mover a imagem (\(m.imagePlacement))")
        check(abs(m.doc.area.x - 50) < 1, "a área (sem área própria) devia acompanhar a imagem (\(m.doc.area))")
        m.undo()
        // 11) a alça redonda roda a imagem (encosta aos 90°)
        canvas.debugMouse(at: canvas.imageRotationHandlePoint(), dragTo: Point(x: 900, y: 252))
        check(m.imageRotation == 90, "a alça devia rodar a imagem para 90° (\(m.imageRotation))")
        // 12) campos: tamanho em proporção e escala; restaurar
        m.setImageSize(width: 200)
        check(abs(m.imagePlacement.width - 200) < 1 && abs(m.imagePlacement.height - 125) < 1 && m.imageRotation == 90, "largura 200 em proporção devia dar 200×125 e manter a rotação (\(m.imagePlacement))")
        m.keepImageAspect = false; m.setImageSize(height: 400); m.keepImageAspect = true
        check(abs(m.imagePlacement.width - 200) < 1 && abs(m.imagePlacement.height - 400) < 1, "sem proporção, a altura muda sozinha (\(m.imagePlacement))")
        m.setImageScale(0.5)
        check(abs(m.imagePlacement.width - 400) < 1 && abs(m.imagePlacement.height - 250) < 1, "escala 50% devia dar 400×250")
        m.resetImage()
        check(m.imageIsNatural && m.doc.area == m.doc.naturalImageRect, "restaurar devia voltar ao natural")
        // 13) só clicar na imagem (sem arrastar) não altera nada nem cria ponto de undo
        let undos = m.canUndo
        m.tool = .canvas; m.canvasTarget = .area
        canvas.debugMouse(at: Point(x: 400, y: 250))
        check(m.canvasTarget == .image && m.imageIsNatural, "clicar na imagem devia só passar a editá-la")
        check(m.canUndo == undos, "um clique sem arrasto não devia criar um ponto de undo")
        // 14) a imagem rodada entra no desenho dos efeitos sem falhar
        m.tool = .select
        var bid = UUID()
        m.perform { bid = $0.add(.gaussian(origin: Point(x: 100, y: 100), width: 200, height: 100, intensity: 8)).id; $0.setImageFrame($0.naturalImageRect, rotation: 30) }
        m.selection = bid; m.setRotation(20)
        check(export() != nil, "exportar com imagem e blur rodados devia funcionar")
        // 15) texto rodado (fica no ficheiro, para os testes visuais com --render-main … --edit-hold)
        var tid = UUID()
        m.perform { tid = $0.add(.textBox(origin: Point(x: 420, y: 320), width: 260, height: 60, string: "Texto rodado", fontSize: 28), style: Style(colorHex: "#1D4ED8", fillHex: "#FFFFFF")).id }
        m.selection = tid; m.setRotation(-30)
        check(export() != nil && m.selected?.rotation == -30, "texto rodado devia exportar")
        m.selection = nil
        print("ROTATE-CAPTURE: \(url.path)")
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
        let wide = ToolsScroll(); wide.viewport = 1200    // cabe tudo: nada desliza
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

        // deslize automático: pousar o rato junto a uma ponta puxa para esse lado, mais depressa perto da ponta
        let a = ToolsScroll(); a.viewport = 200
        let w: CGFloat = 244
        check(a.hoverPull(x: 120, width: w).direction == 0, "a meio da barra não desliza")
        check(a.hoverPull(x: 5, width: w).direction == 0, "no início não há nada para a esquerda")
        let near = a.hoverPull(x: w - 4, width: w), far = a.hoverPull(x: w - 50, width: w)
        check(near.direction == 1 && far.direction == 1 && near.factor > far.factor && near.factor <= 1, "junto à ponta direita desliza, mais depressa mais perto (\(far.factor) → \(near.factor))")
        a.hover(x: w - 4, width: w)
        for _ in 0..<30 { a.advanceHover(dt: dt) }
        check(a.offset > 100 && a.offset < 160, "meio segundo pousado na ponta desliza ~\(Int(ToolsScroll.hoverSpeed / 2)) px (deslizou \(a.offset))")
        let slid = a.offset
        a.hover(x: 120, width: w)
        for _ in 0..<30 { a.advanceHover(dt: dt) }
        check(a.offset == slid, "sair da zona pára o deslize")
        check(a.hoverPull(x: 5, width: w).direction == -1, "agora já há para a esquerda")
        a.hover(x: w - 4, width: w); a.hover(x: nil, width: w)
        for _ in 0..<30 { a.advanceHover(dt: dt) }
        check(a.offset == slid && a.hoverDirection == 0, "o rato sair da barra pára o deslize")
        a.setOffset(a.maxOffset)
        check(a.hoverPull(x: w - 4, width: w).direction == 0, "na ponta direita não desliza mais")

        // na janela a sério: a área de seguimento cobre a barra TODA (do topo ao fundo), não só a faixa junto à barra de rolagem
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("toth-tools-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        CaptureStore.overrideFolder = tmp
        if AppState.shared.createBlankImage(width: 400, height: 300, backgroundHex: "#FFFFFF", transparent: false) == nil {
            MainWindow.show()
            if let win = NSApp.windows.first(where: { $0.contentView is NSHostingView<MainView> }) {
                win.setContentSize(NSSize(width: 760, height: 600))
                RunLoop.current.run(until: Date().addingTimeInterval(0.8))
                if let live = ToolsScroll.current, let v = live.trackView {
                    check(v.bounds.height >= 50 && v.bounds.width > 120, "a área de seguimento devia cobrir a barra (\(v.bounds))")
                    check(live.overflows, "numa janela estreita as ferramentas não cabem")
                    func move(_ x: CGFloat, _ y: CGFloat) -> NSEvent? {
                        NSEvent.mouseEvent(with: .mouseMoved, location: v.convert(NSPoint(x: x, y: y), to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
                    }
                    for y in [CGFloat(3), 20, 38, v.bounds.height - 3] {
                        if let e = move(v.bounds.width - 6, y) {
                            v.mouseMoved(with: e)
                            check(live.hoverDirection == 1, "rato à direita, a \(Int(y)) px do topo da barra: devia deslizar (direção \(live.hoverDirection))")
                            check(live.contains(windowPoint: e.locationInWindow, in: win), "a roda devia valer a \(Int(y)) px do topo da barra")
                        }
                        if let e = move(v.bounds.width / 2, y) { v.mouseMoved(with: e); check(live.hoverDirection == 0, "a meio da barra não desliza") }
                    }
                    if let e = move(v.bounds.width - 6, v.bounds.height + 30) { check(!live.contains(windowPoint: e.locationInWindow, in: win), "abaixo da barra a roda já não é das ferramentas") }
                    // o deslize arranca mesmo (depois da pausa) com o rato pousado no topo da barra
                    let start = live.offset
                    if let e = move(v.bounds.width - 6, 5) { v.mouseMoved(with: e) }
                    RunLoop.current.run(until: Date().addingTimeInterval(0.9))
                    check(live.offset > start + 40, "pousado junto à ponta, no topo da barra, devia ter deslizado (\(start) → \(live.offset))")
                    v.mouseExited(with: NSEvent())
                } else { fails.append("sem área de seguimento na barra das ferramentas") }
            } else { fails.append("sem janela principal") }
        } else { fails.append("não criou a imagem de teste") }

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

        // a faixa mostra só as 20 mais recentes (e a que está aberta, se for mais antiga)
        for i in 0..<21 { _ = state.createBlankImage(width: 120 + i, height: 80, backgroundHex: "#CC6633", transparent: false) }
        state.refreshLibrary()
        check(state.library.count >= 22, "a biblioteca tem tudo (\(state.library.count))")
        check(AppState.stripLimit == 20 && state.stripItems.count == 20 && state.stripItems.map(\.url) == Array(state.library.prefix(20)).map(\.url), "a faixa mostra as 20 mais recentes (\(state.stripItems.count))")
        if let oldest = state.library.last {
            state.open(oldest.url)
            check(state.stripItems.count == 21 && state.stripItems.last?.url == oldest.url, "a captura aberta aparece mesmo sendo antiga (\(state.stripItems.count))")
        }
        // clicar numa miniatura marca-a; Backspace envia-a para o Lixo e abre outra
        let victim = state.stripItems[2].url, total = state.library.count
        state.selectInStrip(victim)
        check(state.stripSelection == victim && state.isCurrent(victim), "clicar na miniatura abre e marca")
        check(state.deleteStripSelection(), "Backspace com a miniatura marcada apaga")
        check(state.library.count == total - 1 && !FileManager.default.fileExists(atPath: victim.path) && state.stripSelection == nil, "a captura foi para o Lixo (\(state.library.count) de \(total))")
        check(!state.deleteStripSelection() && state.library.count == total - 1, "sem miniatura marcada, Backspace não apaga mais nenhuma")
        // a tecla a sério: Backspace na janela apaga a marcada; outra tecla ou um clique desmarca
        if let win = NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.windows.first {
            func key(_ code: UInt16) -> NSEvent? {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)
            }
            let second = state.stripItems[1].url
            state.selectInStrip(second)
            if let e = key(0) { NSApp.sendEvent(e) }   // «a»: desmarca
            check(state.stripSelection == nil, "outra tecla desmarca a miniatura")
            if let e = key(51) { NSApp.sendEvent(e) }
            check(FileManager.default.fileExists(atPath: second.path), "depois de desmarcada, Backspace não apaga a captura")
        }
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

extension SelfTests {
    // MARK: Pasta das capturas (mudar e migrar)

    /// Simula a pasta antiga (`Capture`) com uma captura, um vídeo com edição e carimbos soltos no sítio antigo, migra para
    /// a pasta nova e depois muda de pasta pelas Preferências (`changeCaptureFolder`), com um conflito de nome pelo meio.
    @MainActor static func folderSelfTest(dir: URL) -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { fails.append(what) } }
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = dir.appendingPathComponent("Capture"), new = dir.appendingPathComponent("TothCapture"), oldStamps = dir.appendingPathComponent("AppSupport/Toth/Stamps")
        for d in [old, oldStamps, old.appendingPathComponent("Toth_2026-01-01_10.00.00.mp4.edicao"), old.appendingPathComponent("Toth_2025-12-31_09.00.00.capture")] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
        func touch(_ u: URL, _ s: String = "x") { try? s.data(using: .utf8)!.write(to: u) }
        touch(old.appendingPathComponent("Toth_2026-01-01_10.00.00.mp4"))
        touch(old.appendingPathComponent("Toth_2026-01-01_10.00.00.mp4.edicao/edicao.json"), "{}")
        touch(old.appendingPathComponent("Toth_2026-01-02_10.00.00.capture"), "zip")
        touch(old.appendingPathComponent("Toth_2025-12-31_09.00.00.capture/document.json"), "{}")   // captura antiga em pasta
        touch(old.appendingPathComponent("notas.txt"), "do utilizador")                            // não é do Toth: fica
        touch(old.appendingPathComponent(".DS_Store"))
        touch(oldStamps.appendingPathComponent("logo.png"), "png")
        touch(oldStamps.appendingPathComponent("seta.png"), "png")

        // 1) migração da pasta antiga para a nova (como ao abrir a app pela primeira vez depois da mudança de nome)
        let r1 = CaptureStore.moveContents(from: old, to: new)
        check(r1.moved == 4 && r1.failed.isEmpty, "move as 4 coisas do Toth (moveu \(r1.moved), falhou \(r1.failed))")
        check(fm.fileExists(atPath: new.appendingPathComponent("Toth_2026-01-01_10.00.00.mp4.edicao/edicao.json").path), "a pasta de edição vai com o vídeo")
        check(fm.fileExists(atPath: new.appendingPathComponent("Toth_2025-12-31_09.00.00.capture/document.json").path), "a captura antiga em pasta vai inteira")
        check(fm.fileExists(atPath: old.appendingPathComponent("notas.txt").path) && !r1.removedOld, "o que não é do Toth fica, e a pasta antiga não é apagada")
        let s1 = CaptureStore.moveStampFiles(from: oldStamps, to: new.appendingPathComponent(CaptureStore.stampsSubfolder))
        check(s1.moved == 2 && s1.removedOld && !fm.fileExists(atPath: oldStamps.path), "os carimbos passam para «Carimbos» e a pasta antiga some (\(s1.moved))")
        check(fm.fileExists(atPath: new.appendingPathComponent("Carimbos/logo.png").path), "carimbo no sítio novo")

        // 2) mudar de pasta pelas Preferências: a app usa `new` como pasta atual
        CaptureStore.overrideFolder = new
        let state = AppState.shared
        state.refreshLibrary()
        check(state.library.count == 3, "a biblioteca vê as 3 capturas/vídeos (\(state.library.count))")
        check(StampLibrary.folder.lastPathComponent == CaptureStore.stampsSubfolder && StampLibrary.folder.deletingLastPathComponent().resolvingSymlinksInPath().path == new.resolvingSymlinksInPath().path, "a pasta dos carimbos é a subpasta da pasta das capturas (\(StampLibrary.folder.path))")
        StampLibrary.shared.reload()
        check(StampLibrary.shared.images.count == 2, "a biblioteca de carimbos lê os 2 migrados (\(StampLibrary.shared.images.count))")
        let other = dir.appendingPathComponent("Outra/Pasta")
        try? fm.createDirectory(at: other, withIntermediateDirectories: true)
        touch(other.appendingPathComponent("Toth_2026-01-02_10.00.00.capture"), "já existia")   // conflito de nome
        let r2 = CaptureStore.moveContents(from: new, to: other)
        check(r2.moved == 4 && r2.failed == ["Toth_2026-01-02_10.00.00.capture"], "move o resto (3 + a pasta Carimbos) e reporta o conflito (moveu \(r2.moved), falhou \(r2.failed))")
        check((try? String(contentsOf: other.appendingPathComponent("Toth_2026-01-02_10.00.00.capture"), encoding: .utf8)) == "já existia", "o ficheiro do destino não é substituído")
        check(fm.fileExists(atPath: new.appendingPathComponent("Toth_2026-01-02_10.00.00.capture").path) && !r2.removedOld, "o que falhou fica na pasta antiga, que por isso não é apagada")
        check(fm.fileExists(atPath: other.appendingPathComponent("Carimbos/seta.png").path), "os carimbos migram com as capturas")
        // 3) e para uma pasta vazia: tudo vai e a antiga desaparece
        let third = dir.appendingPathComponent("Terceira")
        let r3 = CaptureStore.moveContents(from: other, to: third)
        check(r3.moved == 5 && r3.failed.isEmpty && r3.removedOld && !fm.fileExists(atPath: other.path), "para uma pasta vazia vai tudo e a antiga é removida (moveu \(r3.moved), removida \(r3.removedOld))")
        // 4) o caminho curto e a preferência
        check(CaptureStore.shortPath(fm.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/TothCapture")) == "~/Pictures/TothCapture", "caminho abreviado com ~")
        check(CaptureStore.defaultFolder.lastPathComponent == "TothCapture", "a pasta por omissão chama-se TothCapture")
        CaptureStore.overrideFolder = nil
        return fails
    }
}

extension SelfTests {
    // MARK: Texto da imagem (reconhecimento, estilo, editar, copiar)

    @MainActor static func ocrSelfTest(dir: URL) -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { fails.append(what) } }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        CaptureStore.overrideFolder = dir
        let state = AppState.shared
        if let e = state.createBlankImage(width: 800, height: 400, backgroundHex: "#FFFFFF", transparent: false) { return ["não criou a imagem: \(e)"] }
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        guard let m = state.model, let canvas = CanvasView.current else { return ["sem editor"] }
        // base: uma linha a negrito azul (Helvetica Neue Bold 32) e uma linha monoespaçada preta (Menlo 24)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 400, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 800, height: 400).fill()
        let bold = NSFont(name: "HelveticaNeue-Bold", size: 32) ?? NSFont.boldSystemFont(ofSize: 32)
        let blue = NSColor(srgbRed: 0.11, green: 0.31, blue: 0.85, alpha: 1)
        ("Guardar alterações" as NSString).draw(at: NSPoint(x: 60, y: 400 - 100), withAttributes: [.font: bold, .foregroundColor: blue])   // (y de baixo) → topo ≈ 100 - ascender
        let mono = NSFont(name: "Menlo", size: 24) ?? NSFont.monospacedSystemFont(ofSize: 24, weight: .regular)
        ("Total: 1250 EUR" as NSString).draw(at: NSPoint(x: 60, y: 400 - 220), withAttributes: [.font: mono, .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        m.base = rep.cgImage!
        m.zoomFit(); RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        m.tool = .ocr   // (dispara o reconhecimento em segundo plano; o síncrono a seguir substitui-o)
        m.recognizeTextNow()
        check(m.textBlocks.count == 2, "devia reconhecer 2 linhas (\(m.textBlocks.map(\.text)))")
        guard let b1 = m.textBlocks.first(where: { $0.text.lowercased().hasPrefix("guardar") }), let b2 = m.textBlocks.first(where: { $0.text.lowercased().hasPrefix("total") }) else {
            return fails + ["não leu as linhas esperadas: \(m.textBlocks.map(\.text))"]
        }
        check(b1.text.lowercased().contains("altera"), "1.ª linha: \(b1.text)")
        check(b2.text.contains("1250"), "2.ª linha: \(b2.text)")
        let expectedW = ("Guardar alterações" as NSString).size(withAttributes: [.font: bold]).width
        check(abs(b1.rect.minX - 60) < 6 && abs(b1.rect.width - Double(expectedW)) < Double(expectedW) * 0.12, "a caixa da 1.ª linha está onde o texto foi desenhado (\(b1.rect), largura esperada \(expectedW))")
        check(b1.rect.minY > 58 && b1.rect.maxY < 110, "a caixa da 1.ª linha está à altura certa (\(b1.rect))")   // draw(at:) põe a base da linha em y=300 de baixo
        check(m.textBlocks.first?.id == b1.id, "ordem de leitura: a linha de cima primeiro")
        // estilo adivinhado
        guard let g1 = m.guessStyle(for: b1), let g2 = m.guessStyle(for: b2) else { return fails + ["sem estilo adivinhado"] }
        let c1 = NSColor(hex: g1.colorHex).usingColorSpace(.sRGB)!
        check(c1.blueComponent > 0.6 && c1.redComponent < 0.35, "cor da 1.ª linha é azul (\(g1.colorHex))")
        check(g1.bold && !g2.bold, "negrito só na 1.ª linha (\(g1.bold), \(g2.bold))")
        check(abs(g1.fontSize - 32) <= 5, "tamanho da 1.ª linha ≈ 32 (\(g1.fontSize))")
        check(abs(g2.fontSize - 24) <= 4, "tamanho da 2.ª linha ≈ 24 (\(g2.fontSize))")
        check(g2.monospaced && !g1.monospaced, "monoespaçada só a 2.ª linha (\(g2.monospaced), \(g1.monospaced))")
        check(g2.fontName == "Menlo" && g1.fontName == nil && !g1.serif, "fontes: Menlo para a 2.ª, sistema para a 1.ª (\(String(describing: g2.fontName)), \(String(describing: g1.fontName)), serifa \(g1.serif))")
        print("OCR-SELFTEST: 1.ª «\(b1.text)» \(g1); 2.ª «\(b2.text)» \(g2); palavras 2.ª: \(b2.words.map { (($0.width * 10).rounded() / 10, $0.chars) }); 1.ª: \(b1.words.map { (($0.width * 10).rounded() / 10, $0.chars) })")
        // copiar
        m.toggleBlock(b2.id, extend: false)
        m.copyCommand()
        check(NSPasteboard.general.string(forType: .string) == b2.text, "⌘C copia a linha marcada")
        m.copyRecognizedText(all: true)
        check(NSPasteboard.general.string(forType: .string) == b1.text + "\n" + b2.text, "copiar tudo junta as linhas por ordem")
        // clicar marca; ⇧ junta; clique fora desmarca
        canvas.debugMouse(at: Point(x: b1.rect.minX + 10, y: b1.rect.minY + b1.rect.height / 2))
        check(m.selectedBlocks == [b1.id], "clique marca a linha")
        canvas.debugMouse(at: Point(x: b2.rect.minX + 10, y: b2.rect.minY + b2.rect.height / 2), shift: true)
        check(m.selectedBlocks == [b1.id, b2.id], "⇧ junta")
        canvas.debugMouse(at: Point(x: 700, y: 380))
        check(m.selectedBlocks.isEmpty, "clique fora desmarca")
        // editar: Reparo + Texto agrupados, com o texto, tamanho e cor adivinhados; a ferramenta passa a Mover
        let n0 = m.doc.annotations.count
        guard let tid = m.editTextBlock(b1.id), let t = m.doc.annotations.first(where: { $0.id == tid }) else { return fails + ["editar não criou a caixa de texto"] }
        check(m.doc.annotations.count == n0 + 2 && m.tool == .select && m.selection == tid, "editar cria 2 objetos, passa a Mover e seleciona o texto")
        check(t.editableString == b1.text && t.style.text.bold && t.style.text.colorHex == g1.colorHex && abs((t.effectiveFontSize ?? 0) - g1.fontSize) < 0.01, "a caixa tem o texto, o negrito, a cor e o tamanho adivinhados")
        let patch = m.doc.annotations.first { $0.id != tid && $0.group == t.group }
        check(patch?.shape.isRepair == true && (patch?.shape.bounds.contains(Point(x: b1.rect.minX + 1, y: b1.rect.minY + 1)) ?? false), "o Reparo agrupado cobre o texto original")
        check(m.textBlocks.count == 1, "a linha editada sai da lista")
        // a caixa de texto desenha as letras por cima do sítio original: a exportação continua a ter tinta azul lá
        if let png = m.exportPNG(), let src = CGImageSourceCreateWithData(png as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            var blueInk = 0
            for x in stride(from: Int(b1.rect.minX), to: Int(b1.rect.maxX), by: 2) { for y in stride(from: Int(b1.rect.minY), to: Int(b1.rect.maxY), by: 2) {
                if let p = pixel(img, x, y), p.b > 150, p.r < 120 { blueInk += 1 }
            } }
            check(blueInk > 40, "o texto reescrito aparece em azul no mesmo sítio (\(blueInk) píxeis)")
        } else { fails.append("sem exportação") }
        m.undo()
        check(m.doc.annotations.count == n0, "desfazer tira os dois objetos de uma vez")
        m.tool = .select
        return fails
    }
}
