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
    /// Gesto sobre a imagem original (Tela → Imagem): mover, redimensionar por uma alça, ou rodar.
    private enum ImageDrag { case move, resize(handle: Int, original: Rect, rotation: Double), rotate }
    private var imageDrag: ImageDrag?
    /// A rodar o elemento selecionado pela alça redonda.
    private var rotating = false
    private var gestureMoved = false
    /// Ao redimensionar um objeto com texto, a letra acompanha o tamanho da caixa (a partir destes valores de partida).
    private var resizeStart: (bounds: Rect, font: Double)?
    private var textObserver: NSObjectProtocol?
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
            for h in sel.handlePoints {
                let r = CGRect(x: h.x - side / 2, y: h.y - side / 2, width: side, height: side)
                ctx.setFillColor(NSColor.white.cgColor); ctx.fill(r)
                ctx.setStrokeColor(NSColor.systemBlue.cgColor); ctx.setLineWidth(1.5 / scale); ctx.stroke(r)
            }
            drawRotationHandle(at: rotationHandlePoint(sel), from: sel.toWorld(topCenter(sel.shape.bodyBounds)), color: .systemBlue, ctx)
        }
        if model.tool == .canvas && model.canvasTarget == .image {
            // a imagem original: contorno (rodado), 8 alças e a alça de rotação
            ctx.setStrokeColor(NSColor.systemOrange.cgColor); ctx.setLineWidth(1.5 / scale)
            ctx.addPath(Renderer.rotatedPath(model.imagePlacement.cg, degrees: model.imageRotation)); ctx.strokePath()
            let side = 10 / scale
            for h in imageHandlePoints() {
                let r = CGRect(x: h.x - side / 2, y: h.y - side / 2, width: side, height: side)
                ctx.setFillColor(NSColor.white.cgColor); ctx.fill(r)
                ctx.setStrokeColor(NSColor.systemOrange.cgColor); ctx.setLineWidth(1.5 / scale); ctx.stroke(r)
            }
            drawRotationHandle(at: imageRotationHandlePoint(), from: imageWorld(topCenter(model.imagePlacement)), color: .systemOrange, ctx)
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
            if model.canvasTarget == .area { for h in areaHandles() {
                let r = CGRect(x: h.x - 5, y: h.y - 5, width: 10, height: 10)
                ctx.setFillColor(NSColor.white.cgColor); ctx.fill(r)
                ctx.setStrokeColor(NSColor.systemBlue.cgColor); ctx.setLineWidth(1.5); ctx.stroke(r)
            } }
        }
    }

    // MARK: Rotação (alça redonda acima do objeto, que roda com ele)

    private var rotationHandleGap: Double { 22 / Double(scale) }
    private func topCenter(_ b: Rect) -> Point { Point(x: b.x + b.width / 2, y: b.y) }
    /// Onde está a alça de rotação do elemento (coordenadas do documento).
    func rotationHandlePoint(_ a: Annotation) -> Point {
        let b = a.shape.bodyBounds
        return a.toWorld(Point(x: b.x + b.width / 2, y: b.y - rotationHandleGap))
    }
    private func drawRotationHandle(at p: Point, from base: Point, color: NSColor, _ ctx: CGContext) {
        let r = 5.5 / scale
        ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(1 / scale)
        ctx.move(to: CGPoint(x: base.x, y: base.y)); ctx.addLine(to: CGPoint(x: p.x, y: p.y)); ctx.strokePath()
        let circle = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
        ctx.setFillColor(NSColor.white.cgColor); ctx.fillEllipse(in: circle)
        ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(1.5 / scale); ctx.strokeEllipse(in: circle)
    }
    /// Ângulo para o rato em `p` visto de `center`: a alça fica em cima (−90°) quando a rotação é 0. Sem ⌥, encosta aos
    /// múltiplos de 15° (até 3° de distância).
    private func rotationAngle(center: Point, to p: Point, free: Bool) -> Double {
        let d = Geometry.normalizedDegrees(Geometry.degrees(from: center, to: p) + 90)
        if free { return d }
        let snapped = (d / 15).rounded() * 15
        return abs(d - snapped) <= 3 ? Geometry.normalizedDegrees(snapped) : d
    }

    // MARK: Imagem original (Tela → Imagem)

    private func imageWorld(_ p: Point) -> Point {
        let r = model.imagePlacement
        return Geometry.rotate(p, around: Point(x: r.x + r.width / 2, y: r.y + r.height / 2), degrees: model.imageRotation)
    }
    private func imageLocal(_ p: Point, placement r: Rect, rotation: Double) -> Point {
        Geometry.rotate(p, around: Point(x: r.x + r.width / 2, y: r.y + r.height / 2), degrees: -rotation)
    }
    private static func eightHandles(_ r: Rect) -> [Point] {
        [Point(x: r.minX, y: r.minY), Point(x: r.minX + r.width / 2, y: r.minY), Point(x: r.maxX, y: r.minY),
         Point(x: r.maxX, y: r.minY + r.height / 2), Point(x: r.maxX, y: r.maxY), Point(x: r.minX + r.width / 2, y: r.maxY),
         Point(x: r.minX, y: r.maxY), Point(x: r.minX, y: r.minY + r.height / 2)]
    }
    /// 8 alças da imagem no documento (já rodadas): tl, t, tr, r, br, b, bl, l.
    func imageHandlePoints() -> [Point] { Self.eightHandles(model.imagePlacement).map(imageWorld) }
    func imageRotationHandlePoint() -> Point { let r = model.imagePlacement; return imageWorld(Point(x: r.x + r.width / 2, y: r.y - rotationHandleGap)) }
    private func imageHandle(at p: Point) -> Int? {
        let t = 9 / Double(scale)
        return imageHandlePoints().firstIndex { abs($0.x - p.x) <= t && abs($0.y - p.y) <= t }
    }
    private func hitsImage(_ p: Point) -> Bool {
        model.imagePlacement.contains(imageLocal(p, placement: model.imagePlacement, rotation: model.imageRotation))
    }
    private func near(_ a: Point, _ b: Point) -> Bool { let t = 8 / Double(scale); return abs(a.x - b.x) <= t && abs(a.y - b.y) <= t }

    /// Enquadramento depois de arrastar a alça `h` até `p` (ambos no referencial da imagem, sem rotação). Nos cantos mantém
    /// a proporção se `keepAspect`; nos lados muda só uma medida. O lado/canto oposto fica fixo.
    private func resizedImage(_ r: Rect, handle h: Int, to p: Point, keepAspect: Bool) -> Rect {
        var x0 = r.minX, y0 = r.minY, x1 = r.maxX, y1 = r.maxY
        let isCorner = [0, 2, 4, 6].contains(h)
        if isCorner && keepAspect {
            let ratio = r.width / max(1, r.height)
            let fx = [0, 6].contains(h) ? x1 : x0, fy = [0, 2].contains(h) ? y1 : y0     // canto fixo
            // o tamanho segue a projeção do rato na diagonal (como nas apps de desenho): o canto acompanha o rato ao longo dela
            let sx: Double = [0, 6].contains(h) ? -1 : 1, sy: Double = [0, 2].contains(h) ? -1 : 1
            let k = ((p.x - fx) * sx * r.width + (p.y - fy) * sy * r.height) / max(1, r.width * r.width + r.height * r.height)
            let w2 = max(8, k * r.width), h2 = max(8, w2 / ratio)
            if [0, 6].contains(h) { x0 = fx - w2 } else { x1 = fx + w2 }
            if [0, 2].contains(h) { y0 = fy - h2 } else { y1 = fy + h2 }
            return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        }
        if [0, 6, 7].contains(h) { x0 = min(p.x, x1 - 8) }
        if [2, 3, 4].contains(h) { x1 = max(p.x, x0 + 8) }
        if [0, 1, 2].contains(h) { y0 = min(p.y, y1 - 8) }
        if [4, 5, 6].contains(h) { y1 = max(p.y, y0 + 8) }
        return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Aplica o arrasto da alça `h` da imagem até ao ponto `p` do documento, mantendo fixo no documento o lado/canto oposto.
    private func dragImageHandle(_ h: Int, original r: Rect, rotation: Double, to p: Point, keepAspect: Bool) {
        let local = imageLocal(p, placement: r, rotation: rotation)
        var next = resizedImage(r, handle: h, to: local, keepAspect: keepAspect)
        if rotation != 0 {
            let fixed = Self.eightHandles(r)[(h + 4) % 8]
            let before = Geometry.rotate(fixed, around: Point(x: r.x + r.width / 2, y: r.y + r.height / 2), degrees: rotation)
            let fixedNow = Self.eightHandles(next)[(h + 4) % 8]
            let after = Geometry.rotate(fixedNow, around: Point(x: next.x + next.width / 2, y: next.y + next.height / 2), degrees: rotation)
            next = Rect(x: next.x + before.x - after.x, y: next.y + before.y - after.y, width: next.width, height: next.height)
        }
        let old = origin
        model.setImageFrameLive(next, rotation: rotation)
        keepOrigin(old)
        areaChangedInGesture = true
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
        imageDrag = nil; rotating = false; gestureMoved = false
        fitAtGestureStart = false; areaChangedInGesture = false
        let tol = 6 / Double(scale)

        switch model.tool {
        case .select:
            if let id = model.selection, let a = model.doc.annotations.first(where: { $0.id == id }) {
                if near(p, rotationHandlePoint(a)) { model.checkpoint(); rotating = true; return }
                if let h = a.handle(at: p, tolerance: 8 / Double(scale)) {
                    model.checkpoint(); resizing = h
                    resizeStart = a.effectiveFontSize.map { (a.shape.bodyBounds, $0) }
                    return
                }
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
            let vp = convert(event.locationInWindow, from: nil)
            if model.canvasTarget == .image {
                if near(p, imageRotationHandlePoint()) { model.checkpoint(); freezeViewIfFit(); imageDrag = .rotate; return }
                if let h = imageHandle(at: p) { model.checkpoint(); freezeViewIfFit(); imageDrag = .resize(handle: h, original: model.imagePlacement, rotation: model.imageRotation); return }
                if hitsImage(p) { model.checkpoint(); freezeViewIfFit(); imageDrag = .move; return }
                if viewRect(area).insetBy(dx: -9, dy: -9).contains(vp) { model.canvasTarget = .area; needsDisplay = true; return }
                model.tool = .select; return   // clique fora da área = confirma
            }
            if let h = areaHandle(at: vp) {
                model.checkpoint(); freezeViewIfFit()
                areaDrag = (h, model.doc.area)
            } else if hitsImage(p) {
                // clicar na imagem passa a editá-la (e já dá para a arrastar)
                model.canvasTarget = .image; model.checkpoint(); freezeViewIfFit(); imageDrag = .move
            } else if !viewRect(area).insetBy(dx: -9, dy: -9).contains(vp) {
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
        if let start = dragStart, hypot((p.x - start.x) * Double(scale), (p.y - start.y) * Double(scale)) >= 3 { gestureMoved = true }
        if let drag = imageDrag {
            let free = event.modifierFlags.contains(.option)
            switch drag {
            case .move:
                if let last = lastPoint {
                    let r = model.imagePlacement, old = origin
                    model.setImageFrameLive(Rect(x: r.x + p.x - last.x, y: r.y + p.y - last.y, width: r.width, height: r.height), rotation: model.imageRotation)
                    keepOrigin(old); areaChangedInGesture = true
                }
            case let .resize(h, original, rotation):
                let keep = model.keepImageAspect != event.modifierFlags.contains(.shift)
                dragImageHandle(h, original: original, rotation: rotation, to: p, keepAspect: keep)
            case .rotate:
                let r = model.imagePlacement, old = origin
                model.setImageFrameLive(r, rotation: rotationAngle(center: Point(x: r.x + r.width / 2, y: r.y + r.height / 2), to: p, free: free))
                keepOrigin(old); areaChangedInGesture = true
            }
            lastPoint = p
            return
        }
        if rotating, let id = model.selection {
            let free = event.modifierFlags.contains(.option)
            update(id) { $0.rotation = rotationAngle(center: $0.shape.rotationCenter, to: p, free: free) }
            expandAreaIfNeeded(for: id)
            lastPoint = p
            return
        }
        if let drag = areaDrag {
            let old = origin
            model.setAreaLive(resizedArea(drag.original, handle: drag.handle, to: p))
            keepOrigin(old)
            areaChangedInGesture = true
            return   // a vista não muda de ponto de referência: não é preciso atualizar lastPoint
        }
        if let h = resizing, let id = model.selection {
            update(id) {
                $0 = $0.movingHandle(h, to: p)
                // a letra cresce e encolhe com a caixa (média geométrica das duas escalas)
                if let start = resizeStart, start.bounds.width > 0, start.bounds.height > 0 {
                    let b = $0.shape.bodyBounds
                    let k = ((b.width / start.bounds.width) * (b.height / start.bounds.height)).squareRoot()
                    $0.setEffectiveFontSize(min(max(start.font * k, 4), 400))
                }
            }
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
        defer { creating = nil; moving = false; dragStart = nil; resizing = nil; areaDrag = nil; imageDrag = nil; rotating = false; resizeStart = nil }
        if imageDrag != nil {
            if gestureMoved { model.commit() } else { model.dropLastCheckpoint() }   // só clicar na imagem não altera nada
            endGesture(); return
        }
        if rotating { model.commit(); endGesture(); return }
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
        if !isNew { model.checkpoint() }   // texto e tamanho da caixa mudam juntos; um só ponto de undo

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
        textObserver = NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: view, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitBoxToText() }
        }
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
        view.frameCenterRotation = 0
        view.frame = rect
        view.frameCenterRotation = CGFloat(a.rotation)    // roda com o objeto (mesmo sentido que o desenho)
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

    /// Enquanto se escreve, a caixa ajusta-se ao texto: a altura acompanha-o (caixa de texto e balão crescem e encolhem,
    /// até ao mínimo; retângulo e elipse só crescem). A largura não muda, para o texto continuar a quebrar onde o utilizador quis.
    private func fitBoxToText() {
        guard let view = editor, let id = editingID, var a = model.doc.annotations.first(where: { $0.id == id }),
              let lm = view.layoutManager as? MarkerLayoutManager, let container = view.textContainer else { return }
        let needed = Double(RichText.textHeight(lm, container) / scale) + 2 * Double(RichText.padY)
        let b = a.shape.bodyBounds
        let minimum = max(48, (a.effectiveFontSize ?? 20) * 2.2)
        let target: Double
        switch a.shape {
        case .textBox, .callout: target = max(minimum, needed.rounded(.up))
        case .rect: target = max(b.height, needed.rounded(.up))
        case .ellipse: target = max(b.height, (needed / (1 - 2 * 0.146)).rounded(.up))   // o texto vive no retângulo inscrito
        default: return
        }
        guard abs(target - b.height) >= 0.5 else { return }
        a.shape = a.shape.withBodyHeight(target)
        model.mutate { $0.update(a); _ = $0.expandAreaToFit(ids: [id]) }
        refreshEditor()
    }

    /// Fecha o editor e grava o texto (cada edição é um ponto de undo, que inclui o ajuste da caixa).
    private func finishEditing() {
        guard let view = editor, let id = editingID else { return }
        let text = view.string
        let isNew = editingIsNew, original = originalString
        view.onFinish = nil
        if let o = textObserver { NotificationCenter.default.removeObserver(o); textObserver = nil }
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
        } else if var a = model.doc.annotations.first(where: { $0.id == id }) {
            let boxChanged = a.shape != model.undoShape(of: id)
            if text != original || boxChanged {
                a.setEditableString(text)
                model.mutate { $0.update(a) }
                model.commit()
            } else { model.dropLastCheckpoint() }
        }
        needsDisplay = true
        window?.makeFirstResponder(self)
    }

    /// Abre o editor no elemento selecionado e deixa-o aberto (flag `--edit-hold`, para captura de ecrã).
    func debugHoldEditing() { if let id = model.selection { beginEditing(id, isNew: false) } }

    /// Autoteste: a caixa ajusta-se ao texto enquanto se escreve, e a letra acompanha o redimensionar.
    func selfTestTextFit() -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { fails.append(what) } }
        // 1) balão: escrever 6 linhas faz a caixa crescer; apagar faz encolher (até ao mínimo)
        let id = model.addAnnotation(.callout(origin: Point(x: 100, y: 100), width: 220, height: 50, tail: Point(x: 60, y: 300), string: "", fontSize: 24))
        model.tool = .select; model.selection = id
        let h0 = model.selected?.shape.bodyBounds.height ?? 0
        beginEditing(id, isNew: false)
        editor?.insertText("um\ndois\ntrês\nquatro\ncinco\nseis", replacementRange: NSRange(location: 0, length: 0))
        let hTyping = model.selected?.shape.bodyBounds.height ?? 0
        check(hTyping > h0 + 100, "a caixa devia crescer enquanto se escreve (\(h0) → \(hTyping))")
        check(model.selected?.shape.bodyBounds.width == 220, "a largura não devia mudar")
        editor?.insertText("", replacementRange: NSRange(location: 0, length: editor?.string.utf16.count ?? 0))
        editor?.insertText("só uma", replacementRange: NSRange(location: 0, length: 0))
        let hShort = model.selected?.shape.bodyBounds.height ?? 0
        check(hShort < hTyping && hShort >= 48, "ao apagar a caixa devia encolher (\(hTyping) → \(hShort))")
        finishEditing()
        check(model.selected?.editableString == "só uma", "texto gravado")
        model.undo()
        check(model.selected?.shape.bodyBounds.height == h0 && model.selected?.editableString == "", "desfazer devia repor o texto e o tamanho (\(model.selected?.shape.bodyBounds.height ?? -1))")
        model.redo()
        // 2) retângulo com texto: só cresce
        let rid = model.addAnnotation(.rect(origin: Point(x: 400, y: 100), width: 200, height: 120))
        model.selection = rid
        beginEditing(rid, isNew: false)
        editor?.insertText("a", replacementRange: NSRange(location: 0, length: 0))
        check(model.selected?.shape.bounds.height == 120, "com pouco texto o retângulo não encolhe")
        editor?.insertText("\n1\n2\n3\n4\n5\n6\n7", replacementRange: NSRange(location: 1, length: 0))
        check((model.selected?.shape.bounds.height ?? 0) > 120, "com muito texto o retângulo cresce")
        finishEditing()
        // 3) redimensionar pela alça: a letra acompanha (maior e menor)
        model.selection = id
        guard let a = model.selected, let f0 = a.effectiveFontSize else { return fails + ["sem balão"] }
        let br = a.handlePoints[2]
        debugMouse(at: br, dragTo: Point(x: br.x + a.shape.bodyBounds.width, y: br.y + a.shape.bodyBounds.height))   // o dobro
        let f1 = model.selected?.effectiveFontSize ?? 0
        check(abs(f1 - f0 * 2) < 0.5, "ao duplicar a caixa a letra devia duplicar (\(f0) → \(f1))")
        let b2 = model.selected!.handlePoints[2]
        debugMouse(at: b2, dragTo: Point(x: b2.x - model.selected!.shape.bodyBounds.width * 0.75, y: b2.y - model.selected!.shape.bodyBounds.height * 0.75))
        let f2 = model.selected?.effectiveFontSize ?? 0
        check(abs(f2 - f0 * 0.5) < 0.5, "ao reduzir a um quarto a letra devia ficar a metade (\(f0) → \(f2))")
        model.setFontSize(300)
        check(model.selected?.effectiveFontSize == 300, "a letra pode passar dos 120")
        model.undo(); model.undo(); model.undo()
        check(model.selected?.effectiveFontSize == f0, "desfazer repõe a letra (\(model.selected?.effectiveFontSize ?? -1))")
        return fails
    }

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
    func debugMouse(at p: Point, dragTo: Point? = nil, option: Bool = false, shift: Bool = false) {
        var flags: NSEvent.ModifierFlags = []
        if option { flags.insert(.option) }
        if shift { flags.insert(.shift) }
        func event(_ type: NSEvent.EventType, _ pt: Point) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: debugWindowPoint(pt), modifierFlags: flags,
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
