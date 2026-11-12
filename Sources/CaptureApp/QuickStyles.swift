// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit
import CaptureCore

/// Um estilo rápido: uma ferramenta com um estilo (e valores soltos, como o tamanho da letra) guardados com nome,
/// para aplicar com um clique (como os Quick Styles do Snagit). Vivem nas preferências, fora das capturas.
struct QuickStyle: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    /// `Tool.rawValue`.
    var tool: String
    var style: Style
    var values: [String: Double]

    var toolValue: Tool { Tool(rawValue: tool) ?? .arrow }
}

@MainActor
final class QuickStyles: ObservableObject {
    static let shared = QuickStyles(defaults: .standard)
    private static let key = "quickStyles.v1"
    private let defaults: UserDefaults
    @Published private(set) var items: [QuickStyle]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let s = try? JSONDecoder().decode([QuickStyle].self, from: data) {
            items = s
        } else {
            items = Self.starter
        }
    }

    /// Os que vêm de origem (a primeira vez, ou depois de «Repor»): exemplos do que se pode guardar.
    static var starter: [QuickStyle] {
        [
            QuickStyle(id: UUID(), name: L("Seta vermelha grossa"), tool: Tool.arrow.rawValue, style: Style(colorHex: "#FF3B30", lineWidth: 6), values: [:]),
            QuickStyle(id: UUID(), name: L("Seta azul fina"), tool: Tool.arrow.rawValue, style: Style(colorHex: "#0A84FF", lineWidth: 3), values: [:]),
            QuickStyle(id: UUID(), name: L("Retângulo vermelho"), tool: Tool.rect.rawValue, style: Style(colorHex: "#FF3B30", lineWidth: 4), values: [:]),
            QuickStyle(id: UUID(), name: L("Texto branco com fundo escuro"), tool: Tool.text.rawValue,
                       style: Style(colorHex: "#1C1C1E", fillHex: "#1C1C1E", lineVisible: false, text: TextFormat(bold: true, colorHex: "#FFFFFF")), values: ["fontSize": 22]),
            QuickStyle(id: UUID(), name: L("Etapa azul"), tool: Tool.step.rawValue, style: Style(colorHex: "#0A84FF"), values: [:]),
            QuickStyle(id: UUID(), name: L("Marcador amarelo"), tool: Tool.highlight.rawValue, style: Style(colorHex: "#FFD60A", opacity: 0.4), values: [:]),
        ]
    }

    @discardableResult
    func add(tool: Tool, style: Style, values: [String: Double], name: String? = nil) -> QuickStyle {
        let n = items.filter { $0.tool == tool.rawValue }.count + 1
        let q = QuickStyle(id: UUID(), name: name ?? "\(tool.title) \(n)", tool: tool.rawValue, style: style, values: values)
        items.append(q); save()
        return q
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { items[i].name = t; save() }
    }

    /// Substitui o estilo (e os valores) de um estilo rápido, mantendo o nome.
    func update(_ id: UUID, style: Style, values: [String: Double]) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].style = style; items[i].values = values; save()
    }

    func remove(_ id: UUID) { items.removeAll { $0.id == id }; save() }

    /// Volta aos exemplos de origem.
    func resetToStarter() { items = Self.starter; save() }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { defaults.set(data, forKey: Self.key) }
    }
}
