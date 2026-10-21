// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit
import CoreImage
import CoreText
import CaptureCore

/// Desenha base + anotações em coordenadas de pixel da imagem (origem no canto superior esquerdo).
/// Usado tanto pelo canvas do editor como pela exportação.
enum Renderer {
    private static let ciContext = CIContext()

    static func draw(_ doc: CaptureDocument, base: CGImage, in ctx: CGContext, selected: UUID? = nil, editing: UUID? = nil,
                     assets: AssetStore? = nil) {
        drawWorld(doc, base: base, assets: assets, annotations: doc.ordered.filter(\.visible), editing: editing, in: ctx)
        if let sel = doc.annotations.first(where: { $0.id == selected }) {
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            defer { NSGraphicsContext.current = previous }
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.systemBlue.cgColor)
            ctx.setLineWidth(max(1.5, Double(base.width) / 1200))
            ctx.setLineDash(phase: 0, lengths: [6, 4])
            ctx.stroke(sel.shape.bounds.cg.insetBy(dx: -6, dy: -6))
            ctx.restoreGState()
        }
    }

    /// Fundo + imagem original + `annotations` por ordem (de baixo para cima).
    /// O Blur e a Pixelização atuam sobre **tudo o que está por baixo deles** (imagem e outros objetos), não só sobre a imagem.
    private static func drawWorld(_ doc: CaptureDocument, base: CGImage, assets: AssetStore?, annotations: [Annotation],
                                  editing: UUID?, in ctx: CGContext) {
        // Fundo da área de trabalho (visível onde a área vai além da imagem original).
        if !doc.transparentBackground {
            ctx.setFillColor(color(doc.backgroundHex).cgColor)
            ctx.fill(doc.area.cg)
        }
        drawImage(base, in: CGRect(x: 0, y: 0, width: Double(base.width), height: Double(base.height)), ctx)

        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        defer { NSGraphicsContext.current = previous }

        for (i, a) in annotations.enumerated() {
            switch a.shape {
            case .blur, .gaussian:
                drawEffect(a, below: Array(annotations[0..<i]), doc: doc, base: base, assets: assets, ctx)
            default:
                draw(a, base: base, assets: assets, ctx, skipText: a.id == editing)
            }
        }
    }

    /// Aplica o efeito de `a` ao que já foi desenhado por baixo (`below`): desenha essa parte num bitmap,
    /// filtra a região e substitui-a no destino. Só se renderiza a região (e uma margem), por isso o custo não
    /// depende do tamanho da imagem.
    private static func drawEffect(_ a: Annotation, below: [Annotation], doc: CaptureDocument, base: CGImage,
                                   assets: AssetStore?, _ ctx: CGContext) {
        let gaussian: Double?
        let pixel: Double?
        switch a.shape {
        case let .gaussian(_, _, _, i): gaussian = i; pixel = nil
        case let .blur(_, _, _, r): gaussian = nil; pixel = max(2, r)
        default: return
        }
        if let g = gaussian, g <= 0 { return }

        // Só interessa o que se vê: área exportada + imagem original.
        let visible = doc.area.cg.union(doc.imageRect.cg)
        let rect = a.shape.bounds.cg.intersection(visible).integral
        guard rect.width >= 1, rect.height >= 1 else { return }
        let pad: CGFloat = gaussian.map { ceil($0 * 3) } ?? 0
        let padded = rect.insetBy(dx: -pad, dy: -pad)
        guard padded.width * padded.height <= 40_000_000 else { return }   // limite de memória (~160 MB)

        // 1) o que está por baixo, num bitmap só desta região
        let w = Int(padded.width), h = Int(padded.height)
        guard let tmp = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        tmp.translateBy(x: 0, y: CGFloat(h))
        tmp.scaleBy(x: 1, y: -1)
        tmp.translateBy(x: -padded.minX, y: -padded.minY)
        drawWorld(doc, base: base, assets: assets, annotations: below, editing: nil, in: tmp)
        guard let below = tmp.makeImage() else { return }

        // 2) filtro (o CoreImage tem a origem em baixo à esquerda)
        let ciRect = CGRect(x: rect.minX - padded.minX, y: CGFloat(h) - (rect.minY - padded.minY) - rect.height,
                            width: rect.width, height: rect.height)
        var output: CIImage?
        var pixelated: CGImage?
        if let radius = gaussian {
            let f = CIFilter(name: "CIGaussianBlur")!
            f.setValue(CIImage(cgImage: below).clampedToExtent(), forKey: kCIInputImageKey)   // bordas estendidas: sem margens transparentes
            f.setValue(radius, forKey: kCIInputRadiusKey)
            output = f.outputImage
        } else if let size = pixel {
            // Células calculadas à mão: o nº de colunas/linhas é arredondado e a região divide-se por igual, por isso não sobra
            // uma faixa fina numa das bordas (o CIPixellate deixava-a no topo).
            let local = CGRect(x: rect.minX - padded.minX, y: rect.minY - padded.minY, width: rect.width, height: rect.height)
            pixelated = pixelate(below, region: local, cell: CGFloat(size))
        }
        let img: CGImage
        if let pixelated { img = pixelated }
        else if let out = output?.cropped(to: ciRect), let blurred = ciContext.createCGImage(out, from: ciRect) { img = blurred }
        else { return }

        // 3) substitui a região (e não compõe por cima, para não deixar o original a transparecer)
        ctx.saveGState()
        ctx.clip(to: rect)
        if a.style.opacity >= 0.999 { ctx.setBlendMode(.copy) } else { ctx.setAlpha(CGFloat(a.style.opacity)) }
        drawImage(img, in: rect, ctx)
        ctx.restoreGState()
    }

    /// PNG da área de trabalho (recorte e/ou espaço extra). A imagem original nunca é alterada.
    static func png(_ doc: CaptureDocument, base: CGImage, assets: AssetStore? = nil) -> Data? {
        let area = doc.area.cg.integral
        guard area.width >= 1, area.height >= 1,
              let ctx = CGContext(data: nil, width: Int(area.width), height: Int(area.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: area.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -area.minX, y: -area.minY)
        draw(doc, base: base, in: ctx, assets: assets)
        guard let image = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    // MARK: -

    /// CGContext com CTM invertido desenharia a imagem de cabeça para baixo; compensa.
    private static func drawImage(_ image: CGImage, in rect: CGRect, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    private static func color(_ hex: String) -> NSColor {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if s.count == 6 { s += "FF" }
        guard let v = UInt32(s, radix: 16), s.count == 8 else { return .systemRed }
        return NSColor(srgbRed: CGFloat((v >> 24) & 255) / 255, green: CGFloat((v >> 16) & 255) / 255,
                       blue: CGFloat((v >> 8) & 255) / 255, alpha: CGFloat(v & 255) / 255)
    }

    /// Contorno da seta: haste com extremo redondo + ponta triangular, tudo num só caminho (sem sobreposições).
    static func arrowPath(from p: CGPoint, to q: CGPoint, lineWidth lw: Double) -> CGPath {
        let head = CGFloat(max(14, lw * 4))
        let hw = CGFloat(lw) / 2
        let angle = atan2(q.y - p.y, q.x - p.x)
        let dir = CGPoint(x: cos(angle), y: sin(angle))
        let n = CGPoint(x: -dir.y, y: dir.x)                       // normal (roda 90° a direção)
        func wing(_ d: CGFloat) -> CGPoint { CGPoint(x: q.x - cos(angle + d) * head, y: q.y - sin(angle + d) * head) }
        let wingPlus = wing(-.pi / 7), wingMinus = wing(.pi / 7)   // asas da ponta: a de ângulo -π/7 fica do lado +n
        let path = CGMutablePath()
        let length = hypot(q.x - p.x, q.y - p.y)
        if length <= head * 0.5 {                                   // seta muito curta: só a ponta
            path.move(to: q); path.addLine(to: wingPlus); path.addLine(to: wingMinus); path.closeSubpath()
            return path
        }
        let neck = CGPoint(x: q.x - dir.x * head * 0.5, y: q.y - dir.y * head * 0.5)   // a haste entra na ponta
        path.move(to: CGPoint(x: p.x + n.x * hw, y: p.y + n.y * hw))
        path.addLine(to: CGPoint(x: neck.x + n.x * hw, y: neck.y + n.y * hw))
        path.addLine(to: wingPlus)
        path.addLine(to: q)
        path.addLine(to: wingMinus)
        path.addLine(to: CGPoint(x: neck.x - n.x * hw, y: neck.y - n.y * hw))
        path.addLine(to: CGPoint(x: p.x - n.x * hw, y: p.y - n.y * hw))
        // extremo redondo, desenhado com segmentos (os sentidos de arco dependem do eixo y do contexto)
        for k in 1...10 {
            let t = angle - .pi / 2 - CGFloat(k) * .pi / 10
            path.addLine(to: CGPoint(x: p.x + cos(t) * hw, y: p.y + sin(t) * hw))
        }
        path.closeSubpath()
        return path
    }

    /// Contorno único: caixa arredondada com o ponteiro integrado no lado mais próximo da ponta
    /// (um só caminho, por isso não há linha entre a caixa e o ponteiro).
    /// Pixeliza `region` (coordenadas da imagem, origem no topo) com células de lado aproximado `cell`: cada célula é a média
    /// dos píxeis que cobre. O número de colunas/linhas é arredondado e as fronteiras são inteiras e repartidas por igual
    /// (as células diferem, no máximo, 1 px), por isso não há faixas finas nas bordas.
    static func pixelate(_ image: CGImage, region: CGRect, cell: CGFloat) -> CGImage? {
        let w = Int(region.width.rounded()), h = Int(region.height.rounded())
        guard w >= 1, h >= 1, let crop = image.cropping(to: CGRect(x: region.minX, y: region.minY, width: CGFloat(w), height: CGFloat(h))) else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var src = [UInt8](repeating: 0, count: w * h * 4)
        guard let sctx = CGContext(data: &src, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        sctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        let cols = max(1, Int((CGFloat(w) / max(cell, 1)).rounded())), rows = max(1, Int((CGFloat(h) / max(cell, 1)).rounded()))
        var dst = [UInt8](repeating: 0, count: w * h * 4)
        for cy in 0..<rows {
            let y0 = cy * h / rows, y1 = (cy + 1) * h / rows
            for cx in 0..<cols {
                let x0 = cx * w / cols, x1 = (cx + 1) * w / cols
                var sum = [Int](repeating: 0, count: 4)
                for y in y0..<y1 { for x in x0..<x1 { let o = (y * w + x) * 4; sum[0] += Int(src[o]); sum[1] += Int(src[o + 1]); sum[2] += Int(src[o + 2]); sum[3] += Int(src[o + 3]) } }
                let n = max(1, (y1 - y0) * (x1 - x0))
                let avg = sum.map { UInt8(($0 + n / 2) / n) }
                for y in y0..<y1 { for x in x0..<x1 { let o = (y * w + x) * 4; dst[o] = avg[0]; dst[o + 1] = avg[1]; dst[o + 2] = avg[2]; dst[o + 3] = avg[3] } }
            }
        }
        guard let dctx = CGContext(data: &dst, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return dctx.makeImage()
    }

    enum CalloutSide { case top, right, bottom, left }

    /// Onde o ponteiro se liga à caixa. Segue o **raio do centro da caixa até à ponta**: o ponto de ligação desliza de forma
    /// contínua pelo contorno e tende a ficar perto do centro (quanto mais longe a ponta, mais centrado). `nil` se a ponta
    /// estiver dentro da caixa (sem ponteiro).
    static func calloutAnchor(box: CGRect, tail: CGPoint) -> (side: CalloutSide, coordinate: CGFloat)? {
        if box.contains(tail) { return nil }
        let r = min(10, min(box.width, box.height) / 4)
        let half = min(14, min(box.width, box.height) / 3)
        let dx = tail.x - box.midX, dy = tail.y - box.midY
        // o raio sai pelos lados verticais ou horizontais conforme a proporção da caixa
        if abs(dx) * box.height > abs(dy) * box.width {
            let y = box.midY + dy * (box.width / 2) / abs(dx)
            return (dx > 0 ? .right : .left, max(box.minY + r + half, min(box.maxY - r - half, y)))
        }
        let x = box.midX + dx * (box.height / 2) / max(abs(dy), 0.0001)
        return (dy > 0 ? .bottom : .top, max(box.minX + r + half, min(box.maxX - r - half, x)))
    }

    static func calloutPath(_ box: CGRect, tail: CGPoint) -> CGPath {
        let r = min(10, min(box.width, box.height) / 4)
        let half = min(14, min(box.width, box.height) / 3)
        let anchor = calloutAnchor(box: box, tail: tail)
        func side(_ s: CalloutSide) -> CGFloat? { anchor?.side == s ? anchor?.coordinate : nil }

        let p = CGMutablePath()
        p.move(to: CGPoint(x: box.minX + r, y: box.minY))
        // topo (esquerda → direita)
        if let a = side(.top) { p.addLine(to: CGPoint(x: a - half, y: box.minY)); p.addLine(to: tail); p.addLine(to: CGPoint(x: a + half, y: box.minY)) }
        p.addLine(to: CGPoint(x: box.maxX - r, y: box.minY))
        p.addArc(tangent1End: CGPoint(x: box.maxX, y: box.minY), tangent2End: CGPoint(x: box.maxX, y: box.minY + r), radius: r)
        // direita (cima → baixo)
        if let a = side(.right) { p.addLine(to: CGPoint(x: box.maxX, y: a - half)); p.addLine(to: tail); p.addLine(to: CGPoint(x: box.maxX, y: a + half)) }
        p.addLine(to: CGPoint(x: box.maxX, y: box.maxY - r))
        p.addArc(tangent1End: CGPoint(x: box.maxX, y: box.maxY), tangent2End: CGPoint(x: box.maxX - r, y: box.maxY), radius: r)
        // base (direita → esquerda)
        if let a = side(.bottom) { p.addLine(to: CGPoint(x: a + half, y: box.maxY)); p.addLine(to: tail); p.addLine(to: CGPoint(x: a - half, y: box.maxY)) }
        p.addLine(to: CGPoint(x: box.minX + r, y: box.maxY))
        p.addArc(tangent1End: CGPoint(x: box.minX, y: box.maxY), tangent2End: CGPoint(x: box.minX, y: box.maxY - r), radius: r)
        // esquerda (baixo → cima)
        if let a = side(.left) { p.addLine(to: CGPoint(x: box.minX, y: a + half)); p.addLine(to: tail); p.addLine(to: CGPoint(x: box.minX, y: a - half)) }
        p.addLine(to: CGPoint(x: box.minX, y: box.minY + r))
        p.addArc(tangent1End: CGPoint(x: box.minX, y: box.minY), tangent2End: CGPoint(x: box.minX + r, y: box.minY), radius: r)
        p.closeSubpath()
        return p
    }

    /// Número/letra da etapa: escala com o raio e fica centrado no círculo.
    /// Horizontalmente centra-se pelo desenho real dos glifos; verticalmente pela altura das maiúsculas/dígitos (para uma
    /// coluna de etapas ficar alinhada) ou, se houver minúsculas, pelo desenho real.
    static func drawStepLabel(_ label: String, center: CGPoint, radius r: CGFloat, style: Style, _ ctx: CGContext) {
        let numberColor = style.text.colorHex.map { color($0) } ?? .white
        let fmt = TextFormat(fontName: style.text.fontName, bold: true)
        let fromContext = NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String)
        func make(_ size: CGFloat) -> (line: CTLine, ink: CGRect, font: NSFont) {
            let font = RichText.font(fmt, size: size)
            let attributed = NSAttributedString(string: label, attributes: [.font: font, fromContext: true])
            let line = CTLineCreateWithAttributedString(attributed)
            return (line, CTLineGetBoundsWithOptions(line, .useGlyphPathBounds), font)
        }
        var size = r * 17 / 16            // mesma proporção que o desenho original (raio 16, letra 17)
        var m = make(size)
        // numerais largos (XVIII, AA) encolhem para caber: ocupam, no máximo, 75% do diâmetro
        if m.ink.width > 0, m.ink.width > r * 1.5 {
            size *= (r * 1.5) / m.ink.width
            m = make(size)
        }
        // Maiúsculas e dígitos: centro da altura das maiúsculas (colunas de etapas alinhadas). Minúsculas (i, a, g…): centro do
        // desenho real do texto, porque os pingos e os descendentes mudam onde está a massa visual.
        let hasLower = label.contains { $0.isLowercase }
        let verticalOffset = hasLower ? m.ink.midY : m.font.capHeight / 2
        ctx.saveGState()
        ctx.setFillColor(numberColor.cgColor)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)          // o contexto tem o eixo y para baixo
        // posição da linha de base (y para baixo): o centro da referência fica no centro do círculo
        ctx.textPosition = CGPoint(x: center.x - m.ink.midX, y: center.y + verticalOffset)
        CTLineDraw(m.line, ctx)
        ctx.restoreGState()
    }

    /// Área do texto dentro de uma caixa.
    static func textRect(_ box: CGRect) -> CGRect { box.insetBy(dx: RichText.padX, dy: RichText.padY) }

    /// Área onde o texto do objeto é desenhado/editado (`nil` se o objeto não tem texto).
    /// Na elipse usa-se o retângulo inscrito.
    static func textArea(_ a: Annotation) -> CGRect? {
        switch a.shape {
        case .textBox, .rect: return textRect(a.shape.bounds.cg)
        case .callout: return textRect(a.shape.calloutBox!.cg)
        case .ellipse:
            let b = a.shape.bounds.cg
            return textRect(b.insetBy(dx: b.width * 0.146, dy: b.height * 0.146))
        default: return nil
        }
    }

    private static func drawCaption(_ a: Annotation) {
        guard let area = textArea(a), let size = a.effectiveFontSize, !a.caption.isEmpty else { return }
        RichText.draw(a.caption, in: area, format: a.style.text, size: size, color: RichText.textColor(a.style))
    }

    private static func draw(_ a: Annotation, base: CGImage, assets: AssetStore?, _ ctx: CGContext, skipText: Bool = false) {
        let c = color(a.style.colorHex)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(c.cgColor)
        ctx.setFillColor(c.cgColor)
        ctx.setLineWidth(a.style.lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setAlpha(CGFloat(a.style.opacity))
        let fill: NSColor? = a.style.fillHex.map { color($0) }
        if a.style.shadow {
            ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 4, color: NSColor.black.withAlphaComponent(0.4).cgColor)
        }

        switch a.shape {
        case let .line(p, q):
            ctx.move(to: CGPoint(x: p.x, y: p.y)); ctx.addLine(to: CGPoint(x: q.x, y: q.y)); ctx.strokePath()

        case let .arrow(p, q):
            // Um só contorno preenchido (haste + ponta): sem linha de junção, e a sombra e a opacidade aplicam-se uma só vez.
            ctx.addPath(arrowPath(from: CGPoint(x: p.x, y: p.y), to: CGPoint(x: q.x, y: q.y), lineWidth: a.style.lineWidth))
            ctx.fillPath()

        case .rect:
            if let fill { ctx.setFillColor(fill.cgColor); ctx.fill(a.shape.bounds.cg) }
            if a.style.lineVisible { ctx.stroke(a.shape.bounds.cg) }
            if !skipText { ctx.setShadow(offset: .zero, blur: 0, color: nil); drawCaption(a) }

        case .ellipse:
            if let fill { ctx.setFillColor(fill.cgColor); ctx.fillEllipse(in: a.shape.bounds.cg) }
            if a.style.lineVisible { ctx.strokeEllipse(in: a.shape.bounds.cg) }
            if !skipText { ctx.setShadow(offset: .zero, blur: 0, color: nil); drawCaption(a) }

        case let .textBox(_, _, _, string, size):
            let box = a.shape.bounds.cg
            if let fill { ctx.setFillColor(fill.cgColor); ctx.fill(box) }
            if a.style.lineVisible { ctx.stroke(box) }
            if !skipText { RichText.draw(string, in: textRect(box), format: a.style.text, size: size, color: RichText.textColor(a.style)) }

        case .highlight:
            ctx.setFillColor(c.cgColor)   // a transparência vem da opacidade do estilo
            ctx.fill(a.shape.bounds.cg)

        case let .text(o, s, size):
            if !skipText {
                let b = a.shape.bounds.cg
                RichText.draw(s, in: CGRect(x: o.x, y: o.y, width: b.width + size, height: b.height), format: a.style.text,
                              size: size, color: RichText.textColor(a.style, legacyFallback: true), vertical: false)
            }

        case let .callout(_, _, _, tail, string, size):
            let box = a.shape.calloutBox!.cg
            let path = calloutPath(box, tail: CGPoint(x: tail.x, y: tail.y))
            if let fill { ctx.setFillColor(fill.cgColor); ctx.addPath(path); ctx.fillPath() }
            if a.style.lineVisible { ctx.addPath(path); ctx.strokePath() }
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            if !skipText { RichText.draw(string, in: textRect(box), format: a.style.text, size: size, color: RichText.textColor(a.style)) }

        case let .step(center, n, radius):
            let r = CGFloat(radius ?? Shape.defaultStepRadius)
            ctx.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            drawStepLabel(a.style.stepFormat.label(n), center: CGPoint(x: center.x, y: center.y), radius: r, style: a.style, ctx)

        case .gaussian, .blur:
            break   // tratados em drawEffect: precisam do que está por baixo

        case let .image(_, _, _, asset):
            let box = a.shape.bounds.cg
            if let img = assets?.image(named: asset) {
                drawImage(img, in: box, ctx)
            } else {   // ficheiro em falta: mostra uma caixa vazia em vez de falhar
                ctx.setStrokeColor(NSColor.systemRed.cgColor); ctx.setLineDash(phase: 0, lengths: [6, 4]); ctx.stroke(box)
            }

        }
    }
}
