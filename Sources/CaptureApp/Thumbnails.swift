// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit
import ImageIO
import CaptureCore

/// Miniaturas da biblioteca: `preview.png` dentro de cada pacote (regenerado a cada gravação do editor).
enum Thumbnails {
    static let maxPixel = 360

    /// Miniatura (PNG pequeno) a partir do PNG completo.
    static func previewPNG(fromPNG png: Data) -> Data? { thumbnailPNG(from: CGImageSourceCreateWithData(png as CFData, nil)) }

    /// Lê o preview guardado na captura (arquivo ou pasta); se não existir (captura antiga), gera-o a partir do original.
    static func load(_ package: URL) -> NSImage? {
        if let d = CaptureContainer.readEntry(CapturePackage.previewFile, at: package), let img = NSImage(data: d) { return img }
        guard let original = CaptureContainer.readEntry(CapturePackage.originalFile, at: package),
              let data = previewPNG(fromPNG: original) else { return nil }
        // Em pastas antigas guarda-se o preview gerado; num arquivo não se reescreve a partir de uma leitura.
        if CaptureContainer.isFolderCapture(package) { try? data.write(to: package.appendingPathComponent(CapturePackage.previewFile), options: .atomic) }
        return NSImage(data: data)
    }

    private static func thumbnailPNG(from source: CGImageSource?) -> Data? {
        guard let source else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}
