// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit
import ImageIO
import CaptureCore

/// Imagens coladas: entradas `assets/<nome>` do contentor da captura (arquivo ou pasta), com cache em memória.
/// Num arquivo só ficam gravadas no disco quando o editor faz `flush()` (a cada alteração).
final class AssetStore {
    private let container: CaptureContainer
    private var cache: [String: CGImage] = [:]

    init(container: CaptureContainer) { self.container = container }

    private func path(_ name: String) -> String { "assets/\(name)" }

    func image(named name: String) -> CGImage? {
        if let c = cache[name] { return c }
        guard let data = data(named: name), let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        cache[name] = img
        return img
    }

    func data(named name: String) -> Data? { container.data(path(name)) }
    func has(_ name: String) -> Bool { container.exists(path(name)) }

    /// Grava PNG novo e devolve o nome do ficheiro.
    func add(png: Data) throws -> String {
        let name = "\(UUID().uuidString).png"
        try write(png, as: name)
        return name
    }

    /// Grava com um nome já conhecido (ex.: colar de outro documento).
    func write(_ png: Data, as name: String) throws {
        try container.write(path(name), png)
        cache[name] = nil
    }
}
