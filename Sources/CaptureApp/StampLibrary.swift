// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit
import CaptureCore

/// Carimbos: símbolos do sistema (pintados com a cor do estilo), emojis e imagens importadas pelo utilizador
/// (guardadas em `~/Library/Application Support/Toth/Stamps`, como PNG). Um carimbo de imagem entra no documento como `image`
/// (a imagem fica dentro da captura, como ao colar).
@MainActor
final class StampLibrary: ObservableObject {
    static let shared = StampLibrary()

    /// Símbolos prontos (nome SF Symbol).
    static let symbols = ["checkmark.circle.fill", "xmark.circle.fill", "exclamationmark.triangle.fill", "questionmark.circle.fill", "info.circle.fill",
                          "star.fill", "heart.fill", "hand.thumbsup.fill", "hand.thumbsdown.fill", "flag.fill", "bolt.fill", "lightbulb.fill",
                          "lock.fill", "eye.fill", "bell.fill", "pin.fill", "hand.point.up.left.fill", "cursorarrow.click.2", "checkmark", "xmark",
                          "plus.circle.fill", "minus.circle.fill", "arrow.right.circle.fill", "clock.fill", "trash.fill", "gearshape.fill"]
    /// Emojis prontos.
    static let emojis = ["✅", "❌", "⚠️", "❓", "💡", "⭐️", "❤️", "👍", "👎", "🔥", "🎯", "📌", "🚀", "👀", "🙂", "😮", "🤔", "🎉", "1️⃣", "2️⃣", "3️⃣", "➡️", "⬅️", "🔒"]

    /// `"sf:nome"` para símbolos; o próprio texto para emojis.
    nonisolated static func symbolKey(_ name: String) -> String { "sf:\(name)" }
    nonisolated static func isSymbol(_ s: String) -> Bool { s.hasPrefix("sf:") }
    nonisolated static func symbolName(_ s: String) -> String? { isSymbol(s) ? String(s.dropFirst(3)) : nil }

    /// Imagens importadas (ficheiros PNG na pasta dos carimbos), por ordem de nome.
    @Published private(set) var images: [URL] = []

    nonisolated(unsafe) static var overrideFolder: URL?
    static var folder: URL {
        let url = overrideFolder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Toth/Stamps", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    init() { reload() }

    func reload() {
        let items = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        images = items.filter { $0.pathExtension.lowercased() == "png" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Importa ficheiros de imagem (qualquer formato que o sistema leia) como carimbos: ficam em PNG, até 1024 px de lado.
    /// Devolve os nomes que não foi possível importar.
    @discardableResult
    func importImages(_ urls: [URL]) -> [String] {
        var failed: [String] = []
        for u in urls {
            guard let img = ImageFiles.load(u), let png = Self.png(img, maxSide: 1024) else { failed.append(u.lastPathComponent); continue }
            let base = u.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "/", with: "-")
            var dest = Self.folder.appendingPathComponent(base + ".png")
            var n = 2
            while FileManager.default.fileExists(atPath: dest.path) { dest = Self.folder.appendingPathComponent("\(base)-\(n).png"); n += 1 }
            do { try png.write(to: dest) } catch { failed.append(u.lastPathComponent) }
        }
        reload()
        return failed
    }

    func remove(_ url: URL) { try? FileManager.default.trashItem(at: url, resultingItemURL: nil); reload() }

    /// PNG de uma imagem, reduzida se passar de `maxSide` de lado.
    nonisolated static func png(_ img: CGImage, maxSide: Int) -> Data? {
        let k = min(1, Double(maxSide) / Double(max(img.width, img.height)))
        let w = max(1, Int(Double(img.width) * k)), h = max(1, Int(Double(img.height) * k))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
    }

    /// Imagem de um símbolo do sistema, para desenhar como carimbo (cor única; tamanho em pontos grande para ficar nítido).
    nonisolated static func symbolImage(_ name: String, color: NSColor, pointSize: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular).applying(.init(paletteColors: [color])))
    }
}
