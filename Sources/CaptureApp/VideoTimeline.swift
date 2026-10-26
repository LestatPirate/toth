// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit
import CaptureCore
import SwiftUI

/// A linha de tempo do vídeo: uma linha por faixa (vídeo, áudio do sistema, microfone), simples (sem fotogramas: o ponto
/// exato vê-se no leitor). Mostra os clipes, os espaços (sem vídeo / sem som), a onda do áudio, o trecho marcado e a
/// posição de reprodução. A caixa de cada cabeçalho escolhe em que linhas o corte, a cópia e a inversão se aplicam.
///
/// Rato: arrastar marca um trecho (e o leitor mostra o ponto exato da ponta que se move); arrastar uma ponta ajusta-a;
/// clicar vai para o ponto; arrastar na régua anda pelo vídeo; clique duplo num espaço marca-o inteiro.
/// Teclas: espaço, Delete (cortar e juntar), ⇧Delete (cortar deixando espaço), I/O, Tab (outra ponta), setas, ⌘C, ⌘V, ⌥⌘V, Esc.
final class TimelineNSView: NSView {
    weak var model: VideoEditorModel?
    var onAction: ((Action) -> Void)?
    enum Action { case cutJoin, cutGap, copy, paste, pasteOver, reverse, togglePlay }

    let headerWidth: CGFloat = 158, margin: CGFloat = 14, rulerHeight: CGFloat = 22, handleWidth: CGFloat = 9
    private enum Drag {
        case none, scrub, selecting(anchor: Double), start, end
        var isStart: Bool { if case .start = self { true } else { false } }
    }
    private var drag = Drag.none
    private var pressPoint: NSPoint = .zero
    private var moved = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Geometria

    private var lanes: [EditTrack] { model?.timeline.tracks ?? [] }
    private var duration: Double { max(model?.duration ?? 0, 0.001) }
    var trackLeft: CGFloat { headerWidth + margin }
    var trackWidth: CGFloat { max(1, bounds.width - trackLeft - margin) }
    func x(_ t: Double) -> CGFloat { trackLeft + CGFloat(t / duration) * trackWidth }
    func time(_ x: CGFloat) -> Double { max(0, min(duration, Double((x - trackLeft) / trackWidth) * duration)) }
    private func rowHeight(_ t: EditTrack) -> CGFloat { t == .video ? 38 : 50 }
    /// Retângulo da linha `t` (na zona das faixas).
    func rowRect(_ t: EditTrack) -> NSRect {
        var y = rulerHeight + 4
        for l in lanes { if l == t { break }; y += rowHeight(l) + 4 }
        return NSRect(x: trackLeft, y: y, width: trackWidth, height: rowHeight(t))
    }
    var tracksArea: NSRect {
        let last = lanes.last.map { rowRect($0).maxY } ?? rulerHeight + 4
        return NSRect(x: trackLeft, y: rulerHeight + 4, width: trackWidth, height: max(1, last - rulerHeight - 4))
    }
    static func idealHeight(lanes: Int) -> CGFloat { 22 + 4 + 38 + CGFloat(max(0, lanes - 1)) * 54 + 12 }

    func title(_ t: EditTrack) -> String {
        switch t {
        case .video: L("Vídeo")
        case .system: (model?.singleAudio ?? false) ? L("Áudio") : L("Áudio do sistema")
        case .microphone: L("Microfone")
        }
    }
    private func symbol(_ t: EditTrack) -> String { t == .video ? "film" : (t == .system ? "speaker.wave.2.fill" : "mic.fill") }
    private func color(_ t: EditTrack) -> NSColor { t == .video ? NSColor(calibratedRed: 0.25, green: 0.42, blue: 0.85, alpha: 1) : (t == .system ? NSColor(calibratedRed: 0.18, green: 0.62, blue: 0.5, alpha: 1) : NSColor(calibratedRed: 0.8, green: 0.5, blue: 0.2, alpha: 1)) }

    // MARK: Desenho

    override func draw(_ dirtyRect: NSRect) {
        guard let model, let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor(white: 0.12, alpha: 1).setFill(); bounds.fill()
        drawRuler()
        for lane in lanes {
            let r = rowRect(lane)
            let active = model.mask.contains(lane)
            drawHeader(lane, row: r, active: active)
            // fundo da linha
            NSColor(white: 0.19, alpha: 1).setFill()
            NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
            ctx.saveGState(); NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).addClip()
            // espaços: sem vídeo (preto) ou sem som
            for g in model.timeline.gaps(lane) { drawGap(g, in: r, lane: lane) }
            for c in model.timeline.clips(lane) { drawClip(c, lane: lane, row: r, model: model, dimmed: !active) }
            ctx.restoreGState()
            NSColor.white.withAlphaComponent(active ? 0.22 : 0.1).setStroke()
            let b = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5); b.lineWidth = 1; b.stroke()
        }
        drawSelection(model)
        // posição de reprodução
        let px = x(model.playhead)
        NSColor.systemRed.setStroke()
        let line = NSBezierPath(); line.move(to: NSPoint(x: px, y: 6)); line.line(to: NSPoint(x: px, y: bounds.height - 2)); line.lineWidth = 2; line.stroke()
        NSColor.systemRed.setFill()
        let tri = NSBezierPath(); tri.move(to: NSPoint(x: px - 5, y: 3)); tri.line(to: NSPoint(x: px + 5, y: 3)); tri.line(to: NSPoint(x: px, y: 12)); tri.close(); tri.fill()
    }

    private func drawHeader(_ lane: EditTrack, row: NSRect, active: Bool) {
        let box = NSRect(x: 8, y: row.midY - 9, width: 18, height: 18)
        let sym = NSImage(systemSymbolName: active ? "checkmark.square.fill" : "square", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular).applying(.init(paletteColors: active ? [NSColor.white, NSColor.controlAccentColor] : [NSColor(white: 0.55, alpha: 1)])))
        sym?.draw(in: box)
        let icon = NSImage(systemSymbolName: symbol(lane), accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold).applying(.init(paletteColors: [color(lane)])))
        icon?.draw(in: NSRect(x: 32, y: row.midY - 8, width: 16, height: 16))
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor(white: active ? 0.9 : 0.55, alpha: 1)]
        (title(lane) as NSString).draw(in: NSRect(x: 52, y: row.midY - 7, width: headerWidth - 54, height: 14), withAttributes: attrs)
    }

    private func drawGap(_ g: TimeSpan, in row: NSRect, lane: EditTrack) {
        let r = NSRect(x: x(g.start), y: row.minY, width: max(2, x(g.end) - x(g.start)), height: row.height)
        (lane == .video ? NSColor.black : NSColor(white: 0.1, alpha: 1)).setFill(); r.fill()
        NSColor.white.withAlphaComponent(0.12).setStroke()
        var hx = r.minX - r.height
        while hx < r.maxX { let p = NSBezierPath(); p.move(to: NSPoint(x: hx, y: r.maxY)); p.line(to: NSPoint(x: hx + r.height, y: r.minY)); p.lineWidth = 1; p.stroke(); hx += 8 }
        if r.width > 70 {
            let text = (lane == .video ? L("sem vídeo") : L("sem som")) as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor(white: 0.6, alpha: 1)]
            let sz = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2), withAttributes: attrs)
        }
    }

    private func drawClip(_ c: Clip, lane: EditTrack, row: NSRect, model: VideoEditorModel, dimmed: Bool) {
        let r = NSRect(x: x(c.at), y: row.minY + 1, width: max(2, x(c.end) - x(c.at)), height: row.height - 2)
        let base = color(lane)
        let reversed = c.media != 0
        (reversed ? base.blended(withFraction: 0.35, of: NSColor.systemPurple) ?? base : base).withAlphaComponent(dimmed ? 0.4 : (lane == .video ? 0.9 : 0.5)).setFill()
        NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
        if lane != .video, let peaks = model.peaks[TrackKey(media: c.media, lane: lane)], !peaks.isEmpty {
            let mid = r.midY, half = (r.height - 6) / 2
            NSColor.white.withAlphaComponent(dimmed ? 0.35 : 0.85).setFill()
            var px = r.minX
            while px < r.maxX {
                let t0 = c.src.start + Double((px - r.minX) / r.width) * c.length
                let t1 = c.src.start + Double((px + 1.5 - r.minX) / r.width) * c.length
                let i0 = max(0, Int(t0 * Waveform.perSecond)), i1 = min(peaks.count, max(i0 + 1, Int(t1 * Waveform.perSecond) + 1))
                if i0 < i1 {
                    let v = CGFloat(min(1, (peaks[i0..<i1].max() ?? 0) * 1.6))
                    NSBezierPath(rect: NSRect(x: px, y: mid - max(0.5, v * half), width: 1, height: max(1, v * half * 2))).fill()
                }
                px += 1.5
            }
        }
        if reversed, r.width > 24, let img = NSImage(systemSymbolName: "backward.fill", accessibilityDescription: nil) {
            img.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .bold).applying(.init(paletteColors: [.white])))?.draw(in: NSRect(x: r.minX + 5, y: r.minY + 4, width: 12, height: 10))
        }
    }

    private func drawSelection(_ model: VideoEditorModel) {
        guard let sel = model.selection else { return }
        let area = tracksArea
        let r = NSRect(x: x(sel.start), y: area.minY - 2, width: max(2, x(sel.end) - x(sel.start)), height: area.height + 4)
        NSColor.controlAccentColor.withAlphaComponent(0.22).setFill(); r.fill()
        NSColor.controlAccentColor.setStroke()
        let b = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1)); b.lineWidth = 1.5; b.stroke()
        for (edge, which) in [(r.minX, VideoEditorModel.Edge.start), (r.maxX, .end)] {
            let h = NSRect(x: edge - handleWidth / 2, y: r.minY, width: handleWidth, height: r.height)
            (model.activeEdge == which ? NSColor.white : NSColor.controlAccentColor).setFill()
            NSBezierPath(roundedRect: h, xRadius: 3, yRadius: 3).fill()
            (model.activeEdge == which ? NSColor.controlAccentColor : NSColor.white).setFill()
            NSBezierPath(roundedRect: NSRect(x: h.midX - 0.75, y: h.midY - 9, width: 1.5, height: 18), xRadius: 0.75, yRadius: 0.75).fill()
        }
        let label = String(format: L("%@ selecionados"), Self.format(sel.length)) as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white]
        let sz = label.size(withAttributes: attrs)
        if r.width > sz.width + 16 {
            let pill = NSRect(x: r.midX - sz.width / 2 - 6, y: r.minY + 3, width: sz.width + 12, height: sz.height + 4)
            NSColor.black.withAlphaComponent(0.65).setFill(); NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
            label.draw(at: NSPoint(x: pill.minX + 6, y: pill.minY + 2), withAttributes: attrs)
        }
    }

    private func drawRuler() {
        let d = duration
        let steps: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800]
        let step = steps.first { CGFloat($0 / d) * trackWidth >= 60 } ?? 3600
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular), .foregroundColor: NSColor(white: 0.7, alpha: 1)]
        var t = 0.0
        NSColor(white: 0.45, alpha: 1).setStroke()
        while t <= d + 1e-9 {
            let px = x(t)
            let p = NSBezierPath(); p.move(to: NSPoint(x: px, y: rulerHeight - 6)); p.line(to: NSPoint(x: px, y: rulerHeight - 1)); p.lineWidth = 1; p.stroke()
            (Self.format(t, tenths: step < 1) as NSString).draw(at: NSPoint(x: px + 3, y: 4), withAttributes: attrs)
            t += step
        }
    }

    static func format(_ seconds: Double, tenths: Bool = true) -> String {
        let s = max(0, seconds)
        let m = Int(s) / 60, sec = s - Double(m * 60)
        if s >= 3600 { return String(format: "%d:%02d:%02d", Int(s) / 3600, (Int(s) / 60) % 60, Int(s) % 60) }
        return tenths ? String(format: "%d:%05.2f", m, sec) : String(format: "%d:%02d", m, Int(sec))
    }

    // MARK: Rato

    private func hitHandle(_ p: NSPoint) -> Drag? {
        guard let sel = model?.selection, tracksArea.insetBy(dx: -10, dy: -4).contains(p) else { return nil }
        let ds = abs(p.x - x(sel.start)), de = abs(p.x - x(sel.end))
        guard min(ds, de) <= handleWidth else { return nil }
        return ds <= de ? .start : .end
    }

    private func lane(atY y: CGFloat) -> EditTrack? { lanes.first { rowRect($0).insetBy(dx: 0, dy: -2).minY <= y && y <= rowRect($0).maxY + 2 } }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        pressPoint = p; moved = false
        guard let model else { return }
        if p.x < headerWidth { if let l = lane(atY: p.y) { model.toggleMask(l); needsDisplay = true }; drag = .none; return }
        if event.clickCount == 2, let l = lane(atY: p.y), let g = model.timeline.gaps(l).first(where: { $0.contains(time(p.x)) }) {
            model.selection = g; model.activeEdge = .start; model.preview(g.start, label: L("Início do trecho")); drag = .none; return
        }
        if let h = hitHandle(p) {
            drag = h
            model.activeEdge = (h.isStart) ? .start : .end
            if let sel = model.selection { model.preview(h.isStart ? sel.start : sel.end, label: h.isStart ? L("Início do trecho") : L("Fim do trecho")) }
            return
        }
        if p.y < rulerHeight { drag = .scrub; model.clearPreview(); model.seek(to: time(p.x)); return }
        drag = tracksArea.insetBy(dx: 0, dy: -4).contains(p) ? .selecting(anchor: time(p.x)) : .none
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model else { return }
        let p = convert(event.locationInWindow, from: nil)
        if abs(p.x - pressPoint.x) > 3 { moved = true }
        let t = time(p.x)
        switch drag {
        case .scrub: model.seek(to: t)
        case let .selecting(anchor):
            guard moved else { return }
            let sel = TimeSpan(start: min(anchor, t), end: max(anchor, t))
            model.selection = sel
            model.activeEdge = t >= anchor ? .end : .start
            model.preview(t, label: t >= anchor ? L("Fim do trecho") : L("Início do trecho"))
        case .start:
            if let e = model.selection?.end { model.selection = TimeSpan(start: min(t, e), end: e); model.preview(min(t, e), label: L("Início do trecho")) }
        case .end:
            if let s = model.selection?.start { model.selection = TimeSpan(start: s, end: max(t, s)); model.preview(max(t, s), label: L("Fim do trecho")) }
        case .none: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let model else { return }
        let p = convert(event.locationInWindow, from: nil)
        if case .selecting = drag, !moved { model.selection = nil; model.clearPreview(); model.seek(to: time(p.x)) }   // clique simples
        if let sel = model.selection, sel.length < 0.02 { model.selection = nil }
        drag = .none
    }

    override func resetCursorRects() {
        guard let sel = model?.selection else { return }
        let a = tracksArea
        for t in [sel.start, sel.end] { addCursorRect(NSRect(x: x(t) - handleWidth, y: a.minY, width: 2 * handleWidth, height: a.height), cursor: .resizeLeftRight) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard model?.selection != nil || model?.canPaste == true else { return nil }
        let m = NSMenu()
        func add(_ title: String, _ a: Action, _ enabled: Bool = true) {
            let i = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: ""); i.target = self; i.isEnabled = enabled
            i.representedObject = a; m.addItem(i)
        }
        let has = model?.selection != nil
        add(L("Cortar e juntar"), .cutJoin, has); add(L("Cortar deixando espaço"), .cutGap, has); m.addItem(.separator())
        add(L("Copiar"), .copy, has); add(L("Colar (insere)"), .paste, model?.canPaste == true); add(L("Colar por cima"), .pasteOver, model?.canPaste == true); m.addItem(.separator())
        add(L("Inverter o trecho"), .reverse, has)
        return m
    }
    @objc private func menuAction(_ item: NSMenuItem) { if let a = item.representedObject as? Action { onAction?(a) } }

    // MARK: Teclado

    @objc func copy(_ sender: Any?) { onAction?(.copy) }
    @objc func paste(_ sender: Any?) { onAction?(.paste) }

    override func keyDown(with event: NSEvent) {
        guard let model else { return }
        let shift = event.modifierFlags.contains(.shift)
        if event.modifierFlags.contains(.command) { super.keyDown(with: event); return }
        switch event.charactersIgnoringModifiers {
        case " ": onAction?(.togglePlay)
        case "\u{7F}", "\u{F728}": onAction?(shift ? .cutGap : .cutJoin)
        case "i", "I": model.markStart(); if let s = model.selection { model.preview(s.start, label: L("Início do trecho")) }
        case "o", "O": model.markEnd(); if let s = model.selection { model.preview(s.end, label: L("Fim do trecho")) }
        case "\t": if model.selection != nil { model.activeEdge = model.activeEdge == .start ? .end : .start; if let s = model.selection { model.preview(model.activeEdge == .start ? s.start : s.end, label: model.activeEdge == .start ? L("Início do trecho") : L("Fim do trecho")) } }
        case "\u{1B}": model.selection = nil; model.clearPreview()
        case String(UnicodeScalar(NSLeftArrowFunctionKey)!): model.step(shift ? -1 : -model.frameStep, moveEdge: true)
        case String(UnicodeScalar(NSRightArrowFunctionKey)!): model.step(shift ? 1 : model.frameStep, moveEdge: true)
        default: super.keyDown(with: event)
        }
    }
}

struct VideoTimeline: NSViewRepresentable {
    @ObservedObject var model: VideoEditorModel
    var onAction: (TimelineNSView.Action) -> Void

    func makeNSView(context: Context) -> TimelineNSView {
        let v = TimelineNSView()
        v.model = model
        v.onAction = onAction
        return v
    }

    func updateNSView(_ v: TimelineNSView, context: Context) {
        v.model = model
        v.onAction = onAction
        v.needsDisplay = true
        v.window?.invalidateCursorRects(for: v)
    }
}
