// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit
import CaptureCore

enum CaptureStore {
    /// Só para testes (`--library <pasta>`): usa outra pasta em vez de `~/Pictures/Capture`.
    nonisolated(unsafe) static var overrideFolder: URL?

    static var folder: URL {
        let url = overrideFolder ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Capture", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Guarda a captura como arquivo `.capture` único (ZIP): original imutável + document.json + miniatura.
    /// `backgroundHex`/`transparentBackground`: cor usada quando a área de trabalho for aumentada (imagens novas em branco).
    static func save(_ image: CGImage, backgroundHex: String? = nil, transparentBackground: Bool = false) throws -> URL {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HH.mm.ss"
        // Nome único (importar várias imagens no mesmo segundo não pode juntar capturas diferentes).
        let stamp = fmt.string(from: Date())
        var url = folder.appendingPathComponent("Toth_\(stamp).capture")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("Toth_\(stamp)_\(n).capture"); n += 1
        }
        var doc = CaptureDocument(canvasWidth: Double(image.width), canvasHeight: Double(image.height))
        if let hex = backgroundHex { doc.backgroundHex = hex }
        doc.transparentBackground = transparentBackground
        var entries: [String: Data] = [CapturePackage.documentFile: try CapturePackage.encode(doc), CapturePackage.originalFile: png]
        if let preview = Thumbnails.previewPNG(fromPNG: png) { entries[CapturePackage.previewFile] = preview }
        _ = try CaptureContainer.createArchive(at: url, entries: entries)
        return url
    }

    static func copyToPasteboard(_ image: CGImage) {
        let ns = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([ns])
    }
}
