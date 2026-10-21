// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Abrir e guardar imagens em formatos comuns.
enum ImageFiles {
    /// Formatos em que se pode exportar.
    enum Format: CaseIterable {
        case png, jpeg, heic, tiff

        var type: UTType {
            switch self { case .png: .png; case .jpeg: .jpeg; case .heic: .heic; case .tiff: .tiff }
        }
        var ext: String {
            switch self { case .png: "png"; case .jpeg: "jpg"; case .heic: "heic"; case .tiff: "tif" }
        }
        var title: String {
            switch self { case .png: "PNG"; case .jpeg: "JPEG"; case .heic: "HEIC"; case .tiff: "TIFF" }
        }
        /// O JPEG não tem transparência.
        var flattens: Bool { self == .jpeg }
    }

    /// Lê uma imagem de um ficheiro, respeitando a orientação (fotografias de telemóvel vêm "deitadas" com uma etiqueta EXIF).
    static func load(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        if max(w, h) > 0 {
            // A API de miniaturas aplica a orientação; com o tamanho máximo igual ao da imagem, não perde resolução.
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                         kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceThumbnailMaxPixelSize: max(w, h)]
            if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) { return cg }
        }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Converte o PNG exportado para o formato pedido. Para formatos sem transparência, compõe sobre `flatten` (por omissão, branco).
    static func encode(png: Data, as format: Format, flattenOn flatten: NSColor = .white, quality: Double = 0.92) -> Data? {
        guard format != .png else { return png }
        guard let src = CGImageSourceCreateWithData(png as CFData, nil), var image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        if format.flattens {
            guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            ctx.setFillColor(flatten.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let flat = ctx.makeImage() else { return nil }
            image = flat
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, format.type.identifier as CFString, 1, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, image, opts as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
