// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit
import Combine
import SwiftUI
import CaptureCore

struct CanvasRepresentable: NSViewRepresentable {
    let model: EditorModel
    func makeNSView(context: Context) -> CanvasView { CanvasView(model: model) }
    func updateNSView(_ view: CanvasView, context: Context) { view.needsDisplay = true }
}

/// Editor de texto em linha, posicionado sobre o objeto.
final class InlineTextView: NSTextView {
    var onFinish: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        if event.keyCode == 53 || (cmd && event.keyCode == 36) { onFinish?(); return }  // Esc ou ⌘↩ terminam
        super.keyDown(with: event)
    }
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { DispatchQueue.main.async { [weak self] in self?.onFinish?() } }
        return ok
    }
}

final class CanvasView: NSView {
    /// Canvas em uso (para o autoteste).
    nonisolated(unsafe) static weak var current: CanvasView?
    private let model: EditorModel
    private var bag = Set<AnyCancellable>()
    private var dragStart: Point?
    private var creating: UUID?
    private var moving = false
    private var resizing: Int?
    private var lastPoint: Point?
    private var areaDrag: (handle: Int, original: Rect)?
    /// Objeto existente sob o rato quando se começou a desenhar: se for só um clique (sem arrastar), seleciona-se esse objeto.
    private var clickCandidate: UUID?

    // Edição de texto em linha
    private var editor: InlineTextView?
    private var editingID: UUID?
    private var editingIsNew = false
    private var originalString = ""

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        CanvasView.current = self
        clipsToBounds = true   // desde o macOS 14 as vistas já não recortam por omissão: sem isto a imagem desenhava-se fora da vista
        model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.needsDisplay = true
                if let id = self.editingID {
                    if self.model.selection != id { self.finishEditing() } else { self.refreshEditor() }
                }
            }
        }.store(in: &bag)
    }
    required init?(coder: NSCoder) { fatalError() }

    // A área de trabalho é ajustada à vista, centrada (ou com zoom/deslocamento).
    private var area: CGRect { model.doc.area.cg }
    private var fit: CGFloat {
        let f = min((bounds.width - 40) / max(area.width, 1), (bounds.height - 40) / max(area.height, 1), 1)
        return max(f, 0.01)
    }
    private var scale: CGFloat { model.zoom.map { CGFloat($0) } ?? fit }
    /// Posição na vista do ponto (0,0) do documento (o canto da imagem original).
    private var origin: CGPoint {
        CGPoint(x: (bounds.width - area.width * scale) / 2 - area.minX * scale + model.pan.width,
                y: (bounds.height - area.height * scale) / 2 - area.minY * scale + model.pan.height)
    }
    private func imagePoint(_ e: NSEvent) -> Point {
        let p = convert(e.locationInWindow, from: nil)
        return Point(x: Double((p.x - origin.x) / scale), y: Double((p.y - origin.y) / scale))
    }
    private func viewRect(_ r: CGRect) -> CGRect {
        CGRect(x: origin.x + r.minX * scale, y: origin.y + r.minY * scale, width: r.width * scale, height: r.height * scale)
    }

    override func layout() {
        super.layout()
        if editingID != nil { refreshEditor() }
    }

    override func draw(_ dirtyRect: NSRect) {
        model.fitScale = Double(fit)
        model.visibleCenter = Point(x: Double((bounds.midX - origin.x) / scale), y: Double((bounds.midY - origin.y) / scale))
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clip(to: bounds)
        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.scaleBy(x: scale, y: scale)
        ctx.interpolationQuality = .high
        if model.doc.transparentBackground { drawChecker(ctx) }
        Renderer.draw(model.doc, base: model.base, in: ctx, selected: model.selection, editing: editingID, assets: model.assets)
        if editingID == nil, let sel = model.doc.annotations.first(where: { $0.id == model.selection }) {
            let side = 9 / scale
            for h in sel.shape.handles {
                let r = CGRect(x: h.x - side / 2, y: h.y - side / 2, width: side, height: side)
                ctx.setFillColor(NSColor.white.cgColor); ctx.fill(r)
                ctx.setStrokeColor(NSColor.systemBlue.cgColor); ctx.setLineWidth(1.5 / scale); ctx.stroke(r)
            }
        }
        ctx.restoreGState()

        // Fora da área de trabalho: escurecido (o que fica de fora não será exportado).
        let areaView = viewRect(area)
        if model.doc.area != model.doc.imageRect || model.tool == .canvas {
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.4).cgColor)
            ctx.addRect(bounds); ctx.addRect(areaView)
            ctx.fillPath(using: .evenOdd)
        }
        if model.tool == .canvas {
            ctx.setStrokeColor(NSColor.systemBlue.cgColor); ctx.setLineWidth(1.5); ctx.stroke(areaView)
            for h in areaHandles() {
                let r = CGRect(x: h.x - 5, y: h.y - 5, width: 10, height: 10)
                ctx.setFillColor(NSColor.white.cgColor); ctx.fill(r)
                ctx.setStrokeColor(NSColor.systemBlue.cgColor); ctx.setLineWidth(1.5); ctx.stroke(r)
            }
        }
    }

    /// Xadrez para fundo transparente (só na vista; a exportação fica realmente transparente).
    private func drawChecker(_ ctx: CGContext) {
        let tile = 10 / scale
        let visible = CGRect(x: -origin.x / scale, y: -origin.y / scale, width: bounds.width / scale, height: bounds.height / scale)
        let r = area.intersection(visible)
        guard !r.isNull, r.width > 0, r.height > 0 else { return }
        ctx.saveGState()
        ctx.setFillColor(NSColor(white: 0.95, alpha: 1).cgColor); ctx.fill(r)
        ctx.setFillColor(NSColor(white: 0.82, alpha: 1).cgColor)
        let i0 = Int(floor(r.minX / tile)), i1 = Int(ceil(r.maxX / tile))
        let j0 = Int(floor(r.minY / tile)), j1 = Int(ceil(r.maxY / tile))
        for i in i0..<i1 { for j in j0..<j1 where (i + j) & 1 == 1 {
            ctx.fill(CGRect(x: CGFloat(i) * tile, y: CGFloat(j) * tile, width: tile, height: tile).intersection(r))
        } }
        ctx.restoreGState()
    }

    // MARK: Área de trabalho (alças)

    /// 8 alças em coordenadas da vista: tl, t, tr, r, br, b, bl, l.
    private func areaHandles() -> [CGPoint] {
        let r = viewRect(area)
        return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY),
                CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
    }

    private func areaHandle(at viewPoint: CGPoint) -> Int? {
        areaHandles().firstIndex { abs($0.x - viewPoint.x) <= 9 && abs($0.y - viewPoint.y) <= 9 }
    }

    /// Rectângulo da área depois de arrastar a alça `h` até `p` (coordenadas do documento).
    private func resizedArea(_ r: Rect, handle h: Int, to p: Point) -> Rect {
        var x0 = r.minX, y0 = r.minY, x1 = r.maxX, y1 = r.maxY
        if [0, 6, 7].contains(h) { x0 = min(p.x, x1 - 8) }
        if [2, 3, 4].contains(h) { x1 = max(p.x, x0 + 8) }
        if [0, 1, 2].contains(h) { y0 = min(p.y, y1 - 8) }
        if [4, 5, 6].contains(h) { y1 = max(p.y, y0 + 8) }
        return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    // Durante um gesto que muda a área, a vista fica "congelada" (zoom fixo e canto da imagem no mesmo
    // sítio) para o rato não "fugir"; no fim volta a ajustar-se, se estava em "ajustar".
    private var fitAtGestureStart = false
    private var areaChangedInGesture = false

    private func freezeViewIfFit() {
        if model.zoom == nil { fitAtGestureStart = true; model.zoom = Double(scale) }
    }

    private func keepOrigin(_ old: CGPoint) {
        let now = origin
        model.pan = CGSize(width: model.pan.width + old.x - now.x, height: model.pan.height + old.y - now.y)
    }

    /// Expande a área (se ligada) para conter o objeto; mantém a vista estável.
    private func expandAreaIfNeeded(for id: UUID) {
        var probe = model.doc
        guard probe.expandAreaToFit(ids: [id]) else { return }
        freezeViewIfFit()
        let old = origin
        model.expandAreaIfNeeded(for: id)
        keepOrigin(old)
        areaChangedInGesture = true
    }

    private func endGesture() {
        if areaChangedInGesture && fitAtGestureStart { model.zoomFit() }
        fitAtGestureStart = false; areaChangedInGesture = false
    }

    // MARK: Rato

    override func mouseDown(with event: NSEvent) {
        if editor != nil { finishEditing() }
        window?.makeFirstResponder(self)
        let p = imagePoint(event)
        dragStart = p; lastPoint = p; creating = nil; moving = false; resizing = nil; areaDrag = nil; clickCandidate = nil
        fitAtGestureStart = false; areaChangedInGesture = false
        let tol = 6 / Double(scale)

        switch model.tool {
        case .select:
            if let id = model.selection, let a = model.doc.annotations.first(where: { $0.id == id }),
               let h = a.shape.handle(at: p, tolerance: 8 / Double(scale)) {
                model.checkpoint(); resizing = h
                return
            }
            let hit = model.doc.topmost(at: p, tolerance: tol)
            model.selection = hit?.id
            if let hit, event.clickCount == 2, hit.editableString != nil {
                beginEditing(hit.id, isNew: false)
                return
            }
            if hit != nil { model.checkpoint(); moving = true }
        case .step:
            // Clique sobre um objeto existente seleciona-o (⌥ + clique força a criação de uma etapa por cima dele).
            if !event.modifierFlags.contains(.option), let hit = model.doc.topmost(at: p, tolerance: tol) {
                selectExisting(hit.id)
            } else {
                model.addStep(at: p)
            }
        case .canvas:
            if let h = areaHandle(at: convert(event.locationInWindow, from: nil)) {
                model.checkpoint(); freezeViewIfFit()
                areaDrag = (h, model.doc.area)
            } else if !viewRect(area).insetBy(dx: -9, dy: -9).contains(convert(event.locationInWindow, from: nil)) {
                model.tool = .select   // clique fora da área = confirma
            }
        default:
            if !event.modifierFlags.contains(.option) { clickCandidate = model.doc.topmost(at: p, tolerance: tol)?.id }
            model.checkpoint()
            let id = UUID()
            let style = model.style   // o último estilo usado nesta ferramenta
            let a = Annotation(id: id, z: (model.doc.annotations.map(\.z).max() ?? -1) + 1,
                               shape: shape(model.tool, from: p, to: p), style: style)
            model.mutate { $0.insert(a) }
            model.selection = id
            creating = id
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = imagePoint(event)
        if let drag = areaDrag {
            let old = origin
            model.setAreaLive(resizedArea(drag.original, handle: drag.handle, to: p))
            keepOrigin(old)
            areaChangedInGesture = true
            return   // a vista não muda de ponto de referência: não é preciso atualizar lastPoint
        }
        if let h = resizing, let id = model.selection {
            update(id) { $0.shape = $0.shape.movingHandle(h, to: p) }
            expandAreaIfNeeded(for: id)
        } else if let id = creating, let start = dragStart {
            update(id) { $0.shape = shape(model.tool, from: start, to: p) }
            expandAreaIfNeeded(for: id)
        } else if moving, let id = model.selection, let last = lastPoint {
            update(id) { $0.shape = $0.shape.translated(dx: p.x - last.x, dy: p.y - last.y) }
            expandAreaIfNeeded(for: id)
        }
        lastPoint = imagePoint(event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { creating = nil; moving = false; dragStart = nil; resizing = nil; areaDrag = nil }
        if areaDrag != nil { model.commit(); endGesture(); return }
        if resizing != nil { model.commit(); model.rememberStepSize(); endGesture(); return }
        if let id = creating {
            let tiny = model.doc.annotations.first(where: { $0.id == id }).map { $0.shape.bounds.width < 8 && $0.shape.bounds.height < 8 } ?? true
            // "Clique" = o rato quase não andou (medido no ecrã, não no tamanho do objeto: o balão tem sempre o ponteiro).
            let clickOnly = dragStart.flatMap { start in lastPoint.map { hypot(($0.x - start.x) * Double(scale), ($0.y - start.y) * Double(scale)) < 4 } } ?? tiny
            if clickOnly, let existing = clickCandidate {
                // Foi um clique (não um arrasto) sobre um objeto que já existia: descarta o objeto novo e seleciona o existente.
                model.mutate { $0.remove(id: id) }
                model.dropLastCheckpoint()
                selectExisting(existing)
                endGesture()
                return
            }
            if model.tool == .text || model.tool == .callout {
                // Clique sem arrastar cria uma caixa de tamanho padrão; depois edita-se o texto no próprio objeto.
                if let start = dragStart {
                    if model.tool == .callout { if clickOnly { update(id) { $0.shape = calloutPlaced(tail: start, near: nil) } } }
                    else if tiny { update(id) { $0.shape = defaultBox(model.tool, at: start) } }
                }
                beginEditing(id, isNew: true)
                return
            }
            if tiny {   // clique sem arrastar não cria nada
                model.mutate { $0.remove(id: id) }
                model.dropLastCheckpoint()
                model.selection = nil
            } else { model.commit() }
            endGesture()
        } else if moving { model.commit(); endGesture() }
    }

    /// Seleciona um objeto que já existia e passa para a ferramenta Mover: o painel e as opções passam a ser os desse objeto.
    private func selectExisting(_ id: UUID) {
        model.selection = id
        model.tool = .select
    }

    private func update(_ id: UUID, _ f: (inout Annotation) -> Void) {
        guard var a = model.doc.annotations.first(where: { $0.id == id }) else { return }
        f(&a)
        model.mutate { $0.update(a) }
    }

    private func shape(_ tool: Tool, from a: Point, to b: Point) -> CaptureCore.Shape {
        let o = Point(x: min(a.x, b.x), y: min(a.y, b.y))
        let w = abs(a.x - b.x), h = abs(a.y - b.y)
        switch tool {
        case .line: return .line(from: a, to: b)
        case .rect: return .rect(origin: o, width: w, height: h)
        case .ellipse: return .ellipse(origin: o, width: w, height: h)
        case .highlight: return .highlight(origin: o, width: w, height: h)
        case .blur: return .blur(origin: o, width: w, height: h, radius: model.defaultPixelSize)
        case .gaussian: return .gaussian(origin: o, width: w, height: h, intensity: model.defaultBlurIntensity)
        case .text: return .textBox(origin: o, width: w, height: h, string: "", fontSize: model.defaultFontSize)
        case .callout: return calloutPlaced(tail: a, near: b)
        default: return .arrow(from: a, to: b)
        }
    }

    /// O ponto do clique é a ponta do balão; o balão (tamanho padrão) vem depois: acompanha o rato durante o
    /// arrasto, e num simples clique fica por cima da ponta (ou por baixo, se não couber).
    private func calloutPlaced(tail: Point, near: Point?) -> CaptureCore.Shape {
        let w = 220.0, h = max(48, model.defaultFontSize * 2.2)
        var o: Point
        if let b = near, hypot((b.x - tail.x) * Double(scale), (b.y - tail.y) * Double(scale)) >= 4 {
            o = Point(x: b.x - w / 2, y: b.y - h / 2)
        } else {
            let above = tail.y - 44 - h
            o = Point(x: tail.x - w * 0.25, y: above >= 0 ? above : tail.y + 44)
        }
        return .callout(origin: o, width: w, height: h, tail: tail, string: "", fontSize: model.defaultFontSize)
    }

    private func defaultBox(_ tool: Tool, at p: Point) -> CaptureCore.Shape {
        let h = max(48, model.defaultFontSize * 2.2)
        return .textBox(origin: p, width: 240, height: h, string: "", fontSize: model.defaultFontSize)
    }

    // MARK: Edição de texto no objeto

    private func beginEditing(_ id: UUID, isNew: Bool) {
        finishEditing()
        guard var a = model.doc.annotations.first(where: { $0.id == id }) else { return }
        // Texto antigo (sem caixa): converte-se em caixa de texto ao editar.
        if case let .text(o, s, f) = a.shape {
            let b = a.shape.bounds
            model.checkpoint()
            a.shape = .textBox(origin: o, width: max(b.width + 24, 160), height: b.height + 16, string: s, fontSize: f)
            if a.style.text.colorHex == nil { a.style.text.colorHex = a.style.colorHex }
            a.style.lineVisible = false
            model.mutate { $0.update(a) }
            model.commit()
        }
        guard Renderer.textArea(a) != nil else { return }

        let storage = NSTextStorage()
        let lm = MarkerLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        lm.addTextContainer(container)
        storage.addLayoutManager(lm)
        let view = InlineTextView(frame: .zero, textContainer: container)
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.textContainerInset = NSSize.zero
        view.onFinish = { [weak self] in self?.finishEditing() }
        view.string = a.editableString ?? ""
        addSubview(view)
        editor = view
        editingID = id
        editingIsNew = isNew
        originalString = a.editableString ?? ""
        needsDisplay = true
        refreshEditor()
        window?.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
    }

    /// Reposiciona o editor e aplica fonte/alinhamento/lista atuais.
    private func refreshEditor() {
        guard let view = editor, let id = editingID,
              let a = model.doc.annotations.first(where: { $0.id == id }),
              let box = Renderer.textArea(a), let size = a.effectiveFontSize,
              let lm = view.layoutManager as? MarkerLayoutManager, let container = view.textContainer else { return }
        let f = a.style.text
        let s = CGFloat(size) * scale
        let color = RichText.textColor(a.style)
        let attrs = RichText.attributes(f, size: s, color: color)
        RichText.configure(lm, f, size: s, color: color)

        let rect = viewRect(box)
        view.frame = rect
        container.size = CGSize(width: rect.width, height: CGFloat.greatestFiniteMagnitude)
        view.typingAttributes = attrs
        view.insertionPointColor = color
        if let storage = view.textStorage {
            storage.setAttributes(attrs, range: NSRange(location: 0, length: storage.length))
        }
        let h = RichText.textHeight(lm, container)
        view.textContainerInset = NSSize(width: 0, height: RichText.verticalOffset(f.vAlign, free: rect.height - h))
        view.needsDisplay = true
    }

    /// Fecha o editor e grava o texto (cada edição é um ponto de undo).
    private func finishEditing() {
        guard let view = editor, let id = editingID else { return }
        let text = view.string
        let isNew = editingIsNew, original = originalString
        view.onFinish = nil
        editor = nil; editingID = nil
        view.removeFromSuperview()

        if isNew {
            if text.isEmpty && !(model.doc.annotations.first { $0.id == id }?.shape.isCallout ?? false) {
                model.mutate { $0.remove(id: id) }
                model.dropLastCheckpoint()
                model.selection = nil
            } else if var a = model.doc.annotations.first(where: { $0.id == id }) {
                a.setEditableString(text)
                model.mutate { $0.update(a) }
                model.commit()
            }
        } else if text != original {
            model.updateString(id: id, to: text)
        }
        needsDisplay = true
        window?.makeFirstResponder(self)
    }

    /// Abre o editor no elemento selecionado e deixa-o aberto (flag `--edit-hold`, para captura de ecrã).
    func debugHoldEditing() { if let id = model.selection { beginEditing(id, isNew: false) } }

    /// Autoteste do editor em linha (flag `--edit-selftest`): devolve uma descrição das falhas, vazia se tudo bem.
    func selfTestEditing() -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { fails.append(what) } }
        guard let id = model.selection, let a = model.selected, let before = a.editableString else { return ["sem seleção de texto"] }

        beginEditing(id, isNew: false)
        check(editor != nil, "editor não abriu")
        editor?.insertText("+X", replacementRange: NSRange(location: (editor?.string.utf16.count ?? 0), length: 0))
        finishEditing()
        check(editor == nil, "editor não fechou")
        check(model.selected?.editableString == before + "+X", "texto editado não gravado: \(model.selected?.editableString ?? "nil")")
        model.undo()
        check(model.selected?.editableString == before, "undo não repôs o texto")

        // Novo objeto: com texto fica; vazio desaparece.
        let count = model.doc.annotations.count
        let n1 = model.addAnnotation(.textBox(origin: Point(x: 5, y: 5), width: 120, height: 40, string: "", fontSize: 20))
        beginEditing(n1, isNew: true); editor?.insertText("novo", replacementRange: NSRange(location: 0, length: 0)); finishEditing()
        check(model.doc.annotations.count == count + 1 && model.doc.annotations.first { $0.id == n1 }?.shape.string == "novo", "novo texto não ficou")
        model.checkpoint()
        var empty = Annotation(z: 99, shape: .textBox(origin: Point(x: 5, y: 60), width: 120, height: 40, string: "", fontSize: 20))
        empty.id = UUID()
        model.mutate { $0.insert(empty) }
        beginEditing(empty.id, isNew: true); finishEditing()
        check(!model.doc.annotations.contains { $0.id == empty.id }, "texto vazio não foi removido")
        return fails
    }

    // MARK: Zoom e deslocamento

    override func scrollWheel(with event: NSEvent) {
        guard model.zoom != nil else { return }   // em "ajustar" não há o que deslocar
        model.pan = CGSize(width: model.pan.width + event.scrollingDeltaX, height: model.pan.height + event.scrollingDeltaY)
    }

    override func magnify(with event: NSEvent) {
        let cur = model.zoom ?? model.fitScale
        model.zoom = max(0.05, min(8, cur * (1 + Double(event.magnification))))
    }

    // MARK: Ações do menu Editar (chegam aqui quando o editor é a primeira resposta)

    @objc func undo(_ sender: Any?) { model.undo() }
    @objc func redo(_ sender: Any?) { model.redo() }
    @objc func cut(_ sender: Any?) { model.cutSelection() }
    @objc func copy(_ sender: Any?) { if model.selection != nil { model.copySelection() } else { model.copyToPasteboard() } }
    @objc func paste(_ sender: Any?) { model.paste() }
    @objc func duplicate(_ sender: Any?) { model.duplicateSelection() }

    // MARK: Autoteste do rato (eventos entregues diretamente ao editor)

    /// Ponto da imagem -> ponto na janela.
    func debugWindowPoint(_ p: Point) -> NSPoint {
        convert(CGPoint(x: origin.x + CGFloat(p.x) * scale, y: origin.y + CGFloat(p.y) * scale), to: nil)
    }

    /// Clique (ou arrasto, se `to` existir) entregue ao editor como se fosse o rato.
    func debugMouse(at p: Point, dragTo: Point? = nil, option: Bool = false) {
        func event(_ type: NSEvent.EventType, _ pt: Point) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: debugWindowPoint(pt), modifierFlags: option ? [.option] : [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)
        }
        if let e = event(.leftMouseDown, p) { mouseDown(with: e) }
        if let to = dragTo {
            if let e = event(.leftMouseDragged, Point(x: (p.x + to.x) / 2, y: (p.y + to.y) / 2)) { mouseDragged(with: e) }
            if let e = event(.leftMouseDragged, to) { mouseDragged(with: e) }
            if let e = event(.leftMouseUp, to) { mouseUp(with: e) }
        } else if let e = event(.leftMouseUp, p) { mouseUp(with: e) }
    }

    // MARK: Teclado

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: model.deleteSelection()   // Delete / Forward delete
        case 53: model.selection = nil          // Esc
        case 36:                                // Return: confirma a área (Tela) ou edita o texto do elemento selecionado
            if model.tool == .canvas { model.tool = .select }
            else if let id = model.selection, model.selected?.editableString != nil { beginEditing(id, isNew: false) }
        default: super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        if editor != nil { return super.performKeyEquivalent(with: event) }  // dentro do texto valem os atalhos do texto
        let shift = event.modifierFlags.contains(.shift)
        switch key {
        case "z": if shift { model.redo() } else { model.undo() }
        case "c": if model.selection != nil { model.copySelection() } else { model.copyToPasteboard() }
        case "x": model.cutSelection()
        case "v": model.paste()
        case "d": model.duplicateSelection()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}
