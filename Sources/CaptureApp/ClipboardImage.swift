// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit
import ImageIO

/// Imagem na área de transferência, de qualquer origem: PNG, TIFF (capturas de outras apps), ficheiros de imagem
/// copiados no Finder ou qualquer imagem que o macOS saiba converter.
enum ClipboardImage {
    static func png() -> Data? {
        let pb = NSPasteboard.general
        if let d = pb.data(forType: .png) { return d }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingContentsConformToTypes: ["public.image"]]) as? [URL],
           let u = urls.first, let img = NSImage(contentsOf: u) { return png(from: img) }
        if let img = pb.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage { return png(from: img) }
        return nil
    }

    static func cgImage() -> CGImage? {
        guard let data = png(), let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    static func png(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
