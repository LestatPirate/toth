// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import SwiftUI
import AppKit

/// Deslocamento das ferramentas na barra de cima. Funciona como um scroll contínuo, ao pixel:
/// - **manter premida** uma seta desliza as ferramentas a velocidade constante (para quando se solta ou se chega à ponta);
/// - um **clique rápido** dá um pequeno passo animado;
/// - a **roda do rato** e o **trackpad** deslizam a barra (a roda vertical também desliza na horizontal).
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
    /// Largura visível (definida pela barra a cada desenho).
    var viewport: CGFloat = 0
    /// Retângulo da barra nas coordenadas da janela (a partir do topo), para a roda do rato.
    var frame: CGRect = .zero

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
                guard let self, self.overflows, let content = event.window?.contentView else { return event }
                let p = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
                guard self.frame.contains(p) else { return event }
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
    private let tools = Tool.allCases
    private let arrowWidth: CGFloat = 22

    var body: some View {
        GeometryReader { geo in
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
                        BarButton(symbol: t.symbol, label: t.title, selected: model.tool == t, fixedWidth: ToolsScroll.buttonWidth) { model.tool = t }
                            .help(t.title)
                    }
                }
                .fixedSize()
                .offset(x: overflow ? -shown : 0)
                .frame(width: viewport, height: 54, alignment: overflow ? .topLeading : .top)
                .clipped()
                if overflow { arrow("chevron.right", direction: 1, enabled: scroll.canScrollRight, help: L("Mais ferramentas")) }
            }
            .frame(width: geo.size.width, height: 54, alignment: .topLeading)
            .background(GeometryReader { g in
                Color.clear.onAppear { scroll.frame = g.frame(in: .global) }.onChange(of: g.frame(in: .global)) { _, f in scroll.frame = f }
            })
            .onAppear { ToolsScroll.current = scroll; scroll.installWheelMonitor() }
            .onDisappear { scroll.removeWheelMonitor() }
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
