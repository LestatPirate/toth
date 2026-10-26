// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit

/// Botão só com ícone (SF Symbol) e dica, para as barras que aparecem durante a captura (imagem, rolagem, vídeo).
/// Realça ao passar o rato e mostra o estado ligado/desligado (por exemplo, o microfone).
final class IconButton: NSButton {
    private var hovering = false
    private var tracking: NSTrackingArea?
    /// Cor do ícone; `nil` = a cor normal dos controlos.
    var tint: NSColor? { didSet { applyTint() } }
    /// Realce permanente (por exemplo, o botão principal).
    var prominent = false { didSet { needsDisplay = true } }

    init(symbol: String, tooltip: String, tint: NSColor? = nil, size: CGFloat = 34, target: AnyObject?, action: Selector?) {
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        toolTip = tooltip
        setAccessibilityLabel(tooltip)
        self.target = target; self.action = action
        self.tint = tint
        setSymbol(symbol, description: tooltip)
        wantsLayer = true
        applyTint()
    }

    required init?(coder: NSCoder) { fatalError() }

    func setSymbol(_ name: String, description: String? = nil) {
        let cfg = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        image = NSImage(systemSymbolName: name, accessibilityDescription: description ?? toolTip)?.withSymbolConfiguration(cfg)
    }

    private func applyTint() { contentTintColor = tint ?? .labelColor }

    override var isEnabled: Bool { didSet { alphaValue = isEnabled ? 1 : 0.35 } }
    override var intrinsicContentSize: NSSize { frame.size }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }   // clicável mesmo com a janela inativa

    override func draw(_ dirtyRect: NSRect) {
        if prominent || (hovering && isEnabled) {
            let r = bounds.insetBy(dx: 2, dy: 2)
            (prominent ? NSColor.controlAccentColor.withAlphaComponent(hovering ? 0.35 : 0.22) : NSColor.labelColor.withAlphaComponent(0.12)).setFill()
            NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
        }
        super.draw(dirtyRect)
    }
}

/// Barra flutuante com uma fila de ícones (fundo translúcido, cantos redondos).
final class IconBar: NSVisualEffectView {
    private(set) var items: [NSView] = []
    private let pad: CGFloat = 8, gap: CGFloat = 4

    init() {
        super.init(frame: .zero)
        material = .hudWindow; state = .active; blendingMode = .behindWindow
        wantsLayer = true; layer?.cornerRadius = 12; layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Substitui o conteúdo e ajusta o tamanho da barra. Separadores: `NSBox` vertical de 1 px.
    func setItems(_ views: [NSView]) {
        items.forEach { $0.removeFromSuperview() }
        items = views
        var x = pad
        let h = (views.map { $0.frame.height }.max() ?? 34) + 2 * 7
        for v in views {
            v.frame.origin = NSPoint(x: x, y: (h - v.frame.height) / 2)
            addSubview(v)
            x += v.frame.width + gap
        }
        setFrameSize(NSSize(width: x - gap + pad, height: h))
    }

    static func separator() -> NSView {
        let b = NSBox(frame: NSRect(x: 0, y: 0, width: 1, height: 22))
        b.boxType = .separator
        return b
    }

    static func label(_ text: String, width: CGFloat) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        f.textColor = .labelColor
        f.frame = NSRect(x: 0, y: 0, width: width, height: 20)
        f.alignment = .center
        return f
    }
}
