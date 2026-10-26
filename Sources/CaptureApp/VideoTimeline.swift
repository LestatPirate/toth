// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit
import CaptureCore
import SwiftUI

/// A linha de tempo do vídeo (tempo do vídeo original): miniaturas, régua, trecho marcado, trechos já cortados e a posição
/// de reprodução. Arrastar na faixa marca um trecho; arrastar as pegas ajusta-o; clicar põe a reprodução nesse ponto;
/// clicar na régua e arrastar anda pelo vídeo; clique duplo num trecho cortado repõe-no.
final class TimelineNSView: NSView {
    weak var model: VideoEditorModel?
    var onRestoreCut: ((Int) -> Void)?
    var onCut: (() -> Void)?
    var onTogglePlay: (() -> Void)?

    private let margin: CGFloat = 14, rulerHeight: CGFloat = 20, handleWidth: CGFloat = 9
    private enum Drag { case none, scrub, selecting(anchor: Double), start, end }
    private var drag = Drag.none
    private var pressPoint: NSPoint = .zero
    private var moved = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Geometria

    private var duration: Double { max(model?.duration ?? 0, 0.001) }
    private var trackWidth: CGFloat { max(1, bounds.width - 2 * margin) }
    var strip: NSRect { NSRect(x: margin, y: rulerHeight, width: trackWidth, height: max(10, bounds.height - rulerHeight - 6)) }
    func x(_ t: Double) -> CGFloat { margin + CGFloat(t / duration) * trackWidth }
    func time(_ x: CGFloat) -> Double { max(0, min(duration, Double((x - margin) / trackWidth) * duration)) }

    // MARK: Desenho

    override func draw(_ dirtyRect: NSRect) {
        guard let model, let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor(white: 0.13, alpha: 1).setFill(); bounds.fill()
        let s = strip

        // miniaturas
        ctx.saveGState(); NSBezierPath(roundedRect: s, xRadius: 5, yRadius: 5).addClip()
        NSColor(white: 0.2, alpha: 1).setFill(); s.fill()
        if !model.thumbnails.isEmpty {
            let w = s.width / CGFloat(model.thumbnails.count)
            for (i, img) in model.thumbnails.enumerated() {
                let r = NSRect(x: s.minX + CGFloat(i) * w, y: s.minY, width: w + 0.5, height: s.height)
                let ar = img.size.width / max(1, img.size.height)
                var src = NSRect(origin: .zero, size: img.size)
                if r.width / r.height < ar { let sw = img.size.height * (r.width / r.height); src = NSRect(x: (img.size.width - sw) / 2, y: 0, width: sw, height: img.size.height) }
                img.draw(in: r, from: src, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        // trechos cortados: escurecidos e riscados
        for c in model.cuts.cuts {
            let r = NSRect(x: x(c.start), y: s.minY, width: max(2, x(c.end) - x(c.start)), height: s.height)
            NSColor.black.withAlphaComponent(0.72).setFill(); r.fill()
            ctx.saveGState(); NSBezierPath(rect: r).addClip()
            NSColor.white.withAlphaComponent(0.16).setStroke()
            var hx = r.minX - r.height
            while hx < r.maxX { let p = NSBezierPath(); p.move(to: NSPoint(x: hx, y: r.maxY)); p.line(to: NSPoint(x: hx + r.height, y: r.minY)); p.lineWidth = 1; p.stroke(); hx += 7 }
            ctx.restoreGState()
            NSColor.systemOrange.setStroke()
            for edge in [r.minX, r.maxX] { let p = NSBezierPath(); p.move(to: NSPoint(x: edge, y: s.minY)); p.line(to: NSPoint(x: edge, y: s.maxY)); p.lineWidth = 1.5; p.stroke() }
            if r.width > 26, let img = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil) {
                let cfg = img.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold).applying(.init(paletteColors: [.systemOrange])))
                cfg?.draw(in: NSRect(x: r.midX - 8, y: r.midY - 8, width: 16, height: 16))
            }
        }
        ctx.restoreGState()
        NSColor.white.withAlphaComponent(0.25).setStroke()
        let border = NSBezierPath(roundedRect: s.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5); border.lineWidth = 1; border.stroke()

        // trecho marcado
        if let sel = model.selection {
            let r = NSRect(x: x(sel.start), y: s.minY, width: max(2, x(sel.end) - x(sel.start)), height: s.height)
            NSColor.controlAccentColor.withAlphaComponent(0.28).setFill(); r.fill()
            NSColor.controlAccentColor.setStroke()
            let b = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1)); b.lineWidth = 2; b.stroke()
            for (edge, left) in [(r.minX, true), (r.maxX, false)] {
                let h = NSRect(x: left ? edge - handleWidth / 2 : edge - handleWidth / 2, y: s.minY - 2, width: handleWidth, height: s.height + 4)
                NSColor.controlAccentColor.setFill(); NSBezierPath(roundedRect: h, xRadius: 3, yRadius: 3).fill()
                NSColor.white.setFill(); NSBezierPath(roundedRect: NSRect(x: h.midX - 0.75, y: h.midY - 8, width: 1.5, height: 16), xRadius: 0.75, yRadius: 0.75).fill()
            }
            let label = String(format: L("%@ selecionados"), Self.format(sel.length)) as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white]
            let sz = label.size(withAttributes: attrs)
            if r.width > sz.width + 16 {
                let pill = NSRect(x: r.midX - sz.width / 2 - 6, y: s.maxY - sz.height - 8, width: sz.width + 12, height: sz.height + 4)
                NSColor.black.withAlphaComponent(0.6).setFill(); NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
                label.draw(at: NSPoint(x: pill.minX + 6, y: pill.minY + 2), withAttributes: attrs)
            }
        }

        drawRuler()

        // posição de reprodução
        let px = x(model.playhead)
        NSColor.systemRed.setStroke()
        let line = NSBezierPath(); line.move(to: NSPoint(x: px, y: 4)); line.line(to: NSPoint(x: px, y: bounds.height - 2)); line.lineWidth = 2; line.stroke()
        NSColor.systemRed.setFill()
        let tri = NSBezierPath(); tri.move(to: NSPoint(x: px - 5, y: 2)); tri.line(to: NSPoint(x: px + 5, y: 2)); tri.line(to: NSPoint(x: px, y: 11)); tri.close(); tri.fill()
    }

    private func drawRuler() {
        let d = duration
        let steps: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800]
        let step = steps.first { CGFloat($0 / d) * trackWidth >= 56 } ?? 3600
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular), .foregroundColor: NSColor(white: 0.7, alpha: 1)]
        var t = 0.0
        NSColor(white: 0.45, alpha: 1).setStroke()
        while t <= d + 1e-9 {
            let px = x(t)
            let p = NSBezierPath(); p.move(to: NSPoint(x: px, y: rulerHeight - 6)); p.line(to: NSPoint(x: px, y: rulerHeight - 1)); p.lineWidth = 1; p.stroke()
            (Self.format(t, tenths: step < 1) as NSString).draw(at: NSPoint(x: px + 3, y: 3), withAttributes: attrs)
            t += step
        }
    }

    static func format(_ seconds: Double, tenths: Bool = true) -> String {
        let s = max(0, seconds)
        let m = Int(s) / 60, sec = s - Double(m * 60)
        if s >= 3600 { return String(format: "%d:%02d:%02d", Int(s) / 3600, (Int(s) / 60) % 60, Int(s) % 60) }
        return tenths ? String(format: "%d:%04.1f", m, sec) : String(format: "%d:%02d", m, Int(sec))
    }

    // MARK: Rato

    private func hitHandle(_ p: NSPoint) -> Drag? {
        guard let sel = model?.selection, strip.insetBy(dx: -8, dy: -4).contains(p) else { return nil }
        if abs(p.x - x(sel.start)) <= handleWidth { return .start }
        if abs(p.x - x(sel.end)) <= handleWidth { return .end }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        pressPoint = p; moved = false
        guard let model else { return }
        if event.clickCount == 2, let i = model.cuts.cutIndex(at: time(p.x)), strip.contains(p) { onRestoreCut?(i); drag = .none; return }
        if let h = hitHandle(p) { drag = h; return }
        if p.y < rulerHeight { drag = .scrub; model.seek(toSource: time(p.x)); return }
        drag = strip.contains(p) ? .selecting(anchor: time(p.x)) : .none
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model else { return }
        let p = convert(event.locationInWindow, from: nil)
        if abs(p.x - pressPoint.x) > 3 { moved = true }
        let t = time(p.x)
        switch drag {
        case .scrub: model.seek(toSource: t)
        case let .selecting(anchor): if moved { model.selection = TimeSpan(start: min(anchor, t), end: max(anchor, t)) }
        case .start: if let e = model.selection?.end { model.selection = TimeSpan(start: min(t, e), end: e) }
        case .end: if let s = model.selection?.start { model.selection = TimeSpan(start: s, end: max(t, s)) }
        case .none: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let model else { return }
        let p = convert(event.locationInWindow, from: nil)
        if case .selecting = drag, !moved { model.selection = nil; model.seek(toSource: time(p.x)) }   // clique simples: põe a reprodução aí
        if let sel = model.selection, sel.length < 0.05 { model.selection = nil }
        drag = .none
    }

    override func resetCursorRects() {
        guard let sel = model?.selection else { return }
        for t in [sel.start, sel.end] { addCursorRect(NSRect(x: x(t) - handleWidth, y: strip.minY, width: 2 * handleWidth, height: strip.height), cursor: .resizeLeftRight) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        guard let model, strip.contains(p), let i = model.cuts.cutIndex(at: time(p.x)) else { return nil }
        let m = NSMenu()
        let item = NSMenuItem(title: L("Repor este trecho"), action: #selector(restoreFromMenu(_:)), keyEquivalent: "")
        item.target = self; item.tag = i
        m.addItem(item)
        return m
    }
    @objc private func restoreFromMenu(_ item: NSMenuItem) { onRestoreCut?(item.tag) }

    // MARK: Teclado

    override func keyDown(with event: NSEvent) {
        guard let model else { return }
        switch event.charactersIgnoringModifiers {
        case " ": onTogglePlay?()
        case "\u{7F}", "\u{F728}": onCut?()                                   // Delete / Delete para a frente
        case "i", "I": model.markStart()
        case "o", "O": model.markEnd()
        case "\u{1B}": model.selection = nil
        case String(UnicodeScalar(NSLeftArrowFunctionKey)!): model.step(event.modifierFlags.contains(.shift) ? -5 : -1.0 / 30)
        case String(UnicodeScalar(NSRightArrowFunctionKey)!): model.step(event.modifierFlags.contains(.shift) ? 5 : 1.0 / 30)
        default: super.keyDown(with: event)
        }
    }
}

struct VideoTimeline: NSViewRepresentable {
    @ObservedObject var model: VideoEditorModel

    func makeNSView(context: Context) -> TimelineNSView {
        let v = TimelineNSView()
        v.model = model
        v.onRestoreCut = { i in Task { await model.restoreCut(at: i) } }
        v.onCut = { Task { await model.cutSelection() } }
        v.onTogglePlay = { model.togglePlay() }
        return v
    }

    func updateNSView(_ v: TimelineNSView, context: Context) {
        v.model = model
        v.needsDisplay = true
        v.window?.invalidateCursorRects(for: v)
    }
}
