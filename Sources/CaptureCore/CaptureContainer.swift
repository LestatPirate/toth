// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import Foundation

/// Onde vive uma captura: um **arquivo** `.capture` (ZIP, formato novo) ou uma **pasta** `.capture` (formato
/// antigo, que continua a abrir). Quem usa o contentor não precisa de saber qual dos dois é.
///
/// Entradas: `document.json`, `assets/original.png` (imutável), `assets/<uuid>.png` (imagens coladas), `preview.png`.
public final class CaptureContainer {
    public enum Kind: Equatable, Sendable { case folder, archive }

    public let url: URL
    public let kind: Kind
    private var entries: [String: Data] = [:]   // só no arquivo (em memória até ao flush)
    private var dirty = false

    /// Abre uma captura existente (pasta ou arquivo).
    public init(url: URL) throws {
        self.url = url
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { throw CocoaError(.fileNoSuchFile) }
        if isDir.boolValue {
            kind = .folder
        } else {
            kind = .archive
            entries = try ZipArchive.readAll(at: url)
        }
    }

    /// Cria um arquivo novo com estas entradas.
    public static func createArchive(at url: URL, entries: [String: Data]) throws -> CaptureContainer {
        try ZipArchive.make(entries).write(to: url, options: .atomic)
        return try CaptureContainer(url: url)
    }

    public static func isFolderCapture(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return url.pathExtension == "capture" && FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    public func data(_ path: String) -> Data? {
        kind == .archive ? entries[path] : try? Data(contentsOf: url.appendingPathComponent(path))
    }

    public func exists(_ path: String) -> Bool {
        kind == .archive ? entries[path] != nil : FileManager.default.fileExists(atPath: url.appendingPathComponent(path).path)
    }

    /// Num arquivo só fica gravado após `flush()`; numa pasta grava logo.
    public func write(_ path: String, _ data: Data) throws {
        if kind == .archive {
            entries[path] = data; dirty = true
        } else {
            let file = url.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        }
    }

    public func flush() throws {
        guard kind == .archive, dirty else { return }
        try ZipArchive.make(entries).write(to: url, options: .atomic)   // gravação atómica: nunca fica meio-escrito
        dirty = false
    }

    public var paths: [String] {
        if kind == .archive { return entries.keys.sorted() }
        // Caminhos relativos devolvidos pelo próprio sistema (não depende de atalhos como /var -> /private/var).
        let fm = FileManager.default
        guard let walker = fm.enumerator(atPath: url.path) else { return [] }
        var out: [String] = []
        for case let rel as String in walker {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.appendingPathComponent(rel).path, isDirectory: &isDir), !isDir.boolValue { out.append(rel) }
        }
        return out.sorted()
    }

    /// Lê uma entrada sem abrir o contentor inteiro (miniaturas): numa pasta lê o ficheiro, num arquivo só aquela entrada.
    public static func readEntry(_ path: String, at url: URL) -> Data? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        return isDir.boolValue ? try? Data(contentsOf: url.appendingPathComponent(path)) : ZipArchive.readEntry(path, at: url)
    }

    /// Compacta uma captura em pasta num arquivo `.capture` em `destination` (a pasta não é tocada).
    /// Confere o resultado entrada a entrada antes de devolver.
    public static func archive(folder: URL, to destination: URL) throws {
        let src = try CaptureContainer(url: folder)
        var all: [String: Data] = [:]
        for p in src.paths { if let d = src.data(p) { all[p] = d } }
        guard all["document.json"] != nil else { throw CapturePackage.Failure.missingDocument }
        let made = try createArchive(at: destination, entries: all)
        for (p, d) in all where made.data(p) != d {
            try? FileManager.default.removeItem(at: destination)
            throw ZipArchive.Failure.corrupt("verificação falhou em \(p)")
        }
        guard made.paths == all.keys.sorted() else {
            try? FileManager.default.removeItem(at: destination)
            throw ZipArchive.Failure.corrupt("lista de entradas diferente")
        }
    }
}
