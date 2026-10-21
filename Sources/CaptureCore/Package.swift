// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import Foundation

/// Uma captura `.capture` guarda: `document.json`, `assets/original.png` (imutável), `assets/*.png`
/// (imagens coladas) e `preview.png`. Ver `CaptureContainer` para o formato (arquivo ZIP ou pasta antiga).
public enum CapturePackage {
    public static let documentFile = "document.json"
    public static let originalFile = "assets/original.png"
    public static let previewFile = "preview.png"

    public enum Failure: Error { case missingDocument, unsupportedVersion(Int) }

    public static func encode(_ doc: CaptureDocument) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(doc)
    }

    /// Grava o documento no contentor (e o original, só se ainda não existir: nunca é sobrescrito).
    public static func save(_ doc: CaptureDocument, originalImage: Data? = nil, to container: CaptureContainer) throws {
        try container.write(documentFile, try encode(doc))
        if let data = originalImage, !container.exists(originalFile) { try container.write(originalFile, data) }
        try container.flush()
    }

    public static func read(from container: CaptureContainer) throws -> CaptureDocument {
        guard let data = container.data(documentFile) else { throw Failure.missingDocument }
        let doc = try JSONDecoder().decode(CaptureDocument.self, from: data)
        guard doc.formatVersion <= CaptureDocument.currentFormatVersion else { throw Failure.unsupportedVersion(doc.formatVersion) }
        return doc
    }

    /// Atalhos por URL: se `url` não existe cria um **arquivo** novo; se for uma pasta antiga, continua a usá-la.
    public static func write(_ doc: CaptureDocument, originalImage: Data?, to url: URL) throws {
        let container: CaptureContainer
        if FileManager.default.fileExists(atPath: url.path) {
            container = try CaptureContainer(url: url)
        } else {
            container = try CaptureContainer.createArchive(at: url, entries: [documentFile: try encode(doc)])
        }
        try save(doc, originalImage: originalImage, to: container)
    }

    public static func read(from url: URL) throws -> CaptureDocument { try read(from: try CaptureContainer(url: url)) }
}
