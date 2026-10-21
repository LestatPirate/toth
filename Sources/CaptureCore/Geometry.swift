// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import Foundation

/// Retângulo próprio (em vez de CGRect) para o núcleo não depender de CoreGraphics.
public struct Rect: Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public func insetBy(dx: Double, dy: Double) -> Rect {
        Rect(x: x + dx, y: y + dy, width: width - 2 * dx, height: height - 2 * dy)
    }
    public func contains(_ p: Point) -> Bool { p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY }
    public func union(_ o: Rect) -> Rect {
        let x0 = min(minX, o.minX), y0 = min(minY, o.minY)
        return Rect(x: x0, y: y0, width: max(maxX, o.maxX) - x0, height: max(maxY, o.maxY) - y0)
    }
}

public extension Shape {
    /// Nome para mostrar na lista de camadas.
    var isCallout: Bool { if case .callout = self { return true }; return false }
    var kindName: String {
        switch self {
        case .arrow: "Seta"; case .line: "Linha"; case .rect: "Retângulo"; case .ellipse: "Elipse"
        case .text, .textBox: "Texto"; case .step: "Etapa"; case .highlight: "Marcador"; case .blur: "Pixelização"; case .gaussian: "Blur"; case .image: "Imagem"; case .callout: "Balão"
        }
    }

    /// Texto editável da forma, se tiver.
    var string: String? {
        switch self {
        case let .text(_, s, _), let .textBox(_, _, _, s, _), let .callout(_, _, _, _, s, _): return s
        default: return nil
        }
    }

    var fontSize: Double? {
        switch self {
        case let .text(_, _, f), let .textBox(_, _, _, _, f), let .callout(_, _, _, _, _, f): return f
        default: return nil
        }
    }

    /// Raio padrão do círculo de uma etapa.
    static let defaultStepRadius = 16.0
    static let stepRadiusLimits = 8.0...400.0

    var stepNumber: Int? {
        if case let .step(_, n, _) = self { return n }
        return nil
    }

    /// Raio efetivo da etapa (o padrão se o ficheiro não o guardou).
    var stepRadius: Double? {
        if case let .step(_, _, r) = self { return r ?? Shape.defaultStepRadius }
        return nil
    }

    func with(stepRadius r: Double) -> Shape {
        if case let .step(c, n, _) = self { return .step(center: c, number: n, radius: min(max(r, Shape.stepRadiusLimits.lowerBound), Shape.stepRadiusLimits.upperBound)) }
        return self
    }

    func with(stepNumber n: Int) -> Shape {
        if case let .step(c, _, r) = self { return .step(center: c, number: n, radius: r) }
        return self
    }

    /// Intensidade do desfoque gaussiano (só para `gaussian`).
    var blurIntensity: Double? {
        if case let .gaussian(_, _, _, i) = self { return i }
        return nil
    }

    func with(blurIntensity i: Double) -> Shape {
        if case let .gaussian(o, w, h, _) = self { return .gaussian(origin: o, width: w, height: h, intensity: i) }
        return self
    }

    /// Nome do ficheiro da imagem colada (só para `image`).
    var imageAsset: String? {
        if case let .image(_, _, _, a) = self { return a }
        return nil
    }

    /// Tamanho do bloco da pixelização (só para `blur`).
    var pixelSize: Double? {
        if case let .blur(_, _, _, r) = self { return r }
        return nil
    }

    func with(pixelSize r: Double) -> Shape {
        if case let .blur(o, w, h, _) = self { return .blur(origin: o, width: w, height: h, radius: r) }
        return self
    }

    func with(string s: String) -> Shape {
        switch self {
        case let .text(o, _, f): return .text(origin: o, string: s, fontSize: f)
        case let .textBox(o, w, h, _, f): return .textBox(origin: o, width: w, height: h, string: s, fontSize: f)
        case let .callout(o, w, h, t, _, f): return .callout(origin: o, width: w, height: h, tail: t, string: s, fontSize: f)
        default: return self
        }
    }

    func with(fontSize f: Double) -> Shape {
        switch self {
        case let .text(o, s, _): return .text(origin: o, string: s, fontSize: f)
        case let .textBox(o, w, h, s, _): return .textBox(origin: o, width: w, height: h, string: s, fontSize: f)
        case let .callout(o, w, h, t, s, _): return .callout(origin: o, width: w, height: h, tail: t, string: s, fontSize: f)
        default: return self
        }
    }

    /// Caixa do callout sem o ponteiro.
    var calloutBox: Rect? {
        if case let .callout(o, w, h, _, _, _) = self {
            return Rect(x: min(o.x, o.x + w), y: min(o.y, o.y + h), width: abs(w), height: abs(h))
        }
        return nil
    }

    /// Caixa envolvente aproximada, em coordenadas da imagem.
    var bounds: Rect {
        switch self {
        case let .arrow(a, b), let .line(a, b):
            return Rect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        case let .rect(o, w, h), let .ellipse(o, w, h), let .highlight(o, w, h), let .blur(o, w, h, _), let .textBox(o, w, h, _, _),
             let .gaussian(o, w, h, _), let .image(o, w, h, _):
            return Rect(x: min(o.x, o.x + w), y: min(o.y, o.y + h), width: abs(w), height: abs(h))
        case let .text(o, s, size):
            let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
            let longest = lines.map(\.count).max() ?? 1
            let width = Double(max(longest, 1)) * size * 0.6
            let height = Double(lines.count) * size * 1.25
            return Rect(x: o.x, y: o.y, width: width, height: height)
        case let .step(c, _, r):
            let r = r ?? Shape.defaultStepRadius
            return Rect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        case let .callout(_, _, _, tail, _, _):
            let box = calloutBox!
            return box.union(Rect(x: tail.x, y: tail.y, width: 0, height: 0))
        }
    }

    func translated(dx: Double, dy: Double) -> Shape {
        func m(_ p: Point) -> Point { Point(x: p.x + dx, y: p.y + dy) }
        switch self {
        case let .arrow(a, b): return .arrow(from: m(a), to: m(b))
        case let .line(a, b): return .line(from: m(a), to: m(b))
        case let .rect(o, w, h): return .rect(origin: m(o), width: w, height: h)
        case let .ellipse(o, w, h): return .ellipse(origin: m(o), width: w, height: h)
        case let .text(o, s, f): return .text(origin: m(o), string: s, fontSize: f)
        case let .textBox(o, w, h, s, f): return .textBox(origin: m(o), width: w, height: h, string: s, fontSize: f)
        case let .step(c, n, r): return .step(center: m(c), number: n, radius: r)
        case let .highlight(o, w, h): return .highlight(origin: m(o), width: w, height: h)
        case let .blur(o, w, h, r): return .blur(origin: m(o), width: w, height: h, radius: r)
        case let .gaussian(o, w, h, i): return .gaussian(origin: m(o), width: w, height: h, intensity: i)
        case let .image(o, w, h, a): return .image(origin: m(o), width: w, height: h, asset: a)
        case let .callout(o, w, h, t, s, f): return .callout(origin: m(o), width: w, height: h, tail: m(t), string: s, fontSize: f)
        }
    }

    /// `true` se o ponto toca na forma (com tolerância em pixels da imagem).
    func hits(_ p: Point, tolerance t: Double) -> Bool {
        switch self {
        case let .arrow(a, b), let .line(a, b):
            return Shape.distance(from: p, toSegment: a, b) <= t
        case let .callout(_, _, _, tail, _, _):
            if calloutBox!.insetBy(dx: -t, dy: -t).contains(p) { return true }
            let box = calloutBox!
            let c = Point(x: box.x + box.width / 2, y: box.y + box.height / 2)
            return Shape.distance(from: p, toSegment: c, tail) <= t
        default:
            return bounds.insetBy(dx: -t, dy: -t).contains(p)
        }
    }

    static func distance(from p: Point, toSegment a: Point, _ b: Point) -> Double {
        let dx: Double = b.x - a.x
        let dy: Double = b.y - a.y
        let len2: Double = dx * dx + dy * dy
        var t: Double = 0
        if len2 > 0 { t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2)) }
        let ex: Double = p.x - (a.x + t * dx)
        let ey: Double = p.y - (a.y + t * dy)
        return (ex * ex + ey * ey).squareRoot()
    }

    private static func corners(_ r: Rect) -> [Point] {
        [Point(x: r.minX, y: r.minY), Point(x: r.maxX, y: r.minY),
         Point(x: r.maxX, y: r.maxY), Point(x: r.minX, y: r.maxY)]
    }

    /// Pontos de redimensionamento (extremos das linhas/setas, cantos das formas, ponteiro do callout).
    var handles: [Point] {
        switch self {
        case let .arrow(a, b), let .line(a, b): return [a, b]
        case .rect, .ellipse, .highlight, .blur, .textBox, .gaussian, .image: return Shape.corners(bounds)
        case let .callout(_, _, _, tail, _, _): return Shape.corners(calloutBox!) + [tail]
        case .step: return Shape.corners(bounds)   // 4 cantos: o círculo cresce mantendo a proporção
        case .text: return []
        }
    }

    /// Índice da alça junto ao ponto, se existir.
    func handle(at p: Point, tolerance t: Double) -> Int? {
        handles.firstIndex { abs($0.x - p.x) <= t && abs($0.y - p.y) <= t }
    }

    /// Move a alça `index` para `p`; nas formas retangulares o canto oposto fica fixo.
    func movingHandle(_ index: Int, to p: Point) -> Shape {
        func rectFrom(_ fixed: Point) -> (Point, Double, Double) {
            (Point(x: min(fixed.x, p.x), y: min(fixed.y, p.y)), abs(fixed.x - p.x), abs(fixed.y - p.y))
        }
        switch self {
        case let .arrow(a, b): return index == 0 ? .arrow(from: p, to: b) : .arrow(from: a, to: p)
        case let .line(a, b): return index == 0 ? .line(from: p, to: b) : .line(from: a, to: p)
        case .rect, .ellipse, .highlight, .blur, .textBox, .gaussian, .image:
            let h = handles
            guard h.indices.contains(index) else { return self }
            let (o, w, hh) = rectFrom(h[(index + 2) % 4])
            switch self {
            case .rect: return .rect(origin: o, width: w, height: hh)
            case .ellipse: return .ellipse(origin: o, width: w, height: hh)
            case .highlight: return .highlight(origin: o, width: w, height: hh)
            case let .blur(_, _, _, r): return .blur(origin: o, width: w, height: hh, radius: r)
            case let .textBox(_, _, _, s, f): return .textBox(origin: o, width: w, height: hh, string: s, fontSize: f)
            case let .gaussian(_, _, _, i): return .gaussian(origin: o, width: w, height: hh, intensity: i)
            case let .image(_, _, _, a): return .image(origin: o, width: w, height: hh, asset: a)
            default: return self
            }
        case let .callout(_, _, _, tail, s, f):
            let h = handles
            if index == 4 { return .callout(origin: calloutBox!.originPoint, width: calloutBox!.width, height: calloutBox!.height, tail: p, string: s, fontSize: f) }
            guard index < 4 else { return self }
            let (o, w, hh) = rectFrom(h[(index + 2) % 4])
            return .callout(origin: o, width: w, height: hh, tail: tail, string: s, fontSize: f)
        case let .step(_, n, _):
            let h = handles
            guard h.indices.contains(index) else { return self }
            // O canto oposto fica fixo; o círculo cresce em proporção (sempre quadrado envolvente = círculo).
            let fixed = h[(index + 2) % 4]
            let dx = p.x - fixed.x, dy = p.y - fixed.y
            let toward = h[index]   // direção original do canto, para quando o rato fica exatamente alinhado
            let sx: Double = dx != 0 ? (dx > 0 ? 1 : -1) : (toward.x >= fixed.x ? 1 : -1)
            let sy: Double = dy != 0 ? (dy > 0 ? 1 : -1) : (toward.y >= fixed.y ? 1 : -1)
            let lim = Shape.stepRadiusLimits
            let side = min(max(max(abs(dx), abs(dy)), 2 * lim.lowerBound), 2 * lim.upperBound)
            return .step(center: Point(x: fixed.x + sx * side / 2, y: fixed.y + sy * side / 2), number: n, radius: side / 2)
        case .text: return self
        }
    }
}

extension Rect {
    var originPoint: Point { Point(x: x, y: y) }
}

public extension CaptureDocument {
    /// Anotação mais acima que toca no ponto.
    func topmost(at p: Point, tolerance: Double) -> Annotation? {
        ordered.last { $0.visible && $0.shape.hits(p, tolerance: tolerance) }
    }
}


public extension Annotation {
    /// Texto editável no objeto, se a forma o suporta (vazio ≠ não suportado).
    var editableString: String? {
        switch shape {
        case .rect, .ellipse: return caption
        default: return shape.string
        }
    }

    mutating func setEditableString(_ s: String) {
        switch shape {
        case .rect, .ellipse: caption = s
        default: shape = shape.with(string: s)
        }
    }

    /// Tamanho da letra: o da forma ou, em retângulo/elipse, o do formato de texto.
    var effectiveFontSize: Double? {
        switch shape {
        case .rect, .ellipse: return style.text.size ?? 20
        default: return shape.fontSize
        }
    }
}


public extension Annotation {
    /// Caixa que o objeto realmente ocupa, incluindo a espessura da linha.
    var paintBounds: Rect {
        let b = shape.bounds
        let pad: Double
        switch shape {
        case .highlight, .blur, .gaussian, .image, .step: pad = 0
        default: pad = style.lineVisible ? style.lineWidth / 2 : 0
        }
        return b.insetBy(dx: -pad, dy: -pad)
    }
}
