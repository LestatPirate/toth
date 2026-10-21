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

    func begin(snapshots: [(screen: NSScreen, image: CGImage)], completion: @escaping (CGImage?) -> Void) {
        guard !isActive else { return }
        MainWindow.hideForCapture()   // antes de ativar o Toth: senão o editor passa por cima da app que se quer capturar
        self.completion = completion
        for (screen, image) in snapshots {
            let window = SelectionWindow(screen: screen)
            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size), image: image)
            view.onConfirm = { [weak self] cropped in self?.end(cropped) }
            view.onCancel = { [weak self] in self?.end(nil) }
            view.onScroll = { [weak self] rect, first in self?.endScroll(screen: screen, rect: rect, first: first) }
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
    static func renderForTests(image: CGImage, size: CGSize, selection: CGRect, to path: String) {
        let view = SelectionView(frame: CGRect(origin: .zero, size: size), image: image)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.makeKeyAndOrderFront(nil)
        view.debugSelect(selection)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Para testes: cancela a seleção em curso.
    func cancelForTests() { end(nil) }
    /// Para testes: pré-seleciona uma área (coordenadas da vista do 1.º ecrã, origem no canto superior esquerdo).
    func debugPreselect(_ rect: CGRect) { views.first?.debugSelect(rect) }
    /// Para testes: escolhe «Rolagem» como se se clicasse no botão.
    func debugScroll() { views.first?.debugScrollClick() }
    /// Para testes: confirma a seleção atual como se se carregasse em Enter.
    func debugConfirm() { views.first?.confirm() }
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

    private enum Mode { case idle, drawing(anchor: CGPoint), moving(offset: CGSize), resizing(handle: Int, original: CGRect) }
    private var mode: Mode = .idle
    private var selection: CGRect?

    private let confirmButton = NSButton(title: L("Capturar"), target: nil, action: nil)
    private let cancelButton = NSButton(title: L("Cancelar"), target: nil, action: nil)
    private let scrollButton = NSButton(title: L("Rolagem"), target: nil, action: nil)

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(frame: CGRect, image: CGImage) {
        self.image = image
        super.init(frame: frame)
        confirmButton.target = self; confirmButton.action = #selector(confirmClicked)
        confirmButton.bezelStyle = .rounded; confirmButton.keyEquivalent = "\r"; confirmButton.controlSize = .large
        cancelButton.target = self; cancelButton.action = #selector(cancelClicked)
        cancelButton.bezelStyle = .rounded; cancelButton.controlSize = .large
        scrollButton.target = self; scrollButton.action = #selector(scrollClicked)
        scrollButton.bezelStyle = .rounded; scrollButton.controlSize = .large
        scrollButton.toolTip = L("Captura com rolagem: depois role a janela como quiser e clique em Concluir")
        [confirmButton, cancelButton, scrollButton].forEach { $0.isHidden = true; addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Seleção

    func clearSelection() { selection = nil; mode = .idle; layoutButtons(); needsDisplay = true }
    func debugScrollClick() { scrollClicked() }
    func debugSelect(_ r: CGRect) { selection = r; layoutButtons(); needsDisplay = true }

    @objc private func confirmClicked() { confirm() }
    @objc private func cancelClicked() { onCancel?() }

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
        if let sel = selection {
            if let h = handles(sel).firstIndex(where: { abs($0.x - p.x) <= 10 && abs($0.y - p.y) <= 10 }) {
                mode = .resizing(handle: h, original: sel); layoutButtons(); return
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
        let p = convert(event.locationInWindow, from: nil)
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

    override func mouseUp(with event: NSEvent) {
        if let s = selection, s.width < 4 || s.height < 4 { selection = nil }   // clique sem arrastar: sem seleção
        mode = .idle
        layoutButtons(); needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: confirm()          // Enter / Enter do teclado numérico
        case 53: onCancel?()            // Esc
        default: super.keyDown(with: event)
        }
    }

    // MARK: Botões e desenho

    private func layoutButtons() {
        guard let sel = selection, case .idle = mode else { [confirmButton, cancelButton, scrollButton].forEach { $0.isHidden = true }; return }
        [confirmButton, cancelButton, scrollButton].forEach { $0.sizeToFit(); $0.isHidden = false }
        let gap: CGFloat = 8
        let w = scrollButton.frame.width + gap + cancelButton.frame.width + gap + confirmButton.frame.width
        let h = confirmButton.frame.height
        var x = min(max(8, sel.maxX - w), bounds.width - w - 8)
        // por baixo da seleção; se não couber, por cima; se também não, dentro
        var y = sel.maxY + 10
        if y + h > bounds.height - 8 { y = sel.minY - h - 10 }
        if y < 8 { y = max(8, sel.maxY - h - 10); x = max(8, sel.maxX - w - 10) }
        scrollButton.setFrameOrigin(CGPoint(x: x, y: y))
        cancelButton.setFrameOrigin(CGPoint(x: x + scrollButton.frame.width + gap, y: y))
        confirmButton.setFrameOrigin(CGPoint(x: x + scrollButton.frame.width + gap + cancelButton.frame.width + gap, y: y))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // instantâneo congelado (a vista é "flipped": desvira a imagem)
        ctx.saveGState()
        ctx.translateBy(x: 0, y: bounds.height); ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: bounds)
        ctx.restoreGState()

        // escurece fora da seleção
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.addRect(bounds)
        if let sel = selection { ctx.addRect(sel) }
        ctx.fillPath(using: .evenOdd)

        guard let sel = selection else { return }
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
    }
}
