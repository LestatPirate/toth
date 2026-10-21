// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import SwiftUI
import AppKit

/// Largura do painel de Propriedades (à direita). Arrasta-se a divisória para o redimensionar; abaixo de um limite o painel
/// "some" para o lado (largura 0) e volta a aparecer arrastando a mesma divisória (ou com duplo clique, ou no menu Ver).
@MainActor
final class PanelLayout: ObservableObject {
    static let shared = PanelLayout()
    private static let key = "propertiesPanelWidth"

    static let defaultWidth: CGFloat = 270
    static let minOpen: CGFloat = 220        // largura mínima enquanto visível
    static let maxWidth: CGFloat = 520
    static let collapseBelow: CGFloat = 120  // arrastar para menos que isto esconde o painel
    static let dividerWidth: CGFloat = 9     // divisória com o painel visível
    static let hiddenHandleWidth: CGFloat = 20   // faixa/pega com o painel escondido (larga, para não se confundir com a borda da janela)

    /// Rato por cima da divisória (realça a pega).
    @Published var hovering = false
    /// 0 = escondido.
    @Published private(set) var width: CGFloat
    private var dragStart: CGFloat?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.object(forKey: Self.key) as? Double
        width = stored.map { Self.clamp(CGFloat($0)) } ?? Self.defaultWidth
    }

    var isVisible: Bool { width > 0 }

    /// Regra de largura: abaixo de `collapseBelow` esconde; senão fica entre `minOpen` e `maxWidth`.
    static func clamp(_ proposed: CGFloat) -> CGFloat {
        proposed < collapseBelow ? 0 : min(max(proposed, minOpen), maxWidth)
    }

    /// `translationX` = quanto o rato andou desde o início do arrasto (para a esquerda aumenta o painel).
    func drag(translationX: CGFloat) {
        if dragStart == nil { dragStart = width }
        width = Self.clamp((dragStart ?? width) - translationX)
    }

    func endDrag() {
        dragStart = nil
        persist()
    }

    func toggle() {
        width = isVisible ? 0 : Self.defaultWidth
        persist()
    }

    private func persist() { defaults.set(Double(width), forKey: Self.key) }

    /// Só para testes visuais.
    func setWidthForTests(_ w: CGFloat) { width = w }
}

/// Divisória arrastável entre a área de trabalho e o painel. Com o painel visível é uma linha fina; com o painel escondido
/// transforma-se numa **faixa larga** com uma pega bem visível (e realce ao passar o rato), para não se confundir com a borda
/// da janela, que se redimensiona no limite exterior.
struct PanelDivider: View {
    @ObservedObject var layout: PanelLayout

    var body: some View {
        Group {
            if layout.isVisible { visibleDivider } else { hiddenHandle }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            layout.hovering = inside
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { layout.drag(translationX: $0.translation.width) }
            .onEnded { _ in layout.endDrag() })
        .onTapGesture(count: 2) { if layout.isVisible { layout.toggle() } }
        .onTapGesture { if !layout.isVisible { layout.toggle() } }   // com o painel escondido, um clique basta para o abrir
        .help(layout.isVisible ? L("Arraste para redimensionar as Propriedades (duplo clique esconde)")
                               : L("Mostrar Propriedades (clique ou arraste para a esquerda)"))
    }

    private var visibleDivider: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
        }
        .frame(width: PanelLayout.dividerWidth)
    }

    private var hiddenHandle: some View {
        ZStack {
            (layout.hovering ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor))
            HStack(spacing: 0) {
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
                Spacer(minLength: 0)
            }
            VStack(spacing: 7) {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                VStack(spacing: 4) { ForEach(0..<5, id: \.self) { _ in Circle().frame(width: 3.5, height: 3.5) } }
            }
            .foregroundStyle(layout.hovering ? Color.accentColor : Color.secondary)
        }
        .frame(width: PanelLayout.hiddenHandleWidth)
    }
}
