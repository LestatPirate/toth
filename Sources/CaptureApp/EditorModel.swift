// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit
import CaptureCore

enum Tool: String, CaseIterable, Identifiable {
    case select, area, arrow, line, text, callout, rect, ellipse, step, stamp, highlight, blur, gaussian, repair, ocr, canvas
    var id: String { rawValue }
    var title: String {
        switch self {
        case .select: L("Mover"); case .arrow: L("Seta"); case .line: L("Linha"); case .callout: L("Balão"); case .rect: L("Retângulo")
        case .ellipse: L("Elipse"); case .text: L("Texto"); case .step: L("Etapa"); case .highlight: L("Marcador"); case .blur: L("Pixelização"); case .gaussian: L("Blur"); case .canvas: L("Tela")
        case .stamp: L("Carimbo"); case .repair: L("Reparo"); case .area: L("Selecionar"); case .ocr: L("Texto da imagem")
        }
    }
    /// Estilo inicial de cada ferramenta (cada uma lembra o seu último estilo).
    var initialStyle: Style {
        switch self {
        case .highlight: Style(colorHex: "#FFD60A", opacity: 0.4)
        case .text: Style(lineVisible: false)                  // caixa de texto: sem contorno nem fundo
        case .callout: Style(fillHex: "#FFFFFF")               // balão: fundo branco
        default: Style()
        }
    }
    var symbol: String {
        switch self {
        case .select: "cursorarrow"; case .arrow: "arrow.up.right"; case .line: "line.diagonal"; case .callout: "bubble.left"; case .rect: "rectangle"
        case .ellipse: "circle"; case .text: "textformat"; case .step: "1.circle"; case .highlight: "highlighter"; case .blur: "square.grid.3x3"; case .gaussian: "drop"; case .canvas: "aspectratio"
        case .stamp: "checkmark.seal"; case .repair: "bandage"; case .area: "selection.pin.in.out"; case .ocr: "text.viewfinder"
        }
    }
}

/// Na ferramenta Tela: o que as alças editam.
enum CanvasTarget { case area, image }

@MainActor
final class EditorModel: ObservableObject {
    @Published private(set) var doc: CaptureDocument
    @Published var tool: Tool = .arrow {
        didSet {
            if tool != oldValue { toolLocked = false }
            if tool == .canvas && oldValue != .canvas { canvasEntryDepth = undoStack.count }
            if tool == .ocr && oldValue != .ocr { recognizeText() }
            if tool != .ocr && oldValue == .ocr { selectedBlocks = [] }
        }
    }
    @Published var selection: UUID? { didSet { if selection == nil { extraSelection = [] } else { extraSelection.remove(selection!) } } }
    /// Os outros elementos selecionados (⇧+clique, laço): `selection` é o principal (o do painel e das alças).
    @Published var extraSelection: Set<UUID> = []
    var selectedIDs: Set<UUID> { var s = extraSelection; if let p = selection { s.insert(p) }; return s }
    var selectedAll: [Annotation] { doc.ordered.filter { selectedIDs.contains($0.id) } }
    func isSelected(_ id: UUID) -> Bool { selectedIDs.contains(id) }
    /// Seleciona `id` (e o seu grupo); com `extend`, junta-o ou tira-o da seleção (o grupo inteiro de uma vez).
    func select(_ id: UUID, extend: Bool) {
        let members = Set(doc.groupMembers(of: id))
        guard extend else { selectWithGroup(id); return }
        if isSelected(id) {
            let rest = selectedIDs.subtracting(members)
            let p = (selection.map { rest.contains($0) } ?? false) ? selection : rest.first
            selection = p; extraSelection = rest.subtracting(p.map { [$0] } ?? [])
            return
        }
        let p = selection ?? id
        selection = p; extraSelection = selectedIDs.union(members).subtracting([p])
    }
    func selectIDs(_ ids: Set<UUID>) {
        let ordered = doc.ordered.map(\.id).filter { ids.contains($0) }
        selection = ordered.last; extraSelection = Set(ordered.dropLast())
    }
    func selectAll() {
        if tool == .area { selectWholeArea(); return }
        selectIDs(Set(doc.annotations.filter { $0.visible && isShown($0) }.map(\.id)))
    }
    /// Seleciona `id` e, se estiver num grupo, o grupo inteiro (com `id` como principal).
    func selectWithGroup(_ id: UUID) {
        let members = doc.groupMembers(of: id)
        selection = id; extraSelection = Set(members).subtracting([id])
    }
    /// Estende um conjunto de ids aos grupos inteiros dos seus membros.
    func withGroups(_ ids: Set<UUID>) -> Set<UUID> { var out = ids; for id in ids { out.formUnion(doc.groupMembers(of: id)) }; return out }
    var isMultiSelection: Bool { !extraSelection.isEmpty }

    // MARK: Grupos, alinhar e distribuir

    var canGroup: Bool { selectedIDs.count >= 2 }
    var canUngroup: Bool { selectedAll.contains { $0.group != nil } }
    func groupSelection() {
        let ids = selectedIDs
        guard ids.count >= 2 else { return }
        perform { $0.group(ids) }
    }
    func ungroupSelection() {
        let ids = selectedIDs
        guard !ids.isEmpty else { return }
        perform { $0.ungroup(ids) }
    }

    enum Alignment { case left, centerX, right, top, centerY, bottom }
    /// Alinha os selecionados entre si (pela caixa envolvente da seleção); com um só, alinha-o à área de trabalho.
    func alignSelection(_ edge: Alignment) {
        let all = selectedAll
        guard !all.isEmpty else { return }
        let ref = all.count == 1 ? doc.area : selectionBounds!
        perform { d in
            for var a in all {
                let b = a.worldBounds
                var dx = 0.0, dy = 0.0
                switch edge {
                case .left: dx = ref.minX - b.minX
                case .centerX: dx = (ref.minX + ref.width / 2) - (b.minX + b.width / 2)
                case .right: dx = ref.maxX - b.maxX
                case .top: dy = ref.minY - b.minY
                case .centerY: dy = (ref.minY + ref.height / 2) - (b.minY + b.height / 2)
                case .bottom: dy = ref.maxY - b.maxY
                }
                a.shape = a.shape.translated(dx: dx, dy: dy); d.update(a)
            }
            _ = d.expandAreaToFit(ids: all.map(\.id))
        }
    }

    /// Espaça os selecionados por igual (3 ou mais): as pontas ficam, os do meio distribuem-se com intervalos iguais.
    func distributeSelection(horizontal: Bool) {
        let all = selectedAll
        guard all.count >= 3 else { return }
        let sorted = all.sorted { horizontal ? $0.worldBounds.minX < $1.worldBounds.minX : $0.worldBounds.minY < $1.worldBounds.minY }
        let first = sorted.first!.worldBounds, last = sorted.last!.worldBounds
        let total = horizontal ? last.maxX - first.minX : last.maxY - first.minY
        let content = sorted.reduce(0.0) { $0 + (horizontal ? $1.worldBounds.width : $1.worldBounds.height) }
        let gap = (total - content) / Double(sorted.count - 1)
        perform { d in
            var cursor = horizontal ? first.minX : first.minY
            for var a in sorted {
                let b = a.worldBounds
                if horizontal { a.shape = a.shape.translated(dx: cursor - b.minX, dy: 0); cursor += b.width + gap }
                else { a.shape = a.shape.translated(dx: 0, dy: cursor - b.minY); cursor += b.height + gap }
                d.update(a)
            }
        }
    }

    /// Durante um gesto (sem ponto de undo): os elementos de partida `start` escalados por `k` à volta de `c`.
    func scaleLive(_ start: [Annotation], by k: Double, around c: Point) {
        mutate { d in for a in start { d.update(a.scaled(by: max(0.02, k), around: c)) }; _ = d.expandAreaToFit(ids: start.map(\.id)) }
    }
    /// Durante um gesto (sem ponto de undo): os elementos de partida rodados por `d` graus à volta de `c`.
    func rotateLive(_ start: [Annotation], by deg: Double, around c: Point) {
        mutate { d in for a in start { d.update(a.rotated(by: deg, around: c)) }; _ = d.expandAreaToFit(ids: start.map(\.id)) }
    }
    /// Ferramenta presa (duplo clique no ícone): continua ativa depois de desenhar. Sem isto, depois de um objeto volta a Mover.
    @Published var toolLocked = false
    /// Elemento sob o rato (para o destaque ao passar por cima).
    @Published var hover: UUID?
    /// Quantos pontos de undo havia ao entrar na Tela (Esc cancela até aqui).
    private var canvasEntryDepth = 0
    /// Na Tela: a área de trabalho (alças azuis) ou a imagem original (mover, redimensionar, rodar).
    @Published var canvasTarget: CanvasTarget = .area
    /// Ao redimensionar a imagem pelos cantos, manter a proporção (⇧ inverte).
    @Published var keepImageAspect = true
    /// Ao redimensionar um objeto com texto: com «proporção» a letra acompanha o tamanho; sem, só a caixa muda e o texto
    /// quebra de linha (por palavras, sem hifenização). Guardado entre sessões.
    var textScalesWithBox: Bool {
        get { (UserDefaults.standard.object(forKey: "textScalesWithBox") as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "textScalesWithBox"); objectWillChange.send() }
    }
    /// Estilo da ferramenta atual: o último que o utilizador usou (guardado entre sessões, ver `ToolDefaults`).
    var style: Style {
        get { ToolDefaults.shared.style(for: tool) }
        set {
            if tool != .select { ToolDefaults.shared.setStyle(newValue, for: tool) }
            objectWillChange.send()
        }
    }

    /// Tamanho dos blocos da pixelização / intensidade do blur / tamanho da letra: também guardados entre sessões.
    var defaultPixelSize: Double {
        get { ToolDefaults.shared.value("pixelSize", for: .blur, default: 12) }
        set { ToolDefaults.shared.setValue(newValue, "pixelSize", for: .blur); objectWillChange.send() }
    }
    var defaultBlurIntensity: Double {
        get { ToolDefaults.shared.value("intensity", for: .gaussian, default: 8) }
        set { ToolDefaults.shared.setValue(newValue, "intensity", for: .gaussian); objectWillChange.send() }
    }
    /// Tamanho da letra da ferramenta atual.
    var defaultFontSize: Double { fontSize(for: tool) }

    // MARK: Carimbos

    /// O carimbo escolhido (`"sf:nome"` ou emoji) e o tamanho com que nascem (lado maior, em px do documento).
    var currentStamp: String {
        get { UserDefaults.standard.string(forKey: "stampSymbol") ?? StampLibrary.symbolKey("checkmark.circle.fill") }
        set { UserDefaults.standard.set(newValue, forKey: "stampSymbol"); objectWillChange.send() }
    }
    var defaultStampSize: Double {
        get { ToolDefaults.shared.value("size", for: .stamp, default: 64) }
        set { ToolDefaults.shared.setValue(max(8, newValue), "size", for: .stamp); objectWillChange.send() }
    }
    /// Escolhe um carimbo: muda o selecionado (se for um carimbo) ou passa a ser o das próximas.
    func chooseStamp(_ symbol: String) {
        currentStamp = symbol
        if var a = selected, a.shape.stampSymbol != nil { a.shape = a.shape.with(stampSymbol: symbol); perform { $0.update(a) } }
    }
    /// Põe um carimbo (símbolo/emoji) centrado em `p`, com o tamanho padrão.
    func addStamp(at p: Point, symbol: String? = nil) {
        let s = defaultStampSize
        let id = addAnnotation(.stamp(origin: Point(x: p.x - s / 2, y: p.y - s / 2), width: s, height: s, symbol: symbol ?? currentStamp))
        mutate { _ = $0.expandAreaToFit(ids: [id]) }
        finishedDrawing()
    }
    /// Põe uma imagem da biblioteca de carimbos centrada em `p` (fica dentro do documento como `image`).
    func addImageStamp(_ url: URL, at p: Point) {
        guard let png = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: png), let name = try? assets.add(png: png) else { NSSound.beep(); return }
        let s = defaultStampSize, ratio = Double(rep.pixelsWide) / max(1, Double(rep.pixelsHigh))
        let w = ratio >= 1 ? s : s * ratio, h = ratio >= 1 ? s / ratio : s
        let id = addAnnotation(.image(origin: Point(x: p.x - w / 2, y: p.y - h / 2), width: w, height: h, asset: name))
        mutate { _ = $0.expandAreaToFit(ids: [id]) }
        finishedDrawing()
    }

    // MARK: Texto da imagem (reconhecimento)

    /// As linhas de texto reconhecidas na imagem (só enquanto a ferramenta está ativa).
    @Published var textBlocks: [TextBlock] = []
    @Published var recognizing = false
    @Published var selectedBlocks: Set<UUID> = []
    @Published var recognitionError: String?
    private var recognitionRun = 0

    /// Reconhece o texto da imagem como está (em segundo plano; o resultado chega ao painel e ao canvas).
    func recognizeText() {
        guard let r = renderedPixels(), let img = renderedImage() else { return }
        recognitionRun += 1
        let run = recognitionRun
        recognizing = true; recognitionError = nil; selectedBlocks = []
        let origin = r.origin
        Task.detached(priority: .userInitiated) {
            let result = Result { try TextRecognizer.recognize(img, origin: origin) }
            await MainActor.run { [weak self] in
                guard let self, run == self.recognitionRun else { return }
                self.recognizing = false
                switch result {
                case .success(let blocks): self.textBlocks = blocks
                case .failure(let e): self.textBlocks = []; self.recognitionError = e.localizedDescription
                }
            }
        }
    }

    /// Versão síncrona (testes).
    func recognizeTextNow() {
        guard let r = renderedPixels(), let img = renderedImage() else { return }
        recognitionRun += 1
        recognizing = false; selectedBlocks = []
        textBlocks = (try? TextRecognizer.recognize(img, origin: r.origin)) ?? []
    }

    /// A imagem renderizada (área exportada) como CGImage.
    func renderedImage() -> CGImage? {
        guard let png = exportPNG(), let src = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// O texto reconhecido: os blocos marcados (ou todos), por ordem de leitura, uma linha cada.
    func recognizedText(all: Bool = false) -> String {
        let chosen = (all || selectedBlocks.isEmpty) ? textBlocks : textBlocks.filter { selectedBlocks.contains($0.id) }
        return chosen.map(\.text).joined(separator: "\n")
    }

    /// ⌘C na ferramenta: copia o texto reconhecido (marcado, ou todo).
    func copyRecognizedText(all: Bool = false) {
        let s = recognizedText(all: all)
        guard !s.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    /// ⌘C: conforme a ferramenta, texto reconhecido, píxeis da área, objetos, ou a imagem toda.
    func copyCommand() {
        if tool == .ocr { copyRecognizedText(); return }
        if selection != nil { copySelection() } else { copyToPasteboard() }
    }

    func toggleBlock(_ id: UUID, extend: Bool) {
        if extend { if selectedBlocks.contains(id) { selectedBlocks.remove(id) } else { selectedBlocks.insert(id) } }
        else { selectedBlocks = [id] }
    }

    /// Estilo adivinhado de um bloco (tamanho, cor, peso, fonte).
    func guessStyle(for block: TextBlock) -> GuessedTextStyle? {
        guard let r = renderedPixels() else { return nil }
        return TextRecognizer.guessStyle(for: block, pixels: r.pixels, width: r.width, height: r.height, origin: r.origin)
    }

    /// Torna um bloco editável: um Reparo apaga o texto original a partir do fundo e uma caixa de Texto com as mesmas
    /// palavras, tamanho e cor fica por cima, agrupada com ele. Devolve o id da caixa de texto (já selecionada).
    @discardableResult
    func editTextBlock(_ id: UUID) -> UUID? {
        guard let block = textBlocks.first(where: { $0.id == id }), let g = guessStyle(for: block) else { return nil }
        let r = block.rect
        let pad = max(2, r.height * 0.2)
        let patch = Rect(x: (r.minX - pad).rounded(.down), y: (r.minY - pad).rounded(.down), width: (r.width + 2 * pad).rounded(.up), height: (r.height + 2 * pad).rounded(.up))
        var fmt = TextFormat(); fmt.fontName = g.fontName; fmt.bold = g.bold; fmt.colorHex = g.colorHex
        let font = RichText.font(fmt, size: g.fontSize)
        // a 1.ª linha do texto começa no topo da caixa (mais a margem); as maiúsculas ficam a (ascender − capHeight) daí
        let hasTall = block.text.contains { $0.isUppercase || $0.isNumber || "bdfhklt".contains($0) }
        let topGap = Double(font.ascender - (hasTall ? font.capHeight : font.xHeight))
        let lineH = Double(font.ascender - font.descender + font.leading)
        let origin = Point(x: r.minX - Double(RichText.padX), y: r.minY - topGap - Double(RichText.padY))
        let box = Shape.textBox(origin: origin, width: r.width + 2 * Double(RichText.padX) + g.fontSize * 0.75, height: max(lineH + 2 * Double(RichText.padY), 48), string: block.text, fontSize: g.fontSize)
        var textStyle = Style(lineVisible: false); textStyle.text = fmt
        let group = UUID()
        var textID = UUID()
        perform { d in
            var p = d.add(.patch(origin: Point(x: patch.x, y: patch.y), width: patch.width, height: patch.height), style: Style()); p.group = group; d.update(p)
            var t = d.add(box, style: textStyle); t.group = group; d.update(t); textID = t.id
            _ = d.expandAreaToFit(ids: [t.id])
        }
        textBlocks.removeAll { $0.id == id }
        selectedBlocks.remove(id)
        tool = .select
        selection = textID
        return textID
    }

    // MARK: Selecionar área (retângulo, elipse, varinha)

    enum AreaMode: String { case rect, ellipse, wand }
    /// A área selecionada (não fica no ficheiro; é um estado da edição).
    @Published var areaSelection: AreaMask?
    var areaMode: AreaMode {
        get { AreaMode(rawValue: UserDefaults.standard.string(forKey: "areaMode") ?? "") ?? .rect }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "areaMode"); objectWillChange.send() }
    }
    /// Como a próxima seleção se combina com a que já existe (como no Pixelmator: nova, juntar, tirar). ⇧/⌥ sobrepõem-se.
    var areaCombineMode: AreaMask.Combine {
        get {
            switch UserDefaults.standard.string(forKey: "areaCombineMode") { case "add": return .add; case "subtract": return .subtract; default: return .replace }
        }
        set {
            UserDefaults.standard.set(newValue == .add ? "add" : newValue == .subtract ? "subtract" : "replace", forKey: "areaCombineMode"); objectWillChange.send()
        }
    }
    /// Tolerância da varinha (0…255 na maior diferença entre canais) e se apanha só píxeis contíguos.
    var wandTolerance: Double {
        get { (UserDefaults.standard.object(forKey: "wandTolerance") as? Double) ?? 32 }
        set { UserDefaults.standard.set(max(0, min(255, newValue)), forKey: "wandTolerance"); objectWillChange.send() }
    }
    var wandContiguous: Bool {
        get { (UserDefaults.standard.object(forKey: "wandContiguous") as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "wandContiguous"); objectWillChange.send() }
    }

    /// Os píxeis do documento como está (área exportada), RGBA, com a origem da área.
    func renderedPixels() -> (pixels: [UInt8], width: Int, height: Int, origin: Point)? {
        guard let png = exportPNG(), let src = CGImageSourceCreateWithData(png as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))   // (a 1.ª fila em memória é a de cima)
        let a = doc.area
        return (px, w, h, Point(x: a.minX.rounded(.down), y: a.minY.rounded(.down)))
    }

    /// Junta, tira ou substitui a seleção por `m` (em coordenadas do documento).
    func selectArea(_ m: AreaMask, combine: AreaMask.Combine = .replace) {
        let next = (areaSelection.map { $0.combined(with: m, combine) } ?? (combine == .subtract ? nil : m))
        areaSelection = (next?.isEmpty ?? true) ? nil : next
    }

    /// Píxeis renderizados guardados durante um gesto da varinha (arrastar vai apanhando mais zonas sem voltar a desenhar).
    private var wandCache: (pixels: [UInt8], width: Int, height: Int, origin: Point)?
    func wandBegin() { wandCache = renderedPixels() }
    func wandEnd() { wandCache = nil }

    /// Varinha: os píxeis parecidos com o do ponto `p` (do documento). Devolve `false` se não houver píxel nesse ponto.
    @discardableResult
    func wandSelect(at p: Point, combine: AreaMask.Combine = .replace) -> Bool {
        guard let r = wandCache ?? renderedPixels() else { return false }
        let local = Point(x: p.x - r.origin.x, y: p.y - r.origin.y)
        guard var m = AreaMask.wand(pixels: r.pixels, width: r.width, height: r.height, at: local, tolerance: Int(wandTolerance), contiguous: wandContiguous) else { return false }
        m.x += Int(r.origin.x); m.y += Int(r.origin.y)
        selectArea(m, combine: combine)
        return true
    }

    /// Varinha a arrastar: junta (ou tira) a zona parecida com o píxel por onde o rato passa, se ainda não estiver (ou já estiver) na seleção.
    func wandExtend(at p: Point, subtract: Bool) {
        let inside = areaSelection?.contains(p) ?? false
        if subtract ? !inside : inside { return }
        wandSelect(at: p, combine: subtract ? .subtract : .add)
    }

    func selectWholeArea() { areaSelection = AreaMask.rect(doc.area) }
    func clearAreaSelection() { areaSelection = nil }

    /// Grava a máscara em `assets/` (PNG em tons de cinzento: branco = dentro); `nil` se for um retângulo cheio.
    private func maskAsset(_ m: AreaMask) -> String? {
        guard !m.isFullRect, m.width > 0, m.height > 0 else { return nil }
        var bytes = m.alpha
        guard let ctx = CGContext(data: &bytes, width: m.width, height: m.height, bitsPerComponent: 8, bytesPerRow: m.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let img = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { return nil }
        // (a 1.ª fila em memória é a de cima: a máscara já está na orientação certa)
        let name = "mask-\(UUID().uuidString).png"
        try? assets.write(png, as: name)
        return name
    }

    /// PNG dos píxeis da seleção (com a máscara como transparência).
    func selectionPNG() -> Data? {
        guard let m = areaSelection, !m.isEmpty, let r = renderedPixels() else { return nil }
        var out = [UInt8](repeating: 0, count: m.width * m.height * 4)
        for j in 0..<m.height { for i in 0..<m.width {
            let x = m.x + i - Int(r.origin.x), y = m.y + j - Int(r.origin.y)
            guard x >= 0, y >= 0, x < r.width, y < r.height else { continue }
            let a = Int(m.alpha[j * m.width + i]); let s = (y * r.width + x) * 4, d = (j * m.width + i) * 4
            out[d] = UInt8(Int(r.pixels[s]) * a / 255); out[d + 1] = UInt8(Int(r.pixels[s + 1]) * a / 255); out[d + 2] = UInt8(Int(r.pixels[s + 2]) * a / 255); out[d + 3] = UInt8(Int(r.pixels[s + 3]) * a / 255)
        } }
        guard let ctx = CGContext(data: &out, width: m.width, height: m.height, bitsPerComponent: 8, bytesPerRow: m.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let img = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
    }

    /// Levanta a seleção como um objeto imagem (os píxeis, com a forma da seleção); com `erase`, o sítio de onde saiu fica
    /// apagado (cor de fundo). Devolve o id do objeto novo e passa para Mover com ele selecionado.
    @discardableResult
    func liftSelection(erase: Bool) -> UUID? {
        guard let m = areaSelection, !m.isEmpty, let png = selectionPNG(), let name = try? assets.add(png: png) else { NSSound.beep(); return nil }
        let maskName = erase ? maskAsset(m) : nil
        var id = UUID()
        perform { d in
            if erase { d.add(.erase(origin: Point(x: Double(m.x), y: Double(m.y)), width: Double(m.width), height: Double(m.height), mask: maskName)) }
            id = d.add(.image(origin: Point(x: Double(m.x), y: Double(m.y)), width: Double(m.width), height: Double(m.height), asset: name), style: Style(lineVisible: false)).id
        }
        areaSelection = nil
        selection = id
        tool = .select
        return id
    }

    /// Apaga a seleção (passa a cor de fundo, ou transparente).
    func eraseSelection() {
        guard let m = areaSelection, !m.isEmpty else { return }
        let maskName = maskAsset(m)
        perform { $0.add(.erase(origin: Point(x: Double(m.x), y: Double(m.y)), width: Double(m.width), height: Double(m.height), mask: maskName)) }
        areaSelection = nil
    }

    /// Preenche a seleção a partir do que a rodeia (Reparo).
    func fillSelection() {
        guard let m = areaSelection, !m.isEmpty else { return }
        let maskName = maskAsset(m)
        perform { $0.add(.patch(origin: Point(x: Double(m.x), y: Double(m.y)), width: Double(m.width), height: Double(m.height), mask: maskName)) }
        areaSelection = nil
    }

    /// Copia os píxeis da seleção (PNG com transparência) para a área de transferência.
    func copySelectionPixels() {
        guard let png = selectionPNG(), let image = NSImage(data: png) else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
        NSPasteboard.general.writeObjects([image])
    }

    // MARK: Reparo

    /// Modo do Reparo para os próximos: preencher a partir da vizinhança (`false`) ou clonar de outro sítio (`true`).
    var repairClones: Bool {
        get { UserDefaults.standard.bool(forKey: "repairClones") }
        set { UserDefaults.standard.set(newValue, forKey: "repairClones"); objectWillChange.send() }
    }
    var currentRepairClones: Bool { if case .clone = selected?.shape { return true }; if case .patch = selected?.shape { return false }; return repairClones }
    func setRepairClones(_ on: Bool) {
        repairClones = on
        guard var a = selected, a.shape.isRepair else { return }
        a.shape = a.shape.asRepair(clone: on)
        perform { $0.update(a) }
    }

    /// Tamanho da letra de uma ferramenta. No retângulo/elipse vive no estilo do texto; nas outras é um valor próprio.
    func fontSize(for tool: Tool) -> Double {
        if tool == .rect || tool == .ellipse { return ToolDefaults.shared.style(for: tool).text.size ?? 20 }
        return ToolDefaults.shared.value("fontSize", for: tool, default: 24)
    }
    /// `nil` = ajustar à janela.
    @Published var zoom: Double?
    @Published var pan: CGSize = .zero
    /// Escala de "ajustar", atualizada pelo canvas (não publicada).
    var fitScale: Double = 1
    /// Píxeis do ecrã por ponto (2 em Retina), atualizado pelo canvas. As capturas são em píxeis nativos: «1:1» mostra um píxel da
    /// imagem num píxel do ecrã (zoom = 1/deviceScale), e a percentagem mostrada é relativa aos píxeis do ecrã.
    var deviceScale: Double = 1
    /// Zoom relativo aos píxeis do ecrã (100% = um píxel da imagem num píxel do ecrã).
    var displayZoomPercent: Int { Int(((zoom ?? fitScale) * deviceScale * 100).rounded()) }
    /// Centro da zona visível, em coordenadas do documento (atualizado pelo canvas; usado ao colar).
    var visibleCenter = Point(x: 0, y: 0)
    let assets: AssetStore
    private let container: CaptureContainer
    var onSaved: (() -> Void)?
    let url: URL
    /// A imagem de fundo. No editor de imagem é o original (nunca muda); nas anotações de um vídeo é o fotograma atual.
    var base: CGImage { didSet { objectWillChange.send() } }
    /// Anotações de um vídeo: sem Tela nem área própria, e só se mostram as ativas no instante (`shownIDs`).
    var isVideoOverlay = false
    var shownIDs: Set<UUID>? { didSet { if shownIDs != oldValue { objectWillChange.send(); if let s = selection, !isShown(s) { selection = nil } } } }
    func isShown(_ id: UUID) -> Bool { shownIDs?.contains(id) ?? true }
    func isShown(_ a: Annotation) -> Bool { isShown(a.id) }
    /// Anotação mais acima (de entre as mostradas) que toca no ponto.
    func topmost(at p: Point, tolerance: Double) -> Annotation? { doc.ordered.last { $0.visible && isShown($0) && $0.hits(p, tolerance: tolerance) } }
    /// Chamado quando o utilizador acaba de criar uma anotação nova (para as anotações do vídeo ganharem início e fim).
    var onCreated: ((UUID) -> Void)?
    private var undoStack: [CaptureDocument] = []
    private var redoStack: [CaptureDocument] = []

    init(url: URL) throws {
        self.url = url
        let container = try CaptureContainer(url: url)
        self.container = container
        self.assets = AssetStore(container: container)
        self.doc = try CapturePackage.read(from: container)
        guard let original = container.data(CapturePackage.originalFile),
              let src = CGImageSourceCreateWithData(original as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw CocoaError(.fileReadCorruptFile) }
        self.base = img
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // MARK: Edição (cada gesto = um ponto de undo)

    func checkpoint() { undoStack.append(doc); redoStack.removeAll() }
    func dropLastCheckpoint() { _ = undoStack.popLast() }
    /// A forma do objeto no último ponto de undo (para saber se um gesto a mudou).
    func undoShape(of id: UUID) -> Shape? { undoStack.last?.annotations.first { $0.id == id }?.shape }

    /// Altera sem criar ponto de undo (usar entre checkpoint() e commit()).
    func mutate(_ f: (inout CaptureDocument) -> Void) { f(&doc) }

    /// Fim de um gesto: a área segue o conteúdo (se ligado) e grava-se.
    func commit() { doc.autoFitArea(); save() }

    /// Uma edição completa (ponto de undo, alteração, área a seguir o conteúdo se ligado, gravar).
    func perform(_ f: (inout CaptureDocument) -> Void) { checkpoint(); f(&doc); doc.autoFitArea(); save() }

    /// Uma edição da área feita à mão: desliga o ajuste automático (senão era desfeito logo a seguir).
    private func performArea(_ f: (inout CaptureDocument) -> Void) { checkpoint(); doc.autoExpand = false; f(&doc); save() }

    /// Depois de desenhar um objeto: a ferramenta volta a Mover, a não ser que esteja presa. Avisa quem quiser saber do objeto novo.
    func finishedDrawing() {
        if !toolLocked && tool != .select { tool = .select }
        if let id = selection { onCreated?(id) }
    }

    /// Esc: com uma ferramenta de desenho, volta a Mover; na Tela, cancela as alterações feitas nela; em Mover, limpa a seleção.
    func escape() {
        if tool == .canvas { cancelCanvas(); return }
        if areaSelection != nil { areaSelection = nil; return }
        if tool != .select { tool = .select; return }
        selection = nil
    }

    /// Desfaz tudo o que foi feito nesta visita à Tela e volta a Mover.
    func cancelCanvas() {
        while undoStack.count > canvasEntryDepth, canUndo { undo() }
        tool = .select
    }

    /// Setas: desloca os elementos selecionados (1 px; com ⇧, 10 px).
    func nudgeSelection(dx: Double, dy: Double) {
        let all = selectedAll
        guard !all.isEmpty else { return }
        perform { d in for var a in all { a.shape = a.shape.translated(dx: dx, dy: dy); d.update(a) }; _ = d.expandAreaToFit(ids: all.map(\.id)) }
    }

    /// Caixa envolvente (no documento) de todos os selecionados.
    var selectionBounds: Rect? {
        let all = selectedAll
        guard let first = all.first else { return nil }
        return all.dropFirst().reduce(first.worldBounds) { $0.union($1.worldBounds) }
    }

    /// ⌥+arrastar: duplica os selecionados no mesmo sítio e passa a seleção para as cópias (que depois se arrastam).
    func duplicateSelectionInPlace() { duplicate(selectedAll, dx: 0, dy: 0) }

    /// Cópias de `items` (com deslocamento), em que cada grupo original vira um grupo novo entre as cópias.
    private func duplicate(_ items: [Annotation], dx: Double, dy: Double) {
        guard !items.isEmpty else { return }
        var ids: [UUID] = []
        var groups: [UUID: UUID] = [:]
        for a in items { if let g = a.group, groups[g] == nil { groups[g] = UUID() } }
        perform { d in
            for a in items { ids.append(d.insertCopy(of: a, dx: dx, dy: dy, group: a.group.flatMap { groups[$0] }).id) }
            _ = d.expandAreaToFit(ids: ids)
        }
        selectIDs(Set(ids))
    }

    func addAnnotation(_ shape: Shape) -> UUID {
        var id = UUID()
        perform { id = $0.add(shape, style: style).id }
        selection = id
        return id
    }

    // MARK: Zoom

    func zoomIn() { zoom = min(8, (zoom ?? fitScale) * 1.25) }
    func zoomOut() { zoom = max(0.05, (zoom ?? fitScale) / 1.25) }
    func zoomFit() { zoom = nil; pan = .zero }
    /// Tamanho real: um píxel da imagem por píxel do ecrã (em Retina, metade dos pontos).
    func zoomActual() { zoom = 1 / max(1, deviceScale) }

    // MARK: Seleção e propriedades

    var selected: Annotation? { doc.annotations.first { $0.id == selection } }

    /// Estilo mostrado no painel: o do elemento selecionado, ou o padrão para novos.
    var currentStyle: Style { selected?.style ?? style }
    var currentFontSize: Double { selected?.effectiveFontSize ?? fontSize(for: tool) }

    var currentPixelSize: Double { selected?.shape.pixelSize ?? defaultPixelSize }

    func setPixelSize(_ v: Double) {
        defaultPixelSize = v
        guard let a = selected, a.shape.pixelSize != nil else { return }
        var n = a; n.shape = a.shape.with(pixelSize: v)
        perform { $0.update(n) }
    }

    func setFontSize(_ f: Double) {
        // Guarda como padrão da ferramenta que cria este tipo de elemento (a do elemento selecionado, ou a atual).
        let target = selected.flatMap { Tool.forShape($0.shape) } ?? tool
        if target == .rect || target == .ellipse {
            var st = ToolDefaults.shared.style(for: target); st.text.size = f
            ToolDefaults.shared.setStyle(st, for: target)
        } else {
            ToolDefaults.shared.setValue(f, "fontSize", for: target)
        }
        objectWillChange.send()
        guard var a = selected, a.effectiveFontSize != nil else { return }
        switch a.shape {
        case .rect, .ellipse: a.style.text.size = f
        default: a.shape = a.shape.with(fontSize: f)
        }
        perform { $0.update(a) }
    }

    // MARK: Etapas (numeração)

    /// Cria uma etapa com o número seguinte da sequência.
    func addStep(at p: Point) {
        var id = UUID()
        perform {
            let n = $0.upcomingStepNumber
            id = $0.add(.step(center: p, number: n, radius: defaultStepRadius), style: style).id
            $0.nextStepNumber = nil
        }
        selection = id
        finishedDrawing()
    }

    /// Raio com que nascem as etapas novas: o último usado (guardado entre sessões).
    var defaultStepRadius: Double {
        get { ToolDefaults.shared.value("stepRadius", for: .step, default: Shape.defaultStepRadius) }
        set { ToolDefaults.shared.setValue(newValue, "stepRadius", for: .step); objectWillChange.send() }
    }
    var currentStepRadius: Double { selected?.shape.stepRadius ?? defaultStepRadius }

    /// Tamanho da etapa selecionada (ou, sem seleção, das próximas).
    func setStepRadius(_ r: Double) {
        let clamped = min(max(r, Shape.stepRadiusLimits.lowerBound), Shape.stepRadiusLimits.upperBound)
        defaultStepRadius = clamped
        guard var a = selected, a.shape.stepRadius != nil else { return }
        a.shape = a.shape.with(stepRadius: clamped)
        perform { $0.update(a); _ = $0.expandAreaToFit(ids: [a.id]) }
    }

    /// Depois de redimensionar uma etapa com as alças, esse tamanho passa a ser o das próximas.
    func rememberStepSize() {
        if let r = selected?.shape.stepRadius { defaultStepRadius = r }
    }

    func restartSteps() { perform { $0.nextStepNumber = 1 } }
    func setNextStep(_ n: Int) { perform { $0.nextStepNumber = max(0, n) } }

    func setStepNumber(_ n: Int) {
        guard var a = selected, a.shape.stepNumber != nil else { return }
        a.shape = a.shape.with(stepNumber: max(0, n))
        perform { $0.update(a) }
    }

    func updateString(id: UUID, to text: String) {
        guard var a = doc.annotations.first(where: { $0.id == id }) else { return }
        a.setEditableString(text)
        perform { $0.update(a) }
    }

    func bringToFront(_ id: UUID) { perform { $0.bringToFront(id: id) } }
    func sendToBack(_ id: UUID) { perform { $0.sendToBack(id: id) } }
    func setVisible(_ id: UUID, _ v: Bool) { perform { $0.setVisible(id: id, v) } }
    func delete(_ id: UUID) {
        perform { $0.remove(id: id) }
        if selection == id { selection = nil }
    }

    // MARK: Área de trabalho

    var area: Rect { doc.area }

    /// Altera a área durante um gesto (sem ponto de undo; usar com checkpoint()/commit()).
    func setAreaLive(_ r: Rect) {
        let rr = Rect(x: r.x.rounded(), y: r.y.rounded(), width: max(8, r.width.rounded()), height: max(8, r.height.rounded()))
        mutate { $0.autoExpand = false; $0.workArea = rr == $0.imageRect ? nil : WorkArea(rr) }   // à mão: desliga o ajuste automático
    }

    /// Tamanho exato (mantém o canto superior esquerdo).
    func setAreaSize(width: Double, height: Double) {
        let a = doc.area
        performArea { $0.workArea = nil; $0.workArea = WorkArea(Rect(x: a.x, y: a.y, width: max(8, width.rounded()), height: max(8, height.rounded()))) }
    }

    func resetArea() { performArea { $0.workArea = nil } }

    // MARK: Enquadramento da imagem (Tela → Imagem)

    var imagePlacement: Rect { doc.imagePlacement }
    var imageRotation: Double { doc.imageRotation }
    var imageIsNatural: Bool { doc.imageFrame == nil }

    /// Altera o enquadramento durante um gesto (sem ponto de undo; usar com checkpoint()/commit()). Devolve se a área mudou.
    @discardableResult
    func setImageFrameLive(_ r: Rect, rotation: Double) -> Bool {
        var changed = false
        mutate { $0.setImageFrame(r, rotation: rotation); changed = $0.expandAreaToFitImage() }
        return changed
    }

    /// Tamanho da imagem (mantém o canto superior esquerdo do enquadramento). Com `keepAspect`, a outra medida acompanha.
    func setImageSize(width: Double? = nil, height: Double? = nil) {
        let p = doc.imagePlacement, ratio = doc.canvasWidth / max(1, doc.canvasHeight)
        var w = p.width, h = p.height
        if let width { w = max(8, width.rounded()); if keepImageAspect { h = max(8, (w / ratio).rounded()) } }
        if let height { h = max(8, height.rounded()); if keepImageAspect { w = max(8, (h * ratio).rounded()) } }
        perform { $0.setImageFrame(Rect(x: p.x, y: p.y, width: w, height: h), rotation: $0.imageRotation); _ = $0.expandAreaToFitImage() }
    }

    /// Escala da imagem face ao natural (1 = tamanho natural), pela largura.
    var imageScale: Double { doc.imagePlacement.width / max(1, doc.canvasWidth) }
    func setImageScale(_ k: Double) {
        let p = doc.imagePlacement
        perform { $0.setImageFrame(Rect(x: p.x, y: p.y, width: $0.canvasWidth * k, height: $0.canvasHeight * k), rotation: $0.imageRotation); _ = $0.expandAreaToFitImage() }
    }

    func setImageRotation(_ d: Double) {
        perform { $0.setImageFrame($0.imagePlacement, rotation: d); _ = $0.expandAreaToFitImage() }
    }
    func rotateImage(by d: Double) { setImageRotation(doc.imageRotation + d) }
    func resetImage() { perform { $0.imageFrame = nil } }

    // MARK: Rotação dos elementos

    var currentRotation: Double { selected?.rotation ?? 0 }

    func setRotation(_ d: Double) {
        guard var a = selected else { return }
        a.rotation = Geometry.normalizedDegrees(d)
        perform { $0.update(a); _ = $0.expandAreaToFit(ids: [a.id]) }
    }
    func rotateSelection(by d: Double) { if let a = selected { setRotation(a.rotation + d) } }
    func fitAreaToContent() { perform { $0.fitAreaToContent() } }
    func setAutoExpand(_ on: Bool) { perform { $0.autoExpand = on } }
    func setBackground(hex: String) { perform { $0.backgroundHex = hex } }
    func setTransparentBackground(_ on: Bool) { perform { $0.transparentBackground = on } }

    /// Expande a área para conter o objeto (se a expansão automática estiver ligada). Devolve se mudou.
    @discardableResult
    func expandAreaIfNeeded(for id: UUID) -> Bool {
        var changed = false
        mutate { changed = $0.expandAreaToFit(ids: [id]) }
        return changed
    }

    var currentBlurIntensity: Double { selected?.shape.blurIntensity ?? defaultBlurIntensity }

    func setBlurIntensity(_ v: Double) {
        defaultBlurIntensity = v
        guard let a = selected, a.shape.blurIntensity != nil else { return }
        var n = a; n.shape = a.shape.with(blurIntensity: v)
        perform { $0.update(n) }
    }

    func deleteSelection() {
        if tool == .area, areaSelection != nil { eraseSelection(); return }
        let ids = selectedIDs
        guard !ids.isEmpty else { return }
        perform { d in for id in ids { d.remove(id: id) } }
        selection = nil
    }

    func setStyle(_ s: Style) {
        // O estilo vira o padrão da ferramenta que cria este tipo de elemento (a do elemento selecionado, ou a atual).
        let target = selected.flatMap { Tool.forShape($0.shape) } ?? tool
        if target != .select { ToolDefaults.shared.setStyle(s, for: target) }
        objectWillChange.send()
        let all = selectedAll
        guard !all.isEmpty else { return }
        // o estilo aplica-se a todos os selecionados (do mesmo tipo do principal: cores e linha fazem sentido entre tipos, por isso a todos)
        perform { d in for var a in all { a.style = s; d.update(a) } }
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(doc); doc = prev; fixSelection(); save()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(doc); doc = next; fixSelection(); save()
    }

    private func fixSelection() {
        extraSelection = extraSelection.filter { id in doc.annotations.contains { $0.id == id } }
        if let s = selection, !doc.annotations.contains(where: { $0.id == s }) { selection = extraSelection.first; if let p = selection { extraSelection.remove(p) } }
    }

    // MARK: Copiar e colar

    /// Conteúdo copiado dentro da Capture: o objeto e, se for uma imagem, o próprio ficheiro
    /// (para poder colar noutro documento).
    private struct ClipPayload: Codable {
        var annotation: Annotation
        /// Vários objetos (seleção múltipla); `annotation` é o primeiro, para as versões antigas.
        var annotations: [Annotation]?
        var assets: [String: Data]
        var all: [Annotation] { annotations ?? [annotation] }
    }
    private static let clipType = NSPasteboard.PasteboardType("com.capture.annotation")

    func copySelection() {
        if tool == .area, areaSelection != nil { copySelectionPixels(); return }
        let all = selectedAll
        guard let a = all.first else { return }
        var assetData: [String: Data] = [:]
        for x in all { if let name = x.shape.imageAsset, let d = assets.data(named: name) { assetData[name] = d } }
        let pb = NSPasteboard.general
        pb.clearContents()
        if let data = try? JSONEncoder().encode(ClipPayload(annotation: a, annotations: all, assets: assetData)) {
            pb.setData(data, forType: Self.clipType)
        }
        // Para outras apps: o texto do objeto, ou a imagem colada.
        if let s = a.editableString, !s.isEmpty { pb.setString(s, forType: .string) }
        if let name = a.shape.imageAsset, let d = assetData[name] { pb.setData(d, forType: .png) }
    }

    func cutSelection() { copySelection(); deleteSelection() }

    func duplicateSelection() {
        if tool == .area, areaSelection != nil { liftSelection(erase: false); return }
        duplicate(selectedAll, dx: 24, dy: 24)
    }

    var canPaste: Bool {
        let pb = NSPasteboard.general
        return pb.data(forType: Self.clipType) != nil || pb.canReadObject(forClasses: [NSImage.self, NSString.self], options: nil)
    }

    /// Cola o que estiver na área de transferência: objeto copiado na Capture, imagem (de qualquer app,
    /// ficheiro de imagem incluído) ou texto. O resultado fica no centro da zona visível.
    func paste() {
        let pb = NSPasteboard.general
        if let data = pb.data(forType: Self.clipType), let clip = try? JSONDecoder().decode(ClipPayload.self, from: data) {
            pasteAnnotation(clip)
        } else if let png = ClipboardImage.png() {
            pasteImage(png)
        } else if let text = pb.string(forType: .string), !text.isEmpty {
            pasteText(text)
        } else {
            NSSound.beep()
        }
    }

    private func pasteAnnotation(_ clip: ClipPayload) {
        // Imagens: garante o ficheiro neste documento.
        for a in clip.all { if let name = a.shape.imageAsset, !assets.has(name), let d = clip.assets[name] { try? assets.write(d, as: name) } }
        // Colar no mesmo documento: desloca para não ficar escondido por baixo do original.
        let sameDoc = doc.annotations.contains { $0.id == clip.annotation.id }
        let off = sameDoc ? 24.0 : 0.0
        duplicate(clip.all, dx: off, dy: off)
        tool = .select
    }

    /// Ao redimensionar uma imagem colada pelos cantos, manter a proporção (⇧ inverte). Guardado entre sessões.
    var keepObjectAspect: Bool {
        get { (UserDefaults.standard.object(forKey: "imageKeepAspect") as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "imageKeepAspect"); objectWillChange.send() }
    }
    /// Tamanho em píxeis da imagem colada selecionada.
    var selectedImagePixelSize: CGSize? {
        guard let name = selected?.shape.imageAsset, let img = assets.image(named: name) else { return nil }
        return CGSize(width: img.width, height: img.height)
    }
    /// Tamanho da imagem selecionada (mantém o canto superior esquerdo; com «proporção», a outra medida acompanha).
    func setImageObjectSize(width: Double? = nil, height: Double? = nil) {
        guard var a = selected, case let .image(o, w0, h0, asset) = a.shape else { return }
        var w = w0, h = h0
        let ratio = w0 / max(1e-6, h0)
        if let width { w = max(4, width); if keepObjectAspect { h = max(4, w / ratio) } }
        if let height { h = max(4, height); if keepObjectAspect { w = max(4, h * ratio) } }
        a.shape = .image(origin: o, width: w, height: h, asset: asset)
        perform { $0.update(a); _ = $0.expandAreaToFit(ids: [a.id]) }
    }
    /// A imagem selecionada volta ao tamanho real (os píxeis do ficheiro).
    func resetImageObjectSize() {
        guard let px = selectedImagePixelSize, var a = selected, case let .image(o, _, _, asset) = a.shape else { return }
        a.shape = .image(origin: o, width: px.width, height: px.height, asset: asset)
        perform { $0.update(a); _ = $0.expandAreaToFit(ids: [a.id]) }
    }

    func pasteImage(_ png: Data) {
        guard let rep = NSBitmapImageRep(data: png), let name = try? assets.add(png: png) else { NSSound.beep(); return }
        var w = Double(rep.pixelsWide), h = Double(rep.pixelsHigh)
        // Entra ao tamanho real (píxel a píxel: uma captura da mesma zona fica igual à do Toth); só se for maior do que a
        // área é que se reduz, para caber.
        let a = doc.area
        let k = min(1, a.width / w, a.height / h)
        w *= k; h *= k
        let origin = Point(x: visibleCenter.x - w / 2, y: visibleCenter.y - h / 2)
        add(.image(origin: origin, width: w, height: h, asset: name), style: Style(lineVisible: false))
    }

    private func pasteText(_ text: String) {
        let size = fontSize(for: .text)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let longest = Double(lines.map(\.count).max() ?? 1)
        let w = min(480, max(140, longest * size * 0.6 + 2 * Double(RichText.padX)))
        let h = Double(lines.count) * size * 1.3 + 2 * Double(RichText.padY)
        var st = Style(lineVisible: false)
        st.text.size = nil
        add(.textBox(origin: Point(x: visibleCenter.x - w / 2, y: visibleCenter.y - h / 2), width: w, height: h, string: text, fontSize: size), style: st)
    }

    private func add(_ shape: Shape, style: Style) {
        var id: UUID?
        perform {
            id = $0.add(shape, style: style).id
            if let id { _ = $0.expandAreaToFit(ids: [id]) }
        }
        selection = id
        tool = .select
    }

    /// Autoteste do copiar/colar (flag `--paste-selftest`). Repõe a área de transferência no fim.
    func selfTestPaste() -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { fails.append(what) } }
        let pb = NSPasteboard.general
        let saved: [[(NSPasteboard.PasteboardType, Data)]] = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
        }
        defer {
            pb.clearContents()
            let items = saved.map { entries -> NSPasteboardItem in
                let i = NSPasteboardItem(); for (t, d) in entries { i.setData(d, forType: t) }; return i
            }
            if !items.isEmpty { pb.writeObjects(items) }
        }
        let count0 = doc.annotations.count

        // 1) Imagem vinda de fora (PNG na área de transferência)
        let img = NSImage(size: NSSize(width: 50, height: 30), flipped: false) { r in NSColor.green.setFill(); r.fill(); return true }
        guard let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return ["sem PNG de teste"] }
        pb.clearContents(); pb.setData(png, forType: .png)
        paste()
        check(doc.annotations.count == count0 + 1, "imagem não foi colada")
        guard let imgAnn = selected, let name = imgAnn.shape.imageAsset else { return fails + ["imagem sem asset"] }
        check(assets.has(name), "ficheiro da imagem não foi gravado em assets/")
        check(assets.image(named: name) != nil, "imagem colada não carrega")

        // 2) Texto vindo de fora
        pb.clearContents(); pb.setString("texto externo", forType: .string)
        paste()
        check(selected?.editableString == "texto externo", "texto externo não foi colado")

        // 3) Copiar/colar interno (cópia deslocada, novo id) e duplicar
        guard let orig = selected else { return fails + ["sem seleção"] }
        copySelection(); paste()
        check(selected?.id != orig.id && selected?.editableString == "texto externo", "cópia interna falhou")
        check((selected?.shape.bounds.minX ?? 0) == orig.shape.bounds.minX + 24, "cópia não foi deslocada")
        duplicateSelection()
        check(doc.annotations.count == count0 + 4, "duplicar falhou (n=\(doc.annotations.count))")

        // 4) Colar imagem copiada na Capture noutro documento: leva o ficheiro consigo
        selection = imgAnn.id
        copySelection()
        check(pb.data(forType: NSPasteboard.PasteboardType("com.capture.annotation")) != nil, "payload interno em falta")
        // 5) «Copiar tudo» leva a imagem e um ficheiro PNG (para colar no Finder ou anexar)
        copyToPasteboard()
        let fileURL = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first
        check(fileURL?.pathExtension == "png" && (fileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false), "copiar tudo devia pôr um ficheiro PNG na área de transferência (\(String(describing: fileURL)))")
        check(pb.canReadObject(forClasses: [NSImage.self], options: nil), "copiar tudo também leva a imagem")
        undo(); undo(); undo(); undo()   // volta a antes dos testes de colar texto/duplicar
        return fails
    }

    // MARK: Saída

    /// Grava documento + miniatura (+ imagens coladas) de uma vez. O original nunca é reescrito.
    private func save() {
        do {
            try container.write(CapturePackage.documentFile, try CapturePackage.encode(doc))
            if let png = exportPNG(), let preview = Thumbnails.previewPNG(fromPNG: png) {
                try container.write(CapturePackage.previewFile, preview)
            }
            try container.flush()
        } catch { NSLog("Erro ao guardar \(url.path): \(error)") }
        onSaved?()
    }

    func exportPNG() -> Data? { Renderer.png(doc, base: base, assets: assets) }

    /// Copia a imagem final: como imagem (para apps que colam imagens) e como ficheiro PNG (para o Finder, e-mails, chats…).
    func copyToPasteboard() {
        guard let data = exportPNG(), let image = NSImage(data: data) else { return }
        NSPasteboard.general.clearContents()
        var objects: [NSPasteboardWriting] = [image]
        if let file = exportedFile() { objects.append(file as NSURL) }
        NSPasteboard.general.writeObjects(objects)
    }

    /// O PNG final escrito num ficheiro temporário com o nome da captura (para arrastar ou colar como ficheiro).
    func exportedFile() -> URL? {
        guard let png = exportPNG() else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Toth-exportado", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".png")
        do { try png.write(to: file, options: .atomic) } catch { return nil }
        return file
    }

    /// "Salvar como": PNG, JPEG, HEIC ou TIFF (o formato escolhe-se no próprio diálogo).
    func exportToFile() {
        guard let png = exportPNG() else { return }
        let panel = NSSavePanel()
        let picker = FormatPicker(panel: panel, baseName: url.deletingPathExtension().lastPathComponent)
        panel.accessoryView = picker.view
        picker.apply(.png)
        guard panel.runModal() == .OK, var dest = panel.url else { return }
        let format = picker.selected
        if dest.pathExtension.lowercased() != format.ext && !(format == .jpeg && dest.pathExtension.lowercased() == "jpeg")
            && !(format == .tiff && dest.pathExtension.lowercased() == "tiff") {
            dest = dest.deletingPathExtension().appendingPathExtension(format.ext)
        }
        // Em JPEG a transparência passa para a cor de fundo do documento (ou branco).
        let flatten = doc.transparentBackground ? NSColor.white : NSColor(hex: doc.backgroundHex)
        if let data = ImageFiles.encode(png: png, as: format, flattenOn: flatten) { try? data.write(to: dest) }
    }
}

/// Seletor de formato no diálogo "Salvar como".
@MainActor
final class FormatPicker: NSObject {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 36))
    private let popup = NSPopUpButton(frame: NSRect(x: 80, y: 6, width: 160, height: 24), pullsDown: false)
    private weak var panel: NSSavePanel?
    private let baseName: String

    init(panel: NSSavePanel, baseName: String) {
        self.panel = panel
        self.baseName = baseName
        super.init()
        let label = NSTextField(labelWithString: L("Formato:"))
        label.frame = NSRect(x: 8, y: 9, width: 70, height: 18)
        label.alignment = .right
        view.addSubview(label)
        for f in ImageFiles.Format.allCases { popup.addItem(withTitle: f.title) }
        popup.target = self
        popup.action = #selector(changed)
        view.addSubview(popup)
    }

    var selected: ImageFiles.Format { ImageFiles.Format.allCases[max(0, popup.indexOfSelectedItem)] }

    @objc private func changed() { apply(selected) }

    func apply(_ f: ImageFiles.Format) {
        guard let panel else { return }
        popup.selectItem(at: ImageFiles.Format.allCases.firstIndex(of: f) ?? 0)
        panel.allowedContentTypes = [f.type]
        panel.nameFieldStringValue = baseName + "." + f.ext
    }
}
