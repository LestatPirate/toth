// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit
import CaptureCore
import Combine
import SwiftUI

/// A «Tela» do vídeo: por cima do leitor, o contorno do vídeo na saída com 8 alças (redimensionar: cantos em proporção,
/// ⇧ inverte; lados mudam só uma medida) e a alça redonda de rotação (encosta aos 15°; ⌥ liberta). O vídeo fica sempre
/// centrado na saída, por isso o tamanho mede-se a partir do centro. Durante o gesto só as alças seguem o rato; o vídeo
/// refaz-se ao largar.
final class VideoFrameOverlayView: NSView {
    weak var model: VideoEditorModel? { didSet { observe() } }
    private var bag = Set<AnyCancellable>()
    private enum Drag { case resize(handle: Int, size: CGSize), rotate }
    private var drag: Drag?
    private var moved = false

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func observe() {
        bag.removeAll()
        model?.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.needsDisplay = true } }.store(in: &bag)
    }

    // MARK: Geometria (a saída é desenhada ajustada e centrada na vista, como o leitor faz)

    /// Margem à volta do vídeo (o leitor fica recuado o mesmo), para haver espaço para as alças e para a rotação.
    static let inset: CGFloat = 70
    private var canvas: CGSize { model?.canvasSize ?? CGSize(width: 16, height: 16) }
    private var area: CGRect { bounds.insetBy(dx: Self.inset, dy: Self.inset) }
    private var scale: CGFloat { min(max(1, area.width) / max(1, canvas.width), max(1, area.height) / max(1, canvas.height)) }
    private var displayOrigin: CGPoint { CGPoint(x: area.minX + (area.width - canvas.width * scale) / 2, y: area.minY + (area.height - canvas.height * scale) / 2) }
    /// Da saída (píxeis do ficheiro) para a vista, e o contrário.
    func viewPoint(_ p: Point) -> CGPoint { CGPoint(x: displayOrigin.x + CGFloat(p.x) * scale, y: displayOrigin.y + CGFloat(p.y) * scale) }
    func canvasPoint(_ v: CGPoint) -> Point { Point(x: Double((v.x - displayOrigin.x) / scale), y: Double((v.y - displayOrigin.y) / scale)) }
    private var center: Point { Point(x: Double(canvas.width) / 2, y: Double(canvas.height) / 2) }
    /// O vídeo (sem rodar) centrado na saída.
    private var videoFrame: Rect {
        let s = model?.effectiveOutputSize ?? .zero
        return Rect(x: center.x - Double(s.width) / 2, y: center.y - Double(s.height) / 2, width: Double(s.width), height: Double(s.height))
    }
    private var rotation: Double { model?.outputRotation ?? 0 }
    private func world(_ p: Point) -> Point { Geometry.rotate(p, around: center, degrees: rotation) }
    private func local(_ p: Point) -> Point { Geometry.rotate(p, around: center, degrees: -rotation) }
    private static func eight(_ r: Rect) -> [Point] {
        [Point(x: r.minX, y: r.minY), Point(x: r.minX + r.width / 2, y: r.minY), Point(x: r.maxX, y: r.minY),
         Point(x: r.maxX, y: r.minY + r.height / 2), Point(x: r.maxX, y: r.maxY), Point(x: r.minX + r.width / 2, y: r.maxY),
         Point(x: r.minX, y: r.maxY), Point(x: r.minX, y: r.minY + r.height / 2)]
    }
    /// Alças (na saída, já rodadas): tl, t, tr, r, br, b, bl, l.
    func handlePoints() -> [Point] { Self.eight(videoFrame).map(world) }
    func rotationHandlePoint() -> Point { let f = videoFrame; return world(Point(x: f.x + f.width / 2, y: f.y - 26 / Double(scale))) }

    // MARK: Desenho

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, model != nil else { return }
        let color = NSColor.systemOrange
        // contorno do vídeo rodado
        let corners = [Point(x: videoFrame.minX, y: videoFrame.minY), Point(x: videoFrame.maxX, y: videoFrame.minY), Point(x: videoFrame.maxX, y: videoFrame.maxY), Point(x: videoFrame.minX, y: videoFrame.maxY)].map { viewPoint(world($0)) }
        ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(1.5)
        ctx.move(to: corners[0]); for c in corners.dropFirst() { ctx.addLine(to: c) }; ctx.closePath(); ctx.strokePath()
        // a saída (caixa envolvente), a tracejado
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.6).cgColor); ctx.setLineWidth(1); ctx.setLineDash(phase: 0, lengths: [5, 3])
        ctx.stroke(CGRect(origin: displayOrigin, size: CGSize(width: canvas.width * scale, height: canvas.height * scale)))
        ctx.setLineDash(phase: 0, lengths: [])
        for h in handlePoints() {
            let v = viewPoint(h), r = CGRect(x: v.x - 5, y: v.y - 5, width: 10, height: 10)
            ctx.setFillColor(NSColor.white.cgColor); ctx.fill(r)
            ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(1.5); ctx.stroke(r)
        }
        let base = viewPoint(world(Point(x: videoFrame.x + videoFrame.width / 2, y: videoFrame.y))), rh = viewPoint(rotationHandlePoint())
        ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(1); ctx.move(to: base); ctx.addLine(to: rh); ctx.strokePath()
        let circle = CGRect(x: rh.x - 6, y: rh.y - 6, width: 12, height: 12)
        ctx.setFillColor(NSColor.white.cgColor); ctx.fillEllipse(in: circle)
        ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(1.5); ctx.strokeEllipse(in: circle)
        // tamanho da saída
        let label = "\(Int(canvas.width)) × \(Int(canvas.height))" + (rotation != 0 ? " · \(Int(rotation.rounded()))°" : "") as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white]
        let sz = label.size(withAttributes: attrs)
        let pill = CGRect(x: displayOrigin.x + 8, y: displayOrigin.y + canvas.height * scale - sz.height - 12, width: sz.width + 12, height: sz.height + 4)
        NSColor.black.withAlphaComponent(0.65).setFill(); NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
        label.draw(at: CGPoint(x: pill.minX + 6, y: pill.minY + 2), withAttributes: attrs)
    }

    // MARK: Rato

    private func nearView(_ p: CGPoint, _ q: Point) -> Bool { let v = viewPoint(q); return abs(v.x - p.x) <= 9 && abs(v.y - p.y) <= 9 }

    override func mouseDown(with event: NSEvent) {
        guard let model else { return }
        let v = convert(event.locationInWindow, from: nil)
        moved = false; drag = nil
        if nearView(v, rotationHandlePoint()) { drag = .rotate; return }
        if let h = handlePoints().firstIndex(where: { nearView(v, $0) }) { drag = .resize(handle: h, size: model.effectiveOutputSize); return }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model, let drag else { return }
        moved = true
        let p = canvasPoint(convert(event.locationInWindow, from: nil))
        switch drag {
        case .rotate:
            var d = Geometry.normalizedDegrees(Geometry.degrees(from: center, to: p) + 90)
            if !event.modifierFlags.contains(.option) { let s = (d / 15).rounded() * 15; if abs(d - s) <= 3 { d = Geometry.normalizedDegrees(s) } }
            model.setOutputTransformLive(size: model.effectiveOutputSize, rotation: d)
        case let .resize(h, start):
            // o vídeo está centrado: a medida é o dobro da distância ao centro, no referencial sem rodar
            let q = local(p)
            let dx = abs(q.x - center.x) * 2, dy = abs(q.y - center.y) * 2
            let keep = model.outputKeepAspect != event.modifierFlags.contains(.shift)
            var w = Double(start.width), hh = Double(start.height)
            switch h {
            case 1, 5: hh = dy
            case 3, 7: w = dx
            default:
                if keep {
                    let k = (dx * Double(start.width) + dy * Double(start.height)) / max(1, Double(start.width * start.width + start.height * start.height))
                    w = max(16, k * Double(start.width)); hh = w * Double(start.height) / max(1, Double(start.width))
                } else { w = dx; hh = dy }
            }
            model.setOutputTransformLive(size: CGSize(width: max(16, w), height: max(16, hh)), rotation: model.outputRotation)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let model else { return }
        if drag != nil, moved { Task { await model.commitOutputTransform() } }
        drag = nil
    }
}

struct VideoFrameOverlay: NSViewRepresentable {
    @ObservedObject var model: VideoEditorModel
    func makeNSView(context: Context) -> VideoFrameOverlayView { let v = VideoFrameOverlayView(); v.model = model; return v }
    func updateNSView(_ v: VideoFrameOverlayView, context: Context) { v.model = model; v.needsDisplay = true }
}
