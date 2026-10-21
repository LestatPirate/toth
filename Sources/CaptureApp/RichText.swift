// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit
import CaptureCore

/// Gestor de layout que desenha marcadores (• ou 1.) à esquerda de cada parágrafo.
/// É usado tanto na renderização como no editor em linha, para o resultado ser idêntico.
final class MarkerLayoutManager: NSLayoutManager {
    var list: TextFormat.ListStyle = .none
    var markerFont: NSFont = .systemFont(ofSize: 14)
    var markerColor: NSColor = .black
    var indent: CGFloat = 0

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard list != .none, let storage = textStorage else { return }
        let ns = storage.string as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: markerFont, .foregroundColor: markerColor]
        var n = 0

        // O marcador fica logo antes do início real do texto da linha (`textStart`), por isso acompanha
        // o alinhamento (esquerda, centro, direita) em vez de ficar preso à margem.
        func drawMarker(_ number: Int, frag: NSRect, textStart: CGFloat, baseline: CGFloat) {
            let text = (list == .bullet ? "•" : "\(number).") as NSString
            let w = text.size(withAttributes: attrs).width
            let x = origin.x + textStart - w - markerFont.pointSize * 0.3
            let y = origin.y + frag.minY + baseline - markerFont.ascender
            text.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
        }

        if ns.length > 0 {
            ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs, .substringNotRequired]) { _, _, enclosing, _ in
                n += 1
                let g = self.glyphIndexForCharacter(at: enclosing.location)
                let frag = self.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
                let used = self.lineFragmentUsedRect(forGlyphAt: g, effectiveRange: nil)
                drawMarker(n, frag: frag, textStart: used.minX, baseline: self.location(forGlyphAt: g).y)
            }
        }
        // Último parágrafo vazio (texto vazio ou terminado em quebra de linha).
        if ns.length == 0 || ns.hasSuffix("\n") {
            let extra = extraLineFragmentRect
            if extra.height > 0 {
                drawMarker(n + 1, frag: extra, textStart: extraLineFragmentUsedRect.minX, baseline: markerFont.ascender)
            }
        }
    }
}

enum RichText {
    static let padX: CGFloat = 10
    static let padY: CGFloat = 8

    static let fontChoices: [String] = ["Helvetica Neue", "Arial", "Georgia", "Times New Roman", "Courier New", "Menlo", "Verdana", "Trebuchet MS", "Avenir Next"]
        .filter { NSFont(name: $0, size: 12) != nil }

    static func color(_ hex: String) -> NSColor { NSColor(hex: hex) }

    static func font(_ f: TextFormat, size: CGFloat) -> NSFont {
        var font = f.fontName.flatMap { NSFont(name: $0, size: size) } ?? NSFont.systemFont(ofSize: size)
        if f.bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if f.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }

    static func indent(_ f: TextFormat, size: CGFloat) -> CGFloat { f.list == .none ? 0 : size * 1.6 }

    static func attributes(_ f: TextFormat, size: CGFloat, color: NSColor) -> [NSAttributedString.Key: Any] {
        let ps = NSMutableParagraphStyle()
        ps.alignment = switch f.align { case .left: .left; case .center: .center; case .right: .right }
        ps.lineBreakMode = .byWordWrapping
        let ind = indent(f, size: size)
        ps.firstLineHeadIndent = ind; ps.headIndent = ind
        var attrs: [NSAttributedString.Key: Any] = [.font: font(f, size: size), .foregroundColor: color, .paragraphStyle: ps]
        if f.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return attrs
    }

    /// Cor efetiva do texto: a escolhida, ou o padrão (escuro; nos textos antigos, a cor da linha).
    static func textColor(_ style: Style, legacyFallback: Bool = false) -> NSColor {
        if let hex = style.text.colorHex { return color(hex) }
        return legacyFallback ? color(style.colorHex) : color("#1C1C1E")
    }

    static func makeLayout(_ string: String, format f: TextFormat, size: CGFloat, color: NSColor, width: CGFloat)
        -> (NSTextStorage, MarkerLayoutManager, NSTextContainer) {
        let storage = NSTextStorage(string: string, attributes: attributes(f, size: size, color: color))
        let lm = MarkerLayoutManager()
        configure(lm, f, size: size, color: color)
        let container = NSTextContainer(size: CGSize(width: max(1, width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        lm.addTextContainer(container)
        storage.addLayoutManager(lm)
        return (storage, lm, container)
    }

    static func configure(_ lm: MarkerLayoutManager, _ f: TextFormat, size: CGFloat, color: NSColor) {
        lm.list = f.list
        lm.markerFont = font(f, size: size)
        lm.markerColor = color
        lm.indent = indent(f, size: size)
    }

    /// Altura do texto já disposto (inclui a última linha vazia).
    static func textHeight(_ lm: MarkerLayoutManager, _ container: NSTextContainer) -> CGFloat {
        lm.ensureLayout(for: container)
        return max(lm.usedRect(for: container).height, lm.extraLineFragmentRect.maxY)
    }

    static func verticalOffset(_ v: TextFormat.VAlign, free: CGFloat) -> CGFloat {
        let f = max(0, free)
        switch v { case .top: return 0; case .middle: return f / 2; case .bottom: return f }
    }

    /// Desenha o texto dentro de `rect` (coordenadas da imagem, contexto "flipped").
    static func draw(_ string: String, in rect: CGRect, format f: TextFormat, size: CGFloat, color: NSColor, vertical: Bool = true) {
        let (storage, lm, container) = makeLayout(string, format: f, size: size, color: color, width: rect.width)
        _ = storage
        let h = textHeight(lm, container)
        let dy = vertical ? verticalOffset(f.vAlign, free: rect.height - h) : 0
        lm.drawGlyphs(forGlyphRange: lm.glyphRange(for: container), at: CGPoint(x: rect.minX, y: rect.minY + dy))
    }
}
