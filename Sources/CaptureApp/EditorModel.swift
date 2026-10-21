// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit
import CaptureCore

enum Tool: String, CaseIterable, Identifiable {
    case select, arrow, line, text, callout, rect, ellipse, step, highlight, blur, gaussian, canvas
    var id: String { rawValue }
    var title: String {
        switch self {
        case .select: L("Mover"); case .arrow: L("Seta"); case .line: L("Linha"); case .callout: L("Balão"); case .rect: L("Retângulo")
        case .ellipse: L("Elipse"); case .text: L("Texto"); case .step: L("Etapa"); case .highlight: L("Marcador"); case .blur: L("Pixelização"); case .gaussian: L("Blur"); case .canvas: L("Tela")
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
        }
    }
}

@MainActor
final class EditorModel: ObservableObject {
    @Published private(set) var doc: CaptureDocument
    @Published var tool: Tool = .arrow
    @Published var selection: UUID?
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
    /// Centro da zona visível, em coordenadas do documento (atualizado pelo canvas; usado ao colar).
    var visibleCenter = Point(x: 0, y: 0)
    let assets: AssetStore
    private let container: CaptureContainer
    var onSaved: (() -> Void)?
    let url: URL
    let base: CGImage
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

    /// Altera sem criar ponto de undo (usar entre checkpoint() e commit()).
    func mutate(_ f: (inout CaptureDocument) -> Void) { f(&doc) }

    func commit() { save() }

    func perform(_ f: (inout CaptureDocument) -> Void) { checkpoint(); f(&doc); save() }

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
    func zoomActual() { zoom = 1 }

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
        mutate { $0.workArea = rr == $0.imageRect ? nil : WorkArea(rr) }
    }

    /// Tamanho exato (mantém o canto superior esquerdo).
    func setAreaSize(width: Double, height: Double) {
        let a = doc.area
        perform { $0.workArea = nil; $0.workArea = WorkArea(Rect(x: a.x, y: a.y, width: max(8, width.rounded()), height: max(8, height.rounded()))) }
    }

    func resetArea() { perform { $0.workArea = nil } }
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
        guard let id = selection else { return }
        perform { $0.remove(id: id) }
        selection = nil
    }

    func setStyle(_ s: Style) {
        // O estilo vira o padrão da ferramenta que cria este tipo de elemento (a do elemento selecionado, ou a atual).
        let target = selected.flatMap { Tool.forShape($0.shape) } ?? tool
        if target != .select { ToolDefaults.shared.setStyle(s, for: target) }
        objectWillChange.send()
        guard let id = selection, var a = doc.annotations.first(where: { $0.id == id }) else { return }
        a.style = s
        perform { $0.update(a) }
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
        if let s = selection, !doc.annotations.contains(where: { $0.id == s }) { selection = nil }
    }

    // MARK: Copiar e colar

    /// Conteúdo copiado dentro da Capture: o objeto e, se for uma imagem, o próprio ficheiro
    /// (para poder colar noutro documento).
    private struct ClipPayload: Codable {
        var annotation: Annotation
        var assets: [String: Data]
    }
    private static let clipType = NSPasteboard.PasteboardType("com.capture.annotation")

    func copySelection() {
        guard let a = selected else { return }
        var assetData: [String: Data] = [:]
        if let name = a.shape.imageAsset, let d = assets.data(named: name) { assetData[name] = d }
        let pb = NSPasteboard.general
        pb.clearContents()
        if let data = try? JSONEncoder().encode(ClipPayload(annotation: a, assets: assetData)) {
            pb.setData(data, forType: Self.clipType)
        }
        // Para outras apps: o texto do objeto, ou a imagem colada.
        if let s = a.editableString, !s.isEmpty { pb.setString(s, forType: .string) }
        if let name = a.shape.imageAsset, let d = assetData[name] { pb.setData(d, forType: .png) }
    }

    func cutSelection() { copySelection(); deleteSelection() }

    func duplicateSelection() {
        guard let a = selected else { return }
        var id: UUID?
        perform { id = $0.insertCopy(of: a, dx: 24, dy: 24).id; if let id { _ = $0.expandAreaToFit(ids: [id]) } }
        selection = id
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
        if let name = clip.annotation.shape.imageAsset, !assets.has(name), let d = clip.assets[name] {
            try? assets.write(d, as: name)
        }
        // Colar no mesmo documento: desloca para não ficar escondido por baixo do original.
        let sameDoc = doc.annotations.contains { $0.id == clip.annotation.id }
        let off = sameDoc ? 24.0 : 0.0
        var id: UUID?
        perform {
            id = $0.insertCopy(of: clip.annotation, dx: off, dy: off).id
            if let id { _ = $0.expandAreaToFit(ids: [id]) }
        }
        selection = id
        tool = .select
    }

    func pasteImage(_ png: Data) {
        guard let rep = NSBitmapImageRep(data: png), let name = try? assets.add(png: png) else { NSSound.beep(); return }
        var w = Double(rep.pixelsWide), h = Double(rep.pixelsHigh)
        // Imagens grandes entram a, no máximo, 70% da área visível.
        let a = doc.area
        let k = min(1, a.width * 0.7 / w, a.height * 0.7 / h)
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

    func copyToPasteboard() {
        guard let data = exportPNG(), let image = NSImage(data: data) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
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
