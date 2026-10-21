// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit
import CaptureCore

/// A última personalização de cada ferramenta (cor, espessura, preenchimento, formato do texto, tamanhos…).
/// É partilhada por todas as capturas e fica guardada nas preferências, por isso sobrevive a fechar a app:
/// cada ferramenta volta a abrir com o que o utilizador usou da última vez, até ser alterado de novo.
@MainActor
final class ToolDefaults {
    static let shared = ToolDefaults(defaults: .standard)

    private struct Stored: Codable {
        var styles: [String: Style] = [:]
        var values: [String: Double] = [:]
    }

    private let defaults: UserDefaults
    private static let key = "toolDefaults.v1"
    private var stored: Stored

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let s = try? JSONDecoder().decode(Stored.self, from: data) {
            stored = s
        } else {
            stored = Stored()
        }
    }

    /// Estilo da ferramenta: o último usado, ou o inicial se nunca foi alterado.
    func style(for tool: Tool) -> Style { stored.styles[tool.rawValue] ?? tool.initialStyle }

    func setStyle(_ s: Style, for tool: Tool) {
        stored.styles[tool.rawValue] = s
        save()
    }

    /// Valores soltos (tamanho da letra, tamanho da pixelização, intensidade do blur), por ferramenta.
    func value(_ name: String, for tool: Tool, default d: Double) -> Double { stored.values["\(name).\(tool.rawValue)"] ?? d }

    func setValue(_ v: Double, _ name: String, for tool: Tool) {
        stored.values["\(name).\(tool.rawValue)"] = v
        save()
    }

    /// Volta a tudo como na primeira utilização.
    func resetAll() {
        stored = Stored()
        defaults.removeObject(forKey: Self.key)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.key) }
    }
}

extension Tool {
    /// A ferramenta que cria este tipo de elemento (para que editar um elemento selecionado atualize o padrão dessa ferramenta).
    static func forShape(_ shape: CaptureCore.Shape) -> Tool? {
        switch shape {
        case .arrow: .arrow
        case .line: .line
        case .rect: .rect
        case .ellipse: .ellipse
        case .text, .textBox: .text
        case .callout: .callout
        case .step: .step
        case .highlight: .highlight
        case .blur: .blur
        case .gaussian: .gaussian
        case .image: nil
        }
    }
}
