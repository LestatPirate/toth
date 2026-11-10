// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import SwiftUI
import AppKit

/// Deslocamento das ferramentas na barra de cima. Funciona como um scroll contínuo, ao pixel:
/// - **manter premida** uma seta desliza as ferramentas a velocidade constante (para quando se solta ou se chega à ponta);
/// - um **clique rápido** dá um pequeno passo animado;
/// - a **roda do rato** e o **trackpad** deslizam a barra (a roda vertical também desliza na horizontal);
/// - **pousar o rato** junto a uma ponta desliza sozinho para esse lado (mais depressa quanto mais perto da ponta).
@MainActor
final class ToolsScroll: ObservableObject {
    /// A barra em uso (para os testes).
    nonisolated(unsafe) static weak var current: ToolsScroll?

    /// Velocidade ao manter a seta premida (píxeis por segundo) e tamanho do passo de um clique rápido.
    static let speed: CGFloat = 430
    static let clickStep: CGFloat = 96
    private static let holdDelay: TimeInterval = 0.16

    /// Quanto o conteúdo foi deslizado para a esquerda (0 = início).
    @Published private(set) var offset: CGFloat = 0
    /// Cada ferramenta tem largura fixa (`buttonWidth`), por isso a largura do conteúdo é exata e não precisa de ser medida.
    static let buttonWidth: CGFloat = 56            // + 8 de margem do botão = 64
    static let spacing: CGFloat = 2
    static var slot: CGFloat { buttonWidth + 8 + spacing }
    var contentWidth: CGFloat = CGFloat(Tool.allCases.count) * ToolsScroll.slot - ToolsScroll.spacing
    func setToolCount(_ n: Int) { contentWidth = CGFloat(n) * ToolsScroll.slot - ToolsScroll.spacing }
    /// Largura visível (definida pela barra a cada desenho).
    var viewport: CGFloat = 0
    /// A vista nativa que cobre a barra inteira: diz onde está o rato (deslize automático) e delimita a zona da roda.
    weak var trackView: NSView?
    /// O ponto (coordenadas da janela) está sobre a barra das ferramentas?
    func contains(windowPoint p: CGPoint, in window: NSWindow?) -> Bool {
        guard let v = trackView, let w = v.window, w === window else { return false }
        return v.bounds.contains(v.convert(p, from: nil))
    }

    private var timer: Timer?
    private var holdItem: DispatchWorkItem?
    private var holdDirection = 0
    private var holding = false
    private var monitor: Any?
    private var lastTick = Date()

    var maxOffset: CGFloat { max(0, contentWidth - viewport) }
    var overflows: Bool { maxOffset > 0.5 }
    var canScrollLeft: Bool { offset > 0.5 }
    var canScrollRight: Bool { offset < maxOffset - 0.5 }

    private func clamp(_ v: CGFloat) -> CGFloat { min(max(v, 0), maxOffset) }

    /// Quando a janela muda de tamanho, mantém o deslocamento dentro dos limites.
    func reclamp() { let c = clamp(offset); if c != offset { offset = c } }

    /// A barra diz quanto espaço tem; se encolheu, o deslocamento é reposto dentro dos limites.
    func updateViewport(_ w: CGFloat) {
        guard abs(w - viewport) > 0.5 else { return }
        viewport = w
        DispatchQueue.main.async { [weak self] in self?.reclamp() }
    }

    /// Põe o deslocamento num valor (barra de rolagem arrastada).
    func setOffset(_ v: CGFloat) { offset = clamp(v) }

    func scroll(by dx: CGFloat, animated: Bool = false) {
        let target = clamp(offset + dx)
        if animated { withAnimation(.easeOut(duration: 0.22)) { offset = target } } else { offset = target }
    }

    /// Passo de tempo do deslize contínuo (público para os testes). `direction`: -1 esquerda, +1 direita.
    func advance(dt: TimeInterval, direction: Int) {
        offset = clamp(offset + CGFloat(direction) * Self.speed * CGFloat(dt))
    }

    /// Traz uma ferramenta (por índice) para dentro da área visível, com o mínimo de movimento.
    func reveal(index: Int, animated: Bool = true) {
        guard viewport > 0 else { return }
        let slot = Self.slot
        let left = slot * CGFloat(index), right = left + slot - Self.spacing
        var target = offset
        if left < offset { target = left } else if right > offset + viewport { target = right - viewport }
        target = clamp(target)
        if target != offset { if animated { withAnimation(.easeInOut(duration: 0.2)) { offset = target } } else { offset = target } }
    }

    // MARK: Seta premida

    func pressBegan(direction: Int) {
        guard holdItem == nil, !holding else { return }
        holdDirection = direction
        let item = DispatchWorkItem { [weak self] in self?.startHolding() }
        holdItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDelay, execute: item)
    }

    func pressEnded() {
        let wasHolding = holding
        holdItem?.cancel(); holdItem = nil
        stopHolding()
        if !wasHolding { scroll(by: CGFloat(holdDirection) * Self.clickStep, animated: true) }   // clique rápido: um passo
        holdDirection = 0
    }

    private func startHolding() {
        holdItem = nil
        holding = true
        lastTick = Date()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Date(); let dt = now.timeIntervalSince(self.lastTick); self.lastTick = now
                self.advance(dt: min(dt, 0.05), direction: self.holdDirection)
                if (self.holdDirection < 0 && !self.canScrollLeft) || (self.holdDirection > 0 && !self.canScrollRight) { self.stopHolding() }
            }
        }
        RunLoop.main.add(t, forMode: .common)   // continua a correr mesmo com o rato premido
        timer = t
    }

    private func stopHolding() { timer?.invalidate(); timer = nil; holding = false }

    // MARK: Deslize automático (rato pousado junto a uma ponta)

    /// Largura da zona, a contar de cada ponta da barra, onde pousar o rato faz deslizar.
    static let hoverZone: CGFloat = 54
    static let hoverSpeed: CGFloat = 300
    private static let hoverDelay: TimeInterval = 0.22
    private var hoverTimer: Timer?
    private var hoverItem: DispatchWorkItem?
    private(set) var hoverDirection = 0
    private var hoverFactor: CGFloat = 0

    /// Para onde (e com que força, 0…1) desliza com o rato em `x` numa barra de largura `width`: quanto mais perto da
    /// ponta, mais depressa. `0` fora das zonas, ou se já não há mais para esse lado.
    func hoverPull(x: CGFloat, width: CGFloat) -> (direction: Int, factor: CGFloat) {
        guard overflows, width > 2 * Self.hoverZone, x >= 0, x <= width else { return (0, 0) }
        if x < Self.hoverZone, canScrollLeft { return (-1, 0.35 + 0.65 * (1 - x / Self.hoverZone)) }
        if x > width - Self.hoverZone, canScrollRight { return (1, 0.35 + 0.65 * (1 - (width - x) / Self.hoverZone)) }
        return (0, 0)
    }

    /// O rato está em `x` sobre a barra (`nil` = saiu). Começa a deslizar depois de uma pequena pausa, para não fugir a
    /// quem só vai clicar numa ferramenta perto da ponta.
    func hover(x: CGFloat?, width: CGFloat) {
        let pull = x.map { hoverPull(x: $0, width: width) } ?? (0, 0)
        hoverFactor = pull.factor
        guard pull.direction != hoverDirection else { return }
        hoverDirection = pull.direction
        hoverItem?.cancel(); hoverItem = nil
        hoverTimer?.invalidate(); hoverTimer = nil
        guard pull.direction != 0 else { return }
        let item = DispatchWorkItem { [weak self] in self?.startHoverSlide() }
        hoverItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverDelay, execute: item)
    }

    /// Passo do deslize automático (público para os testes).
    func advanceHover(dt: TimeInterval) {
        guard hoverDirection != 0, !holding else { return }
        offset = clamp(offset + CGFloat(hoverDirection) * Self.hoverSpeed * hoverFactor * CGFloat(dt))
    }

    private func startHoverSlide() {
        hoverItem = nil
        lastTick = Date()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Date(); let dt = now.timeIntervalSince(self.lastTick); self.lastTick = now
                self.advanceHover(dt: min(dt, 0.05))
                if (self.hoverDirection < 0 && !self.canScrollLeft) || (self.hoverDirection > 0 && !self.canScrollRight) { self.hover(x: nil, width: 0) }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        hoverTimer = t
    }

    // MARK: Roda do rato / trackpad

    /// `dx`/`dy`: deslocamentos do evento. Qualquer eixo desliza a barra (a roda vertical de um rato também).
    func wheel(dx: CGFloat, dy: CGFloat) {
        let d = abs(dx) >= abs(dy) ? -dx : -dy
        guard overflows, d != 0 else { return }
        scroll(by: d)
    }

    func installWheelMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.overflows, self.contains(windowPoint: event.locationInWindow, in: event.window) else { return event }
                self.wheel(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY)
                return nil   // consumido: não rola nada por baixo
            }
        }
    }

    func removeWheelMonitor() { if let m = monitor { NSEvent.removeMonitor(m) }; monitor = nil }
}

/// Ferramentas com deslocamento lateral: quando a janela é estreita, as que não cabem deslizam (ver `ToolsScroll`).
struct ToolsBar: View {
    @ObservedObject var model: EditorModel
    @StateObject private var scroll = ToolsScroll()
    /// Nas anotações de um vídeo não há Tela (o enquadramento é o do vídeo).
    private var tools: [Tool] { model.isVideoOverlay ? Tool.allCases.filter { $0 != .canvas && $0 != .ocr } : Tool.allCases }
    private let arrowWidth: CGFloat = 22

    var body: some View {
        GeometryReader { geo in
            let _ = scroll.setToolCount(tools.count)
            let content = scroll.contentWidth
            let overflow = content > geo.size.width + 1
            let viewport = max(geo.size.width - (overflow ? 2 * arrowWidth : 0), 0)
            let _ = scroll.updateViewport(viewport)         // (não publica: só guarda a largura visível para a lógica de deslize)
            let shown = min(max(scroll.offset, 0), max(0, content - viewport))
            HStack(spacing: 0) {
                if overflow { arrow("chevron.left", direction: -1, enabled: scroll.canScrollLeft, help: L("Ferramentas anteriores")) }
                // área visível: o conteúdo desliza com `offset` (ou fica centrado, se cabe tudo)
                HStack(spacing: ToolsScroll.spacing) {
                    ForEach(tools) { t in
                        BarButton(symbol: t.symbol, label: t.title, selected: model.tool == t, fixedWidth: ToolsScroll.buttonWidth,
                                  badge: model.tool == t && model.toolLocked ? "lock.fill" : nil) { model.tool = t }
                            // duplo clique prende a ferramenta: continua ativa depois de desenhar (outro duplo clique solta)
                            .simultaneousGesture(TapGesture(count: 2).onEnded { if t != .select && t != .canvas { model.tool = t; model.toolLocked.toggle() } })
                            .help(model.tool == t && model.toolLocked ? L("Ferramenta presa: continua ativa depois de desenhar (duplo clique solta)") : (t == .select || t == .canvas ? t.title : L("%@ (duplo clique prende a ferramenta)", t.title)))
                    }
                }
                .fixedSize()
                .offset(x: overflow ? -shown : 0)
                .frame(width: viewport, height: 54, alignment: overflow ? .topLeading : .top)
                .clipped()
                // barra de rolagem (como a da faixa de miniaturas): o polegar mostra onde se está e arrasta-se
                .overlay(alignment: .bottom) {
                    if overflow {
                        GeometryReader { track in
                            let tw = track.size.width
                            let thumbW = max(28, tw * viewport / max(content, 1))
                            let thumbX = (tw - thumbW) * (shown / max(content - viewport, 1))
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.secondary.opacity(0.12))
                                Capsule().fill(Color.secondary.opacity(0.45)).frame(width: thumbW).offset(x: thumbX)
                            }
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                                scroll.setOffset((g.location.x - thumbW / 2) / max(tw - thumbW, 1) * (content - viewport))
                            })
                        }
                        .frame(height: 6).padding(.horizontal, 4).padding(.bottom, 1)
                    }
                }
                if overflow { arrow("chevron.right", direction: 1, enabled: scroll.canScrollRight, help: L("Mais ferramentas")) }
            }
            .frame(width: geo.size.width, height: 54, alignment: .topLeading)
            // área de seguimento nativa sobre a barra TODA (os botões não a tapam, e os cliques passam por ela): pousar o
            // rato junto a uma ponta desliza as ferramentas para esse lado, e a roda/trackpad vale em toda a altura
            .overlay(ToolsTracker(scroll: scroll).allowsHitTesting(false))
            .onAppear { ToolsScroll.current = scroll; scroll.installWheelMonitor() }
            .onDisappear { scroll.removeWheelMonitor(); scroll.hover(x: nil, width: 0) }
            // a ferramenta escolhida (por atalho, ou noutro sítio) fica sempre à vista
            .onChange(of: model.tool) { _, t in scroll.reveal(index: tools.firstIndex(of: t) ?? 0) }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 54)
    }

    /// Seta: manter premida desliza; um clique rápido dá um passo. (Um gesto de arrasto sem distância mínima dá o "premir" e o "soltar".)
    private func arrow(_ symbol: String, direction: Int, enabled: Bool, help: String) -> some View {
        Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).frame(width: arrowWidth, height: 40)
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.25)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if enabled { scroll.pressBegan(direction: direction) } }
                .onEnded { _ in scroll.pressEnded() })
            .help(help)
    }
}

/// Vista transparente por cima da barra das ferramentas: segue o rato com uma `NSTrackingArea` (que não depende de quem
/// recebe os cliques) e serve de referência para saber se a roda do rato está sobre a barra.
private struct ToolsTracker: NSViewRepresentable {
    let scroll: ToolsScroll
    func makeNSView(context: Context) -> TrackView { let v = TrackView(); v.scroll = scroll; scroll.trackView = v; return v }
    func updateNSView(_ v: TrackView, context: Context) { v.scroll = scroll; scroll.trackView = v }

    final class TrackView: NSView {
        weak var scroll: ToolsScroll?
        private var area: NSTrackingArea?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }   // os cliques vão para os botões por baixo
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let a = area { removeTrackingArea(a) }
            let a = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(a); area = a
        }
        private func report(_ e: NSEvent) { scroll?.hover(x: convert(e.locationInWindow, from: nil).x, width: bounds.width) }
        override func mouseEntered(with event: NSEvent) { report(event) }
        override func mouseMoved(with event: NSEvent) { report(event) }
        override func mouseExited(with event: NSEvent) { scroll?.hover(x: nil, width: bounds.width) }
    }
}
