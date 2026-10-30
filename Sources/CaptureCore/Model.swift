// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import Foundation

public struct Point: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// Formato da numeração das etapas.
public enum StepFormat: String, Codable, CaseIterable, Sendable {
    case arabic, romanUpper, romanLower, alphaUpper, alphaLower

    public func label(_ n: Int) -> String {
        switch self {
        case .arabic: return "\(n)"
        case .romanUpper: return StepFormat.roman(n)
        case .romanLower: return StepFormat.roman(n).lowercased()
        case .alphaUpper: return StepFormat.alpha(n)
        case .alphaLower: return StepFormat.alpha(n).lowercased()
        }
    }

    /// Algarismos romanos (1…3999; fora disto, cai para árabe).
    static func roman(_ n: Int) -> String {
        guard (1...3999).contains(n) else { return "\(n)" }
        var n = n, out = ""
        for (v, sym) in [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
                         (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")] {
            while n >= v { out += sym; n -= v }
        }
        return out
    }

    /// A, B … Z, AA, AB …
    static func alpha(_ n: Int) -> String {
        guard n > 0 else { return "\(n)" }
        var n = n, out = ""
        while n > 0 {
            n -= 1
            out = String(UnicodeScalar(UInt8(65 + n % 26))) + out
            n /= 26
        }
        return out
    }
}

/// Formatação básica de texto (aplica-se ao objeto inteiro).
public struct TextFormat: Codable, Equatable, Sendable {
    public enum Align: String, Codable, Sendable { case left, center, right }
    public enum VAlign: String, Codable, Sendable { case top, middle, bottom }
    public enum ListStyle: String, Codable, Sendable { case none, bullet, numbered }

    /// `nil` = fonte do sistema.
    public var fontName: String?
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var align: Align
    public var vAlign: VAlign
    public var list: ListStyle
    /// `nil` = cor padrão do texto.
    public var colorHex: String?
    /// Tamanho do texto nas formas que não o guardam (retângulo, elipse). `nil` = padrão.
    public var size: Double?

    public init(fontName: String? = nil, bold: Bool = false, italic: Bool = false, underline: Bool = false,
                align: Align = .left, vAlign: VAlign = .top, list: ListStyle = .none, colorHex: String? = nil, size: Double? = nil) {
        self.fontName = fontName; self.bold = bold; self.italic = italic; self.underline = underline
        self.align = align; self.vAlign = vAlign; self.list = list; self.colorHex = colorHex; self.size = size
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName)
        bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? false
        italic = try c.decodeIfPresent(Bool.self, forKey: .italic) ?? false
        underline = try c.decodeIfPresent(Bool.self, forKey: .underline) ?? false
        align = try c.decodeIfPresent(Align.self, forKey: .align) ?? .left
        vAlign = try c.decodeIfPresent(VAlign.self, forKey: .vAlign) ?? .top
        list = try c.decodeIfPresent(ListStyle.self, forKey: .list) ?? .none
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex)
        size = try c.decodeIfPresent(Double.self, forKey: .size)
    }
}

public struct Style: Codable, Equatable, Sendable {
    /// Cor da linha (contorno, seta, linha).
    public var colorHex: String
    public var lineWidth: Double
    /// `false` = sem contorno (retângulo, elipse, callout, caixa de texto).
    public var lineVisible: Bool
    public var shadow: Bool
    /// Preenchimento opcional. `nil` = sem preenchimento.
    public var fillHex: String?
    public var opacity: Double
    public var text: TextFormat
    /// Formato da numeração (só para etapas).
    public var stepFormat: StepFormat

    public init(colorHex: String = "#FF3B30", lineWidth: Double = 4, shadow: Bool = false,
                fillHex: String? = nil, opacity: Double = 1, lineVisible: Bool = true, text: TextFormat = TextFormat(),
                stepFormat: StepFormat = .arabic) {
        self.colorHex = colorHex; self.lineWidth = lineWidth; self.shadow = shadow
        self.fillHex = fillHex; self.opacity = opacity; self.lineVisible = lineVisible; self.text = text; self.stepFormat = stepFormat
    }

    // Ficheiros antigos não têm os campos novos: valores por omissão.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        colorHex = try c.decode(String.self, forKey: .colorHex)
        lineWidth = try c.decode(Double.self, forKey: .lineWidth)
        shadow = try c.decodeIfPresent(Bool.self, forKey: .shadow) ?? false
        fillHex = try c.decodeIfPresent(String.self, forKey: .fillHex)
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        lineVisible = try c.decodeIfPresent(Bool.self, forKey: .lineVisible) ?? true
        text = try c.decodeIfPresent(TextFormat.self, forKey: .text) ?? TextFormat()
        stepFormat = try c.decodeIfPresent(StepFormat.self, forKey: .stepFormat) ?? .arabic
    }
}

/// Geometria em coordenadas da imagem original (independente de resolução).
public enum Shape: Codable, Equatable, Sendable {
    case arrow(from: Point, to: Point)
    case line(from: Point, to: Point)
    case rect(origin: Point, width: Double, height: Double)
    case ellipse(origin: Point, width: Double, height: Double)
    /// Texto simples sem caixa (formato antigo; ao editar converte-se em `textBox`).
    case text(origin: Point, string: String, fontSize: Double)
    /// Caixa de texto: o alinhamento horizontal/vertical é relativo à caixa.
    case textBox(origin: Point, width: Double, height: Double, string: String, fontSize: Double)
    /// Círculo numerado. `radius == nil` = tamanho padrão (`Shape.defaultStepRadius`); ficheiros antigos não têm raio.
    case step(center: Point, number: Int, radius: Double? = nil)
    case highlight(origin: Point, width: Double, height: Double)
    case blur(origin: Point, width: Double, height: Double, radius: Double)
    /// Desfoque gaussiano da região (`intensity` = raio do desfoque, em pixels da imagem).
    case gaussian(origin: Point, width: Double, height: Double, intensity: Double)
    /// Imagem colada; o ficheiro fica em `assets/<asset>` dentro do pacote.
    case image(origin: Point, width: Double, height: Double, asset: String)
    /// Caixa de texto com ponteiro (`tail`) apontando para algo na imagem.
    case callout(origin: Point, width: Double, height: Double, tail: Point, string: String, fontSize: Double)
}

public struct Annotation: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var z: Int
    public var visible: Bool
    public var shape: Shape
    public var style: Style
    /// Texto dentro de retângulos e elipses (as outras formas guardam o texto na própria forma).
    public var caption: String
    /// Rotação em graus (sentido dos ponteiros do relógio), à volta do centro da forma. A geometria da forma fica sem rodar;
    /// quem roda é o desenho, o teste de toque e as alças.
    public var rotation: Double

    public init(id: UUID = UUID(), z: Int, visible: Bool = true, shape: Shape, style: Style = Style(), caption: String = "", rotation: Double = 0) {
        self.id = id; self.z = z; self.visible = visible; self.shape = shape; self.style = style; self.caption = caption; self.rotation = rotation
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        z = try c.decode(Int.self, forKey: .z)
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        shape = try c.decode(Shape.self, forKey: .shape)
        style = try c.decode(Style.self, forKey: .style)
        caption = try c.decodeIfPresent(String.self, forKey: .caption) ?? ""
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
    }
}

/// Onde a imagem original é desenhada no documento: pode ser deslocada, redimensionada (em proporção ou não) e rodada.
/// Os píxeis originais nunca mudam; isto é só o enquadramento.
public struct ImageFrame: Codable, Equatable, Sendable {
    public var origin: Point
    public var width: Double
    public var height: Double
    /// Graus, sentido dos ponteiros do relógio, à volta do centro.
    public var rotation: Double
    public init(origin: Point, width: Double, height: Double, rotation: Double = 0) {
        self.origin = origin; self.width = width; self.height = height; self.rotation = rotation
    }
    public init(_ r: Rect, rotation: Double = 0) { self.init(origin: Point(x: r.x, y: r.y), width: r.width, height: r.height, rotation: rotation) }
    public var rect: Rect { Rect(x: origin.x, y: origin.y, width: width, height: height) }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        origin = try c.decode(Point.self, forKey: .origin)
        width = try c.decode(Double.self, forKey: .width)
        height = try c.decode(Double.self, forKey: .height)
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
    }
}

/// Área de trabalho: a parte do mundo (imagem + espaço extra) que é exportada.
/// Pode ser maior que a imagem original (expandida) ou menor (recorte), e a imagem original nunca é alterada.
public struct WorkArea: Codable, Equatable, Sendable {
    public var origin: Point
    public var width: Double
    public var height: Double
    public init(origin: Point, width: Double, height: Double) {
        self.origin = origin; self.width = width; self.height = height
    }
    public var rect: Rect { Rect(x: origin.x, y: origin.y, width: width, height: height) }
    public init(_ r: Rect) { self.init(origin: Point(x: r.x, y: r.y), width: r.width, height: r.height) }
}

public struct CaptureDocument: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int = CaptureDocument.currentFormatVersion
    public var canvasWidth: Double
    public var canvasHeight: Double
    /// `nil` = a área é a própria imagem original.
    public var workArea: WorkArea?
    /// Enquadramento da imagem original (posição, tamanho e rotação). `nil` = na origem, ao tamanho natural, sem rodar.
    public var imageFrame: ImageFrame?
    /// Cor de fundo onde a área vai além da imagem.
    public var backgroundHex: String = "#FFFFFF"
    public var transparentBackground: Bool = false
    /// Expande a área sozinha quando um objeto sai dela.
    public var autoExpand: Bool = true
    /// Número da próxima etapa, se foi reiniciado/definido pelo utilizador; `nil` = continuar a sequência.
    public var nextStepNumber: Int?
    public private(set) var annotations: [Annotation] = []

    public init(canvasWidth: Double, canvasHeight: Double) {
        self.canvasWidth = canvasWidth; self.canvasHeight = canvasHeight
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, canvasWidth, canvasHeight, workArea, crop, imageFrame, backgroundHex, transparentBackground, autoExpand, nextStepNumber, annotations
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        canvasWidth = try c.decode(Double.self, forKey: .canvasWidth)
        canvasHeight = try c.decode(Double.self, forKey: .canvasHeight)
        // "crop" é o nome antigo da área de trabalho.
        workArea = try c.decodeIfPresent(WorkArea.self, forKey: .workArea) ?? c.decodeIfPresent(WorkArea.self, forKey: .crop)
        imageFrame = try c.decodeIfPresent(ImageFrame.self, forKey: .imageFrame)
        backgroundHex = try c.decodeIfPresent(String.self, forKey: .backgroundHex) ?? "#FFFFFF"
        transparentBackground = try c.decodeIfPresent(Bool.self, forKey: .transparentBackground) ?? false
        autoExpand = try c.decodeIfPresent(Bool.self, forKey: .autoExpand) ?? true
        nextStepNumber = try c.decodeIfPresent(Int.self, forKey: .nextStepNumber)
        annotations = try c.decodeIfPresent([Annotation].self, forKey: .annotations) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(formatVersion, forKey: .formatVersion)
        try c.encode(canvasWidth, forKey: .canvasWidth)
        try c.encode(canvasHeight, forKey: .canvasHeight)
        try c.encodeIfPresent(workArea, forKey: .workArea)
        try c.encodeIfPresent(imageFrame, forKey: .imageFrame)
        try c.encode(backgroundHex, forKey: .backgroundHex)
        try c.encode(transparentBackground, forKey: .transparentBackground)
        try c.encode(autoExpand, forKey: .autoExpand)
        try c.encodeIfPresent(nextStepNumber, forKey: .nextStepNumber)
        try c.encode(annotations, forKey: .annotations)
    }

    /// Tamanho natural da imagem original (os píxeis).
    public var naturalImageRect: Rect { Rect(x: 0, y: 0, width: canvasWidth, height: canvasHeight) }
    /// Onde a imagem é desenhada (antes de rodar), em coordenadas do documento.
    public var imagePlacement: Rect { imageFrame?.rect ?? naturalImageRect }
    public var imageRotation: Double { imageFrame?.rotation ?? 0 }
    /// Caixa envolvente da imagem no documento (com a rotação). Sem enquadramento, é a própria imagem na origem.
    public var imageRect: Rect { Geometry.boundingBox(of: imagePlacement, rotatedBy: imageRotation) }

    /// Muda o enquadramento da imagem (tamanho mínimo 8 px). Voltar ao natural limpa o campo.
    public mutating func setImageFrame(_ r: Rect, rotation: Double) {
        let rr = Rect(x: r.x, y: r.y, width: max(8, r.width), height: max(8, r.height))
        let rot = Geometry.normalizedDegrees(rotation)
        imageFrame = (rr == naturalImageRect && rot == 0) ? nil : ImageFrame(rr, rotation: rot)
    }

    /// Expande a área (se ligada e se for uma área própria) para conter a imagem enquadrada. Devolve `true` se mudou.
    @discardableResult
    public mutating func expandAreaToFitImage() -> Bool {
        guard autoExpand, workArea != nil else { return false }
        let current = area
        return setArea(roundedOut: current.union(imageRect), if: current)
    }

    /// Área que será exportada.
    public var area: Rect { workArea?.rect ?? imageRect }

    /// Expande a área para conter os objetos indicados (nunca a encolhe). Só atua com `autoExpand` ligado.
    /// Considera apenas esses objetos: se a área foi encolhida de propósito, mexer noutro objeto não a reabre.
    /// Devolve `true` se a área mudou.
    @discardableResult
    public mutating func expandAreaToFit(ids: [UUID]) -> Bool {
        guard autoExpand else { return false }
        let current = area
        var union = current
        for a in annotations where a.visible && ids.contains(a.id) { union = union.union(a.worldBounds) }
        return setArea(roundedOut: union, if: current)
    }

    /// Área = imagem original + todos os objetos visíveis ("ajustar ao conteúdo").
    public mutating func fitAreaToContent() {
        var union = imageRect
        for a in annotations where a.visible { union = union.union(a.worldBounds) }
        _ = setArea(roundedOut: union, if: nil)
    }

    /// Arredonda para fora (pixels inteiros) e grava, se diferente da área atual.
    private mutating func setArea(roundedOut r: Rect, if current: Rect?) -> Bool {
        let x0 = r.minX.rounded(.down), y0 = r.minY.rounded(.down)
        let x1 = r.maxX.rounded(.up), y1 = r.maxY.rounded(.up)
        let grown = Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        guard grown != (current ?? area) else { return false }
        workArea = grown == imageRect ? nil : WorkArea(grown)
        return true
    }

    /// Número que a próxima etapa vai receber.
    public var upcomingStepNumber: Int {
        if let n = nextStepNumber { return n }
        let last = ordered.last { if case .step = $0.shape { return true } else { return false } }
        return (last?.shape.stepNumber ?? 0) + 1
    }

    /// Anotações por ordem de desenho.
    public var ordered: [Annotation] { annotations.sorted { $0.z < $1.z } }

    @discardableResult
    public mutating func add(_ shape: Shape, style: Style = Style()) -> Annotation {
        let a = Annotation(z: (annotations.map(\.z).max() ?? -1) + 1, shape: shape, style: style)
        annotations.append(a)
        return a
    }

    @discardableResult
    public mutating func remove(id: UUID) -> Annotation? {
        guard let i = annotations.firstIndex(where: { $0.id == id }) else { return nil }
        return annotations.remove(at: i)
    }

    public mutating func update(_ annotation: Annotation) {
        if let i = annotations.firstIndex(where: { $0.id == annotation.id }) { annotations[i] = annotation }
    }

    public mutating func bringToFront(id: UUID) {
        guard let i = annotations.firstIndex(where: { $0.id == id }) else { return }
        annotations[i].z = (annotations.map(\.z).max() ?? 0) + 1
    }

    public mutating func sendToBack(id: UUID) {
        guard let i = annotations.firstIndex(where: { $0.id == id }) else { return }
        annotations[i].z = (annotations.map(\.z).min() ?? 0) - 1
    }

    public mutating func setVisible(id: UUID, _ visible: Bool) {
        guard let i = annotations.firstIndex(where: { $0.id == id }) else { return }
        annotations[i].visible = visible
    }

    /// Reinsere uma anotação removida (usado por undo).
    public mutating func insert(_ annotation: Annotation) {
        guard !annotations.contains(where: { $0.id == annotation.id }) else { return }
        annotations.append(annotation)
    }

    /// Insere uma cópia (ex.: colar): novo id, no topo, com deslocamento opcional.
    @discardableResult
    public mutating func insertCopy(of a: Annotation, dx: Double = 0, dy: Double = 0) -> Annotation {
        var n = a
        n.id = UUID()
        n.z = (annotations.map(\.z).max() ?? -1) + 1
        n.shape = a.shape.translated(dx: dx, dy: dy)
        annotations.append(n)
        return n
    }
}
