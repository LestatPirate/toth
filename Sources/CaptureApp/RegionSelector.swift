// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit

/// Seleção de área sobre um instantâneo "congelado" do ecrã:
/// 1. mostra-se o instantâneo (o que mudar no ecrã a seguir não afeta a captura);
/// 2. arrasta-se para escolher a área, que depois se pode mover e redimensionar;
/// 3. só ao confirmar (botão "Capturar" ou Enter) a imagem recortada segue para o editor. Esc cancela.
@MainActor
final class RegionSelector {
    private var windows: [NSWindow] = []
    private var views: [SelectionView] = []
    private var completion: ((CGImage?) -> Void)?
    var isActive: Bool { completion != nil }
    /// Chamado quando se escolhe a captura com rolagem: ecrã, área (pontos, canto superior esquerdo do ecrã) e a
    /// imagem exata dessa área no instante congelado (é a primeira imagem da captura com rolagem).
    var onScroll: ((NSScreen, CGRect, CGImage) -> Void)?
    /// Chamado quando se escolhe gravar vídeo: ecrã e área (pontos, canto superior esquerdo do ecrã).
    var onVideo: ((NSScreen, CGRect) -> Void)?
    /// Chamado quando se escolhe uma janela (modo «Janela»): a janela e se a captura leva a sombra.
    var onWindow: ((WindowInfo, Bool) -> Void)?
    /// Chamado quando se escolhe gravar uma janela em vídeo.
    var onWindowVideo: ((NSScreen, WindowInfo) -> Void)?
    /// Chamado quando se escolhe «Texto»: a área recortada, para reconhecer o texto (sem abrir o editor).
    var onText: ((CGImage) -> Void)?

    /// `screenWindows`: as janelas de cada ecrã (modo «Janela»; vazio = só área). `windowMode`: começa logo no modo «Janela».
    /// `cleanSnapshots`: por ecrã, o mesmo instante sem papel de parede nem ícones (para o «Fundo limpo»); `nil` = não há.
    func begin(snapshots: [(screen: NSScreen, image: CGImage)], screenWindows: [[WindowInfo]] = [], windowMode: Bool = false, cleanSnapshots: [CGImage?] = [], completion: @escaping (CGImage?) -> Void) {
        guard !isActive else { return }
        MainWindow.hideForCapture()   // antes de ativar o Toth: senão o editor passa por cima da app que se quer capturar
        self.completion = completion
        for (i, (screen, image)) in snapshots.enumerated() {
            let window = SelectionWindow(screen: screen)
            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size), image: image, cleanImage: cleanSnapshots.indices.contains(i) ? cleanSnapshots[i] : nil)
            view.windows = screenWindows.indices.contains(i) ? screenWindows[i] : []
            view.onConfirm = { [weak self] cropped in self?.end(cropped) }
            view.onText = { [weak self] cropped in self?.endText(cropped) }
            view.onCleanChange = { [weak self, weak view] on in self?.views.forEach { if $0 !== view { $0.setClean(on) } } }
            view.onCancel = { [weak self] in self?.end(nil) }
            view.onScroll = { [weak self] rect, first in self?.endScroll(screen: screen, rect: rect, first: first) }
            view.onVideo = { [weak self] rect in self?.endVideo(screen: screen, rect: rect) }
            view.onWindow = { [weak self] info, shadow in self?.endWindow(info, shadow: shadow) }
            view.onWindowVideo = { [weak self] info in self?.endWindowVideo(screen: screen, info: info) }
            view.onModeChange = { [weak self, weak view] on in self?.views.forEach { if $0 !== view { $0.setWindowMode(on) } } }
            if windowMode { view.setWindowMode(true) }
            // Só pode haver uma seleção de cada vez (em qualquer ecrã).
            view.onBeginSelecting = { [weak self, weak view] in self?.views.forEach { if $0 !== view { $0.clearSelection() } } }
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            windows.append(window); views.append(view)
        }
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.crosshair.push()
    }

    private func endScroll(screen: NSScreen, rect: CGRect, first: CGImage) {
        guard completion != nil else { return }
        end(nil)
        onScroll?(screen, rect, first)
    }

    private func endVideo(screen: NSScreen, rect: CGRect) {
        guard completion != nil else { return }
        end(nil)
        onVideo?(screen, rect)
    }

    private func endWindow(_ info: WindowInfo, shadow: Bool) {
        guard completion != nil else { return }
        end(nil)
        onWindow?(info, shadow)
    }

    private func endText(_ image: CGImage) {
        guard completion != nil else { return }
        end(nil)
        onText?(image)
    }

    private func endWindowVideo(screen: NSScreen, info: WindowInfo) {
        guard completion != nil else { return }
        end(nil)
        onWindowVideo?(screen, info)
    }

    private func end(_ image: CGImage?) {
        guard completion != nil else { return }
        NSCursor.pop()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll(); views.removeAll()
        let done = completion
        completion = nil
        done?(image)
    }

    /// Para testes visuais: desenha o seletor (com uma área já escolhida) fora do ecrã e grava um PNG.
    /// Com `windows`, desenha o modo «Janela» com a 1.ª janela sob o rato.
    static func renderForTests(image: CGImage, size: CGSize, selection: CGRect, windows: [WindowInfo] = [], to path: String) {
        let view = SelectionView(frame: CGRect(origin: .zero, size: size), image: image)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.makeKeyAndOrderFront(nil)
        if windows.isEmpty { view.debugSelect(selection) } else { view.windows = windows; view.setWindowMode(true); view.debugHover(windows[0].frame.origin.applying(.init(translationX: 20, y: 20))) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Para testes: cancela a seleção em curso.
    func cancelForTests() { end(nil) }
    /// Para testes: pré-seleciona uma área (coordenadas da vista do 1.º ecrã, origem no canto superior esquerdo).
    func debugPreselect(_ rect: CGRect) { views.first?.debugSelect(rect) }
    /// Para testes: escolhe «Vídeo» como se se clicasse no botão.
    func debugVideo() { views.first?.debugVideoClick() }
    /// Para testes: escolhe «Rolagem» como se se clicasse no botão.
    func debugScroll() { views.first?.debugScrollClick() }
    /// Para testes: confirma a seleção atual como se se carregasse em Enter.
    func debugConfirm() { views.first?.confirm() }
    /// Para testes: passa ao modo «Janela» e escolhe a janela sob o ponto (coordenadas da vista do 1.º ecrã).
    func debugPickWindow(at p: CGPoint) { views.first?.setWindowMode(true); views.first?.debugHover(p); views.first?.debugClickWindow() }
    /// Para testes: o quadro automático sob o ponto.
    func debugFrame(at p: CGPoint) -> CGRect? { views.first?.debugFrame(at: p) }
    /// Para testes: «Texto» como se se clicasse no botão.
    func debugText() { views.first?.debugTextClick() }
    /// Para testes: liga/desliga o «Fundo limpo».
    func debugClean(_ on: Bool) { views.first?.setClean(on) }
    /// Para testes: arrasta a partir de um ponto (coordenadas da vista) até outro, como com o rato.
    func debugDrag(from a: CGPoint, to b: CGPoint) { views.first?.debugDrag(from: a, to: b) }

    /// Autoteste do seletor sobre uma imagem sintética: quadro automático, bordas, lupa, texto e fundo limpo.
    static func selfTest() -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { fails.append(what) } }
        // imagem 2× de um ecrã de 1000×640 pontos: fundo em gradiente, um painel branco (120,80)-(520,380) com texto e um botão azul lá dentro
        let size = CGSize(width: 1000, height: 640)
        let img = NSImage(size: NSSize(width: 2000, height: 1280), flipped: true) { r in
            NSGradient(colors: [.systemTeal, .systemIndigo])!.draw(in: r, angle: 35)
            NSColor.white.setFill(); NSRect(x: 240, y: 160, width: 800, height: 600).fill()
            NSColor.systemBlue.setFill(); NSRect(x: 300, y: 600, width: 240, height: 100).fill()
            ("Fatura 2026 aprovada" as NSString).draw(at: NSPoint(x: 300, y: 220), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 44), .foregroundColor: NSColor.black])
            return true
        }.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let clean = NSImage(size: NSSize(width: 2000, height: 1280), flipped: true) { r in NSColor(srgbRed: 0.91, green: 0.91, blue: 0.92, alpha: 1).setFill(); r.fill(); return true }.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let view = SelectionView(frame: CGRect(origin: .zero, size: size), image: img, cleanImage: clean)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view; window.setFrameOrigin(NSPoint(x: -30000, y: -30000)); window.makeKeyAndOrderFront(nil)
        // 1) quadro automático: no fundo do painel branco dá o painel; no botão dá o botão; no gradiente, nada
        let panel = view.debugFrame(at: CGPoint(x: 200, y: 200))
        check(panel.map { abs($0.minX - 120) <= 2 && abs($0.minY - 80) <= 2 && abs($0.maxX - 520) <= 2 && abs($0.maxY - 380) <= 2 } ?? false, "o quadro automático apanha o painel branco (\(String(describing: panel)))")
        let button = view.debugFrame(at: CGPoint(x: 200, y: 330))
        check(button.map { abs($0.minX - 150) <= 2 && abs($0.minY - 300) <= 2 && abs($0.width - 120) <= 3 && abs($0.height - 50) <= 3 } ?? false, "no botão azul apanha o botão (\(String(describing: button)))")
        let text = view.debugFrame(at: CGPoint(x: 160, y: 128))
        check(text.map { abs($0.minX - 120) <= 2 && abs($0.maxX - 520) <= 2 } ?? false, "em cima do texto apanha o painel à volta (\(String(describing: text)))")
        check(view.debugFrame(at: CGPoint(x: 40, y: 40)) == nil, "no gradiente não há quadro")
        // Enter com o quadro: captura-o
        var got: CGImage?
        view.onConfirm = { got = $0 }
        view.debugHoverFrame(at: CGPoint(x: 200, y: 200)); view.debugEnter()
        check(got.map { abs($0.width - 800) <= 4 && abs($0.height - 600) <= 4 } ?? false, "Enter captura o quadro automático (\(got.map { "\($0.width)×\($0.height)" } ?? "nada"))")
        // 2) redimensionar pela borda (não só pelas alças): arrastar do meio da borda direita
        view.debugSelect(CGRect(x: 100, y: 100, width: 300, height: 200))
        view.debugDrag(from: CGPoint(x: 400, y: 150), to: CGPoint(x: 450, y: 150))   // (150 não é o meio: 200)
        check(view.debugSelection == CGRect(x: 100, y: 100, width: 350, height: 200), "arrastar a borda direita redimensiona (\(String(describing: view.debugSelection)))")
        view.debugDrag(from: CGPoint(x: 250, y: 300), to: CGPoint(x: 250, y: 320))
        check(view.debugSelection == CGRect(x: 100, y: 100, width: 350, height: 220), "arrastar a borda de baixo redimensiona (\(String(describing: view.debugSelection)))")
        view.debugDrag(from: CGPoint(x: 250, y: 200), to: CGPoint(x: 260, y: 210))
        check(view.debugSelection == CGRect(x: 110, y: 110, width: 350, height: 220), "arrastar de dentro move (\(String(describing: view.debugSelection)))")
        // 3) lupa: enquanto se arrasta, desenha-se uma lupa com os píxeis junto ao cursor
        view.debugBeginDrag(at: CGPoint(x: 500, y: 400))
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return fails + ["sem render"] }
        view.cacheDisplay(in: view.bounds, to: rep)
        let loupe = view.debugLoupeRect
        check(loupe.map { !$0.isNull && rep.colorAt(x: Int($0.midX), y: Int($0.midY)) != nil } ?? false, "a lupa desenha-se junto ao cursor (\(String(describing: loupe)))")
        if let l = loupe {
            // no centro da lupa está o píxel do cursor (gradiente, nem branco nem preto) e a cruz; nos cantos, o aro
            let c = rep.colorAt(x: Int(l.midX) + 3, y: Int(l.midY) + 3)?.usingColorSpace(.sRGB)
            check(c.map { $0.brightnessComponent > 0.1 && $0.brightnessComponent < 0.98 } ?? false, "o centro da lupa mostra o píxel ampliado")
        }
        view.debugEndDrag()
        // 4) «Texto»: entrega a área recortada; «Fundo limpo»: o recorte vem da imagem limpa
        var textImage: CGImage?
        view.onText = { textImage = $0 }
        view.debugSelect(CGRect(x: 120, y: 80, width: 400, height: 300))
        view.debugTextClick()
        check(textImage.map { $0.width == 800 && $0.height == 600 } ?? false, "«Texto» entrega a área recortada em píxeis nativos")
        view.setClean(true)
        got = nil; view.confirm()
        if let g = got, let px = SelfTests.pixel(g, 10, 10) { check(px.r > 225 && px.g > 225 && px.b > 225 && px.r < 240, "com Fundo limpo o recorte vem da imagem limpa (\(px))") } else { fails.append("sem recorte com Fundo limpo") }
        view.setClean(false)
        got = nil; view.confirm()
        if let g = got, let px = SelfTests.pixel(g, 10, 10) { check(px.r > 250 && px.g > 250, "sem Fundo limpo o recorte vem da imagem normal (\(px))") }
        // 5) dica do botão: desenha-se na vista ao passar o rato (as do sistema não aparecem nesta janela) e não entra na captura
        view.debugSelect(CGRect(x: 120, y: 80, width: 400, height: 300))
        view.debugHover(button: 3)   // Fundo limpo
        check(view.debugHint?.hasPrefix("Fundo limpo") == true, "a dica do botão é a do Fundo limpo (\(String(describing: view.debugHint)))")
        guard let rep2 = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return fails + ["sem render da dica"] }
        view.cacheDisplay(in: view.bounds, to: rep2)
        // por baixo da barra do topo (y ≈ 14+bar+8…) há um balão escuro
        var dark = 0
        for y in 60..<110 { for x in 400..<600 { if let c = rep2.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.brightnessComponent < 0.25 { dark += 1 } } }
        check(dark > 800, "o balão da dica desenha-se por baixo da barra (\(dark) píxeis escuros)")
        got = nil; view.confirm()
        if let g = got, let px = SelfTests.pixel(g, 400, 10) { check(px.r > 250 && px.g > 250, "a dica não sai na captura") }
        view.debugHover(button: 99)
        check(view.debugHint == nil, "sem rato em cima, sem dica")
        window.orderOut(nil)
        return fails
    }
}

private final class SelectionWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]   // aparece sobre o ecrã atual sem mudar de Espaço
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isReleasedWhenClosed = false
    }
    override var canBecomeKey: Bool { true }
}

private final class SelectionView: NSView {
    let image: CGImage
    var onConfirm: ((CGImage) -> Void)?
    var onCancel: (() -> Void)?
    var onBeginSelecting: (() -> Void)?
    var onScroll: ((CGRect, CGImage) -> Void)?
    var onVideo: ((CGRect) -> Void)?
    var onWindow: ((WindowInfo, Bool) -> Void)?
    var onWindowVideo: ((WindowInfo) -> Void)?
    var onModeChange: ((Bool) -> Void)?
    var onText: ((CGImage) -> Void)?
    var onCleanChange: ((Bool) -> Void)?

    private enum Mode { case idle, drawing(anchor: CGPoint), moving(offset: CGSize), resizing(handle: Int, original: CGRect) }
    private var mode: Mode = .idle
    private var selection: CGRect?
    /// «Fundo limpo»: o mesmo instante sem papel de parede nem ícones (`nil` = não está disponível).
    let cleanImage: CGImage?
    private(set) var cleanOn = (UserDefaults.standard.object(forKey: "captureCleanDesktop") as? Bool) ?? false
    /// A imagem em uso (normal ou limpa).
    private var currentImage: CGImage { cleanOn ? (cleanImage ?? image) : image }
    /// Quadro automático: o retângulo do conteúdo sob o rato (painel, botão, janela), aceite com Enter ou um clique.
    private var smartOn = (UserDefaults.standard.object(forKey: "captureSmartFrame") as? Bool) ?? true
    private var hoverFrame: CGRect?
    private var detector: FrameDetector?
    /// Onde está o rato (para a lupa).
    private var cursor: CGPoint?
    private var cleanButton: IconButton!
    private var smartButton: IconButton!
    private var textButton: IconButton!

    // Modo «Janela»: a janela sob o rato fica em destaque; um clique captura-a (só ela, mesmo tapada), com ou sem sombra.
    var windows: [WindowInfo] = []
    private(set) var windowMode = false
    private var hoverWindow: WindowInfo?
    private var shadowOn = (UserDefaults.standard.object(forKey: "windowCaptureShadow") as? Bool) ?? true
    private let modeBar = IconBar()
    private var areaModeButton: IconButton!
    private var windowModeButton: IconButton!
    private var shadowButton: IconButton!
    private var windowVideoButton: IconButton!
    private var tracking: NSTrackingArea?

    // Barra de ícones: cancelar · rolagem · vídeo · capturar
    private let bar = IconBar()
    private var cancelButton: IconButton!
    private var scrollButton: IconButton!
    private var videoButton: IconButton!
    private var confirmButton: IconButton!

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(frame: CGRect, image: CGImage, cleanImage: CGImage? = nil) {
        self.image = image
        self.cleanImage = cleanImage
        super.init(frame: frame)
        cancelButton = IconButton(symbol: "xmark", tooltip: L("Cancelar (Esc)"), target: self, action: #selector(cancelClicked))
        scrollButton = IconButton(symbol: "arrow.up.and.down.text.horizontal", tooltip: L("Captura com rolagem: depois role a janela como quiser e clique em ✓"), target: self, action: #selector(scrollClicked))
        videoButton = IconButton(symbol: "video.fill", tooltip: L("Gravar vídeo desta área (MP4), com áudio do sistema e microfone opcionais"), target: self, action: #selector(videoClicked))
        textButton = IconButton(symbol: "text.viewfinder", tooltip: L("Texto: reconhece o texto desta área e copia-o (sem abrir o editor)"), target: self, action: #selector(textClicked))
        confirmButton = IconButton(symbol: "camera.fill", tooltip: L("Capturar (Enter)"), target: self, action: #selector(confirmClicked))
        confirmButton.prominent = true
        bar.setItems([cancelButton, IconBar.separator(), scrollButton, videoButton, textButton, IconBar.separator(), confirmButton])
        bar.isHidden = true
        addSubview(bar)
        // barra do modo (sempre visível, no topo): área · janela · sombra · gravar a janela
        areaModeButton = IconButton(symbol: "rectangle.dashed", tooltip: L("Área: arraste para escolher (Espaço alterna)"), target: self, action: #selector(areaModeClicked))
        windowModeButton = IconButton(symbol: "macwindow", tooltip: L("Janela: clique numa janela para a capturar só a ela (Espaço alterna)"), target: self, action: #selector(windowModeClicked))
        shadowButton = IconButton(symbol: "square.on.square.dashed", tooltip: L("Incluir a sombra da janela"), target: self, action: #selector(shadowClicked))
        windowVideoButton = IconButton(symbol: "video.fill", tooltip: L("Gravar a janela sob o rato em vídeo (MP4)"), target: self, action: #selector(windowVideoClicked))
        smartButton = IconButton(symbol: "viewfinder.rectangular", tooltip: L("Quadro automático: o painel, botão ou janela sob o rato fica marcado; Enter ou um clique captura-o"), target: self, action: #selector(smartClicked))
        cleanButton = IconButton(symbol: "rectangle.dashed.badge.record", tooltip: L("Fundo limpo: a captura sai sem papel de parede nem ícones do ambiente de trabalho"), target: self, action: #selector(cleanClicked))
        addSubview(modeBar)
        rebuildModeBar()
        // a dica de cada botão desenha-se nesta vista (as dicas do sistema ficam por baixo desta janela e não se veem)
        for b in [cancelButton, scrollButton, videoButton, textButton, confirmButton, areaModeButton, windowModeButton, shadowButton, windowVideoButton, smartButton, cleanButton] as [IconButton] {
            b.onHover = { [weak self, weak b] on in self?.hint = on ? b : nil }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// O botão com o rato em cima (a dica dele desenha-se por baixo da barra).
    private var hint: IconButton? { didSet { if hint !== oldValue { needsDisplay = true } } }
    var debugHint: String? { hint?.toolTip }
    func debugHover(button index: Int) { let all: [IconButton] = [areaModeButton, windowModeButton, smartButton, cleanButton, cancelButton, scrollButton, videoButton, textButton, confirmButton]; hint = all.indices.contains(index) ? all[index] : nil }

    /// Dica do botão sob o rato: um balão escuro por baixo (ou por cima) da barra onde ele está.
    private func drawHint(_ ctx: CGContext) {
        guard let b = hint, let text = b.toolTip, !text.isEmpty, let bar = b.superview, !bar.isHidden else { return }
        let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 12)]
        let maxW: CGFloat = 360
        let bounded = (text as NSString).boundingRect(with: NSSize(width: maxW, height: 200), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs)
        let barFrame = convert(bar.bounds, from: bar)
        let buttonFrame = convert(b.bounds, from: b)
        var pill = CGRect(x: buttonFrame.midX - bounded.width / 2 - 9, y: barFrame.maxY + 8, width: bounded.width + 18, height: bounded.height + 12)
        pill.origin.x = max(8, min(bounds.width - pill.width - 8, pill.minX))
        if pill.maxY > bounds.height - 8 { pill.origin.y = barFrame.minY - pill.height - 8 }
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.82).cgColor)
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 7, cornerHeight: 7, transform: nil)); ctx.fillPath()
        // seta pequena a apontar para o botão
        let tipX = max(pill.minX + 10, min(pill.maxX - 10, buttonFrame.midX))
        let up = pill.minY > barFrame.maxY
        ctx.move(to: CGPoint(x: tipX - 6, y: up ? pill.minY : pill.maxY)); ctx.addLine(to: CGPoint(x: tipX, y: up ? pill.minY - 6 : pill.maxY + 6)); ctx.addLine(to: CGPoint(x: tipX + 6, y: up ? pill.minY : pill.maxY)); ctx.closePath(); ctx.fillPath()
        (text as NSString).draw(in: CGRect(x: pill.minX + 9, y: pill.minY + 6, width: bounded.width + 1, height: bounded.height + 1), withAttributes: attrs)
    }

    override func layout() { super.layout(); modeBar.setFrameOrigin(CGPoint(x: (bounds.width - modeBar.frame.width) / 2, y: 14)) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }

    // MARK: Modo «Janela»

    private func rebuildModeBar() {
        areaModeButton.prominent = !windowMode
        windowModeButton.prominent = windowMode
        shadowButton.tint = shadowOn ? nil : .secondaryLabelColor
        shadowButton.toolTip = shadowOn ? L("Sombra da janela: incluída") : L("Sombra da janela: sem sombra")
        smartButton.tint = smartOn ? nil : .secondaryLabelColor
        cleanButton.tint = cleanOn ? .systemGreen : .secondaryLabelColor
        cleanButton.isEnabled = cleanImage != nil
        cleanButton.toolTip = cleanImage == nil ? L("Fundo limpo: não disponível nesta captura") : (cleanOn ? L("Fundo limpo: ligado (sem papel de parede nem ícones)") : L("Fundo limpo: desligado"))
        var items: [NSView] = [areaModeButton, windowModeButton]
        if windowMode { items += [IconBar.separator(), shadowButton, windowVideoButton] }
        else { items += [IconBar.separator(), smartButton, cleanButton] }
        modeBar.setItems(items)
        modeBar.setFrameOrigin(CGPoint(x: (bounds.width - modeBar.frame.width) / 2, y: 14))
        modeBar.isHidden = false
    }

    /// «Fundo limpo» ligado/desligado (em todos os ecrãs).
    func setClean(_ on: Bool) {
        guard on != cleanOn, cleanImage != nil || !on else { return }
        cleanOn = on
        UserDefaults.standard.set(on, forKey: "captureCleanDesktop")
        detector = nil
        rebuildModeBar(); needsDisplay = true
    }
    @objc private func cleanClicked() { setClean(!cleanOn); onCleanChange?(cleanOn) }
    @objc private func smartClicked() { smartOn.toggle(); UserDefaults.standard.set(smartOn, forKey: "captureSmartFrame"); hoverFrame = nil; rebuildModeBar(); needsDisplay = true }
    @objc private func textClicked() { guard let c = crop() else { return }; onText?(c.image) }
    func debugTextClick() { textClicked() }

    // MARK: Quadro automático

    /// O retângulo do conteúdo sob `p` (em pontos): a zona de cor uniforme à volta (painel, botão, campo), limitada à janela
    /// que lá está; em cima de texto ou ícones, a zona à volta deles. `nil` se for o fundo todo ou nada de jeito.
    private func frame(at p: CGPoint) -> CGRect? {
        if detector == nil { detector = FrameDetector(image: currentImage, pointSize: bounds.size) }
        guard let d = detector else { return nil }
        let limit = window(at: p)?.frame.intersection(bounds) ?? bounds
        return d.frame(at: p, within: limit)
    }
    func debugFrame(at p: CGPoint) -> CGRect? { frame(at: p) }
    func debugHoverFrame(at p: CGPoint) { hoverFrame = frame(at: p); needsDisplay = true }
    func debugEnter() { keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!) }
    var debugSelection: CGRect? { selection }
    var debugLoupeRect: CGRect? { loupeRect }
    func debugDrag(from a: CGPoint, to b: CGPoint) { debugBeginDrag(at: a); dragTo(b); debugEndDrag() }
    func debugBeginDrag(at a: CGPoint) { pressed(at: a) }
    func debugEndDrag() { released() }

    func setWindowMode(_ on: Bool) {
        guard on != windowMode else { return }
        windowMode = on
        if on { selection = nil; mode = .idle; layoutButtons() } else { hoverWindow = nil }
        rebuildModeBar(); needsDisplay = true
    }
    @objc private func areaModeClicked() { setWindowMode(false); onModeChange?(false) }
    @objc private func windowModeClicked() { setWindowMode(true); onModeChange?(true) }
    @objc private func shadowClicked() { shadowOn.toggle(); UserDefaults.standard.set(shadowOn, forKey: "windowCaptureShadow"); rebuildModeBar() }
    @objc private func windowVideoClicked() { if let w = hoverWindow { onWindowVideo?(w) } }

    private func window(at p: CGPoint) -> WindowInfo? { windows.first { $0.frame.contains(p) } }   // da frente para trás

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        cursor = p
        if windowMode {
            let w = modeBar.frame.contains(p) ? hoverWindow : window(at: p)
            if w != hoverWindow { hoverWindow = w; needsDisplay = true }
            return
        }
        // o cursor diz o que um arrasto faria: alça, borda, mover, ou desenhar
        if let sel = selection, case .idle = mode {
            if let h = handle(at: p, in: sel) { ([0, 4].contains(h) ? NSCursor.crosshair : [2, 6].contains(h) ? NSCursor.crosshair : [1, 5].contains(h) ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).set() }
            else if sel.contains(p) { NSCursor.openHand.set() }
            else { NSCursor.crosshair.set() }
        } else { NSCursor.crosshair.set() }
        // quadro automático: só sem seleção (depois de escolher uma área, deixa de incomodar)
        if smartOn, selection == nil, case .idle = mode, !modeBar.frame.contains(p) {
            let f = frame(at: p)
            if f != hoverFrame { hoverFrame = f; needsDisplay = true }
        } else if hoverFrame != nil { hoverFrame = nil; needsDisplay = true }
    }

    /// Alça (0…7) ou borda sob o ponto: as alças têm prioridade; depois, qualquer ponto a ≤ 6 pt de uma borda, ao longo dela toda.
    private func handle(at p: CGPoint, in sel: CGRect) -> Int? {
        if let h = handles(sel).firstIndex(where: { abs($0.x - p.x) <= 10 && abs($0.y - p.y) <= 10 }) { return h }
        let tol: CGFloat = 6
        let alongX = p.x >= sel.minX - tol && p.x <= sel.maxX + tol, alongY = p.y >= sel.minY - tol && p.y <= sel.maxY + tol
        if alongX && abs(p.y - sel.minY) <= tol { return 1 }
        if alongX && abs(p.y - sel.maxY) <= tol { return 5 }
        if alongY && abs(p.x - sel.maxX) <= tol { return 3 }
        if alongY && abs(p.x - sel.minX) <= tol { return 7 }
        return nil
    }
    func debugHover(_ p: CGPoint) { hoverWindow = window(at: p); needsDisplay = true }
    func debugClickWindow() { if let w = hoverWindow { onWindow?(w, shadowOn) } }

    // MARK: Seleção

    func clearSelection() { selection = nil; mode = .idle; layoutButtons(); needsDisplay = true }
    func debugScrollClick() { scrollClicked() }
    func debugVideoClick() { videoClicked() }
    func debugSelect(_ r: CGRect) { selection = r; layoutButtons(); needsDisplay = true }

    @objc private func confirmClicked() { confirm() }
    @objc private func cancelClicked() { onCancel?() }

    @objc private func videoClicked() {
        guard let sel = selection, sel.width >= 2, sel.height >= 2 else { return }
        onVideo?(sel)
    }

    @objc private func scrollClicked() {
        guard let c = crop() else { return }
        onScroll?(c.points, c.image)
    }

    /// Recorta o instantâneo (não o ecrã atual) à área escolhida.
    func confirm() {
        guard let c = crop() else { return }
        onConfirm?(c.image)
    }

    /// A área escolhida recortada do instantâneo (píxeis inteiros) e a mesma área em pontos do ecrã, ajustada a esses
    /// píxeis: é o que garante que as imagens seguintes da captura com rolagem têm exatamente o mesmo tamanho.
    private func crop() -> (image: CGImage, points: CGRect)? {
        guard let sel = selection, sel.width >= 2, sel.height >= 2 else { return nil }
        let image = currentImage
        let k = CGFloat(image.width) / bounds.width
        let px = CGRect(x: sel.minX * k, y: sel.minY * k, width: sel.width * k, height: sel.height * k)
            .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let cropped = image.cropping(to: px) else { return nil }
        return (cropped, CGRect(x: px.minX / k, y: px.minY / k, width: px.width / k, height: px.height / k))
    }

    // 8 alças: tl, t, tr, r, br, b, bl, l
    private func handles(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY),
         CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
    }

    private func resized(_ r: CGRect, handle h: Int, to p: CGPoint) -> CGRect {
        var x0 = r.minX, y0 = r.minY, x1 = r.maxX, y1 = r.maxY
        if [0, 6, 7].contains(h) { x0 = p.x }
        if [2, 3, 4].contains(h) { x1 = p.x }
        if [0, 1, 2].contains(h) { y0 = p.y }
        if [4, 5, 6].contains(h) { y1 = p.y }
        return CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0)).intersection(bounds)
    }

    // MARK: Rato

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        if windowMode {
            if let w = window(at: p) { hoverWindow = w; onWindow?(w, shadowOn) }
            return
        }
        pressed(at: p)
    }

    private func pressed(at p: CGPoint) {
        cursor = p
        if let sel = selection {
            if let h = handle(at: p, in: sel) {
                mode = .resizing(handle: h, original: sel); layoutButtons(); needsDisplay = true; return
            }
            if sel.contains(p) {
                mode = .moving(offset: CGSize(width: p.x - sel.minX, height: p.y - sel.minY)); layoutButtons(); return
            }
        }
        onBeginSelecting?()
        selection = nil
        mode = .drawing(anchor: p)
        layoutButtons(); needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !windowMode else { return }
        dragTo(convert(event.locationInWindow, from: nil))
    }

    private func dragTo(_ p: CGPoint) {
        cursor = p
        switch mode {
        case let .drawing(a):
            selection = CGRect(x: min(a.x, p.x), y: min(a.y, p.y), width: abs(a.x - p.x), height: abs(a.y - p.y)).intersection(bounds)
        case let .moving(off):
            if let s = selection {
                var o = CGPoint(x: p.x - off.width, y: p.y - off.height)
                o.x = max(0, min(bounds.width - s.width, o.x)); o.y = max(0, min(bounds.height - s.height, o.y))
                selection = CGRect(origin: o, size: s.size)
            }
        case let .resizing(h, original):
            selection = resized(original, handle: h, to: p)
        case .idle: break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) { released() }

    private func released() {
        if let s = selection, s.width < 4 || s.height < 4 {
            // clique sem arrastar: escolhe o quadro automático, se o houver; senão, sem seleção
            selection = hoverFrame
        }
        if selection != nil { hoverFrame = nil }
        mode = .idle
        layoutButtons(); needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:   // Enter / Enter do teclado numérico: a área escolhida ou, sem ela, o quadro automático
            if windowMode { debugClickWindow() }
            else { if selection == nil, let f = hoverFrame { selection = f; hoverFrame = nil }; confirm() }
        case 53: onCancel?()            // Esc
        case 49: setWindowMode(!windowMode); onModeChange?(windowMode)   // Espaço: área ↔ janela
        default: super.keyDown(with: event)
        }
    }

    // MARK: Botões e desenho

    private func layoutButtons() {
        guard let sel = selection, case .idle = mode else { bar.isHidden = true; return }
        bar.isHidden = false
        let w = bar.frame.width, h = bar.frame.height
        var x = min(max(8, sel.maxX - w), bounds.width - w - 8)
        // por baixo da seleção; se não couber, por cima; se também não, dentro
        var y = sel.maxY + 10
        if y + h > bounds.height - 8 { y = sel.minY - h - 10 }
        if y < 8 { y = max(8, sel.maxY - h - 10); x = max(8, sel.maxX - w - 10) }
        bar.setFrameOrigin(CGPoint(x: x, y: y))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // instantâneo congelado (a vista é "flipped": desvira a imagem)
        ctx.saveGState()
        ctx.translateBy(x: 0, y: bounds.height); ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(currentImage, in: bounds)
        ctx.restoreGState()

        if windowMode {
            // escurece tudo menos a janela sob o rato, com contorno e o nome da app
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
            ctx.addRect(bounds)
            if let w = hoverWindow { ctx.addRect(w.frame.intersection(bounds)) }
            ctx.fillPath(using: .evenOdd)
            guard let w = hoverWindow else { drawHint(ctx); return }
            let r = w.frame.intersection(bounds)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor); ctx.setLineWidth(3)
            ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 8, cornerHeight: 8, transform: nil)); ctx.strokePath()
            let k = CGFloat(image.width) / bounds.width
            let name = w.title.isEmpty ? w.app : "\(w.app) · \(w.title)"
            let label = "\(name)  \(Int((w.frame.width * k).rounded())) × \(Int((w.frame.height * k).rounded()))" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 12, weight: .medium)]
            let size = label.size(withAttributes: attrs)
            let pill = CGRect(x: r.minX, y: max(2, r.minY - size.height - 10), width: min(size.width + 14, bounds.width - r.minX - 4), height: size.height + 6)
            ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor)
            ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 5, cornerHeight: 5, transform: nil)); ctx.fillPath()
            label.draw(in: CGRect(x: pill.minX + 7, y: pill.minY + 3, width: pill.width - 10, height: size.height), withAttributes: attrs)
            drawHint(ctx)
            return
        }
        // escurece fora da seleção
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.addRect(bounds)
        if let sel = selection { ctx.addRect(sel) }
        ctx.fillPath(using: .evenOdd)

        guard let sel = selection else { drawHoverFrame(ctx); drawHint(ctx); return }
        ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(1)
        ctx.stroke(sel.insetBy(dx: 0.5, dy: 0.5))
        if case .idle = mode {
            for h in handles(sel) {
                let r = CGRect(x: h.x - 4, y: h.y - 4, width: 8, height: 8)
                ctx.setFillColor(NSColor.white.cgColor); ctx.fill(r)
                ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.5).cgColor); ctx.stroke(r)
            }
        }
        // dimensões em pixels reais
        let k = CGFloat(image.width) / bounds.width
        let label = "\(Int((sel.width * k).rounded())) × \(Int((sel.height * k).rounded()))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.white, .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)]
        let size = label.size(withAttributes: attrs)
        let pill = CGRect(x: sel.minX, y: max(2, sel.minY - size.height - 8), width: size.width + 12, height: size.height + 4)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor)
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 4, cornerHeight: 4, transform: nil)); ctx.fillPath()
        label.draw(at: CGPoint(x: pill.minX + 6, y: pill.minY + 2), withAttributes: attrs)
        drawLoupe(ctx)
        drawHint(ctx)
    }

    /// O quadro automático: contorno tracejado da cor de destaque, com o tamanho e a dica «Enter».
    private func drawHoverFrame(_ ctx: CGContext) {
        guard let f = hoverFrame, case .idle = mode else { return }
        ctx.saveGState()
        ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor); ctx.fill(f)
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor); ctx.setLineWidth(2); ctx.setLineDash(phase: 0, lengths: [6, 4])
        ctx.stroke(f.insetBy(dx: 1, dy: 1))
        ctx.restoreGState()
        let k = CGFloat(currentImage.width) / bounds.width
        let label = "\(Int((f.width * k).rounded())) × \(Int((f.height * k).rounded()))  ·  Enter" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.white, .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)]
        let size = label.size(withAttributes: attrs)
        var pill = CGRect(x: f.minX, y: f.minY - size.height - 8, width: size.width + 12, height: size.height + 4)
        if pill.minY < 2 { pill.origin.y = f.minY + 4 }
        ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor)
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 4, cornerHeight: 4, transform: nil)); ctx.fillPath()
        label.draw(at: CGPoint(x: pill.minX + 6, y: pill.minY + 2), withAttributes: attrs)
    }

    // MARK: Lupa

    private let loupeSize: CGFloat = 132   // pontos
    private let loupePixels = 11           // píxeis nativos de lado
    /// Onde a lupa se desenha enquanto se arrasta uma borda ou se desenha a área (`nil` = não se mostra).
    private var loupeRect: CGRect? {
        guard let c = cursor else { return nil }
        switch mode { case .drawing, .resizing: break; default: return nil }
        var x = c.x + 24, y = c.y + 24
        if x + loupeSize > bounds.width - 8 { x = c.x - 24 - loupeSize }
        if y + loupeSize > bounds.height - 8 { y = c.y - 24 - loupeSize }
        return CGRect(x: x, y: y, width: loupeSize, height: loupeSize)
    }

    /// Lupa: os `loupePixels` × `loupePixels` píxeis nativos à volta do cursor, ampliados, com uma cruz no píxel do cursor
    /// e as coordenadas em píxeis. Serve para acertar os limites ao píxel.
    private func drawLoupe(_ ctx: CGContext) {
        guard let r = loupeRect, let c = cursor else { return }
        let image = currentImage
        let k = CGFloat(image.width) / bounds.width
        let px = Int((c.x * k).rounded(.down)), py = Int((c.y * k).rounded(.down))
        let half = loupePixels / 2
        let src = CGRect(x: px - half, y: py - half, width: loupePixels, height: loupePixels)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 10, cornerHeight: 10, transform: nil)); ctx.clip()
        ctx.setFillColor(NSColor.black.cgColor); ctx.fill(r)
        if let part = image.cropping(to: src.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))) {
            // (a parte pode ficar menor junto às bordas do ecrã: desenha-se no sítio certo da grelha)
            let visible = src.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let cell = loupeSize / CGFloat(loupePixels)
            let dest = CGRect(x: r.minX + (visible.minX - src.minX) * cell, y: r.minY + (visible.minY - src.minY) * cell, width: visible.width * cell, height: visible.height * cell)
            ctx.saveGState()
            ctx.interpolationQuality = .none
            ctx.translateBy(x: 0, y: dest.minY + dest.maxY); ctx.scaleBy(x: 1, y: -1)
            ctx.draw(part, in: dest)
            ctx.restoreGState()
        }
        // grelha fina e a cruz no píxel do cursor
        let cell = loupeSize / CGFloat(loupePixels)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor); ctx.setLineWidth(0.5)
        for i in 1..<loupePixels { let t = CGFloat(i) * cell; ctx.move(to: CGPoint(x: r.minX + t, y: r.minY)); ctx.addLine(to: CGPoint(x: r.minX + t, y: r.maxY)); ctx.move(to: CGPoint(x: r.minX, y: r.minY + t)); ctx.addLine(to: CGPoint(x: r.maxX, y: r.minY + t)) }
        ctx.strokePath()
        let center = CGRect(x: r.minX + CGFloat(half) * cell, y: r.minY + CGFloat(half) * cell, width: cell, height: cell)
        ctx.setStrokeColor(NSColor.systemRed.cgColor); ctx.setLineWidth(1.5); ctx.stroke(center)
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(1.5)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 10, cornerHeight: 10, transform: nil)); ctx.strokePath()
        let label = "\(px), \(py)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.white, .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)]
        let size = label.size(withAttributes: attrs)
        let pill = CGRect(x: r.midX - size.width / 2 - 5, y: r.maxY + 4, width: size.width + 10, height: size.height + 2)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor)
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 4, cornerHeight: 4, transform: nil)); ctx.fillPath()
        label.draw(at: CGPoint(x: pill.minX + 5, y: pill.minY + 1), withAttributes: attrs)
    }
}

/// Deteta o retângulo do conteúdo sob um ponto, pelos píxeis do instantâneo: a zona de cor parecida à volta do ponto (o
/// fundo de um painel, um botão, um campo), com uma cópia reduzida da imagem para ser rápido a cada movimento do rato.
private struct FrameDetector {
    let w: Int, h: Int
    let rgb: [UInt8]
    /// Pontos por píxel da cópia reduzida.
    let scale: CGFloat

    init?(image: CGImage, pointSize: CGSize) {
        // cópia a meio ponto por píxel (um ecrã de 1440 pt → 720 px): chega para painéis e botões
        let k: CGFloat = 0.5
        w = max(8, Int(pointSize.width * k)); h = max(8, Int(pointSize.height * k))
        scale = pointSize.width / CGFloat(w)
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        rgb = buf
    }

    private func px(_ x: Int, _ y: Int) -> (Int, Int, Int) { let o = (y * w + x) * 4; return (Int(rgb[o]), Int(rgb[o + 1]), Int(rgb[o + 2])) }   // (a 1.ª fila em memória é a de cima)

    /// Caixa (em pontos) da zona de cor uniforme à volta do ponto, limitada a `limit`. Sobre texto ou ícones (zonas
    /// minúsculas) experimenta pontos à volta e fica com a maior caixa que contenha o ponto. `nil` se for quase o limite todo.
    func frame(at p: CGPoint, within limit: CGRect) -> CGRect? {
        let lx0 = max(0, Int(limit.minX / scale)), ly0 = max(0, Int(limit.minY / scale))
        let lx1 = min(w - 1, Int(limit.maxX / scale) - 1), ly1 = min(h - 1, Int(limit.maxY / scale) - 1)
        guard lx1 > lx0, ly1 > ly0 else { return nil }
        let sx = Int(p.x / scale), sy = Int(p.y / scale)
        guard sx >= lx0, sx <= lx1, sy >= ly0, sy <= ly1 else { return nil }
        var best: CGRect?
        let minSide = 10   // px reduzidos (≈ 20 pt)
        // primeiro a zona do próprio ponto (um botão dentro de um painel é o botão); só se não servir (texto, ícone), as zonas à volta
        for (dx, dy) in [(0, 0), (6, 0), (-6, 0), (0, 6), (0, -6), (12, 12), (-12, -12), (12, -12), (-12, 12)] {
            let x = sx + dx, y = sy + dy
            guard x >= lx0, x <= lx1, y >= ly0, y <= ly1 else { continue }
            guard let box = region(x, y, lx0, ly0, lx1, ly1) else { continue }
            guard box.contains(sx, sy), box.w >= minSide, box.h >= minSide else { continue }
            // quase o limite todo (o fundo) não interessa
            if box.w >= (lx1 - lx0 + 1) * 97 / 100 && box.h >= (ly1 - ly0 + 1) * 97 / 100 { continue }
            let r = CGRect(x: CGFloat(box.x0) * scale, y: CGFloat(box.y0) * scale, width: CGFloat(box.w) * scale, height: CGFloat(box.h) * scale)
            if dx == 0 && dy == 0 { best = r; break }
            if best == nil || r.width * r.height > best!.width * best!.height { best = r }
        }
        return best.map { $0.insetBy(dx: -1, dy: -1).intersection(limit) }
    }

    private struct Box { var x0: Int, y0: Int, x1: Int, y1: Int; var w: Int { x1 - x0 + 1 }; var h: Int { y1 - y0 + 1 }; func contains(_ x: Int, _ y: Int) -> Bool { x >= x0 && x <= x1 && y >= y0 && y <= y1 } }

    /// Caixa da zona contígua de cor parecida com a do ponto (tolerância 12 por canal), dentro do limite.
    private func region(_ sx: Int, _ sy: Int, _ lx0: Int, _ ly0: Int, _ lx1: Int, _ ly1: Int) -> Box? {
        let c0 = px(sx, sy)
        let tol = 12
        var seen = [Bool](repeating: false, count: w * h)
        var stack = [(sx, sy)]
        seen[sy * w + sx] = true
        var box = Box(x0: sx, y0: sy, x1: sx, y1: sy)
        var count = 0
        while let (x, y) = stack.popLast() {
            count += 1
            box.x0 = min(box.x0, x); box.x1 = max(box.x1, x); box.y0 = min(box.y0, y); box.y1 = max(box.y1, y)
            for (nx, ny) in [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)] {
                guard nx >= lx0, nx <= lx1, ny >= ly0, ny <= ly1, !seen[ny * w + nx] else { continue }
                let c = px(nx, ny)
                guard abs(c.0 - c0.0) <= tol, abs(c.1 - c0.1) <= tol, abs(c.2 - c0.2) <= tol else { continue }
                seen[ny * w + nx] = true
                stack.append((nx, ny))
            }
        }
        // uma zona esburacada (texto) ou uma faixa de um gradiente tem poucos píxeis para a caixa: não serve
        guard count * 100 >= box.w * box.h * 60 else { return nil }
        return box
    }
}
