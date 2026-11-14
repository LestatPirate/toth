// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit
import CaptureCore

enum CaptureStore {
    /// Só para testes (`--library <pasta>`): usa outra pasta em vez da pasta das capturas.
    nonisolated(unsafe) static var overrideFolder: URL?

    /// Pasta por omissão: `~/Pictures/TothCapture`.
    static var defaultFolder: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("TothCapture", isDirectory: true)
    }
    /// Pasta antiga (versões até à 0.6.0): `~/Pictures/Capture`. O conteúdo é migrado na primeira abertura.
    static var legacyFolder: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("Capture", isDirectory: true)
    }
    /// Pasta antiga dos carimbos importados (até à 0.6.0): `~/Library/Application Support/Toth/Stamps`.
    static var legacyStampsFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Toth/Stamps", isDirectory: true)
    }
    /// Nome da subpasta dos carimbos importados dentro da pasta das capturas.
    static let stampsSubfolder = "Carimbos"

    private static let customKey = "captureFolder"
    /// Pasta escolhida pelo utilizador (Preferências); `nil` = a pasta por omissão.
    static var customFolder: URL? {
        get { UserDefaults.standard.string(forKey: customKey).map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set { if let p = newValue?.path { UserDefaults.standard.set(p, forKey: customKey) } else { UserDefaults.standard.removeObject(forKey: customKey) } }
    }

    /// A pasta das capturas e vídeos (criada se não existir).
    static var folder: URL {
        let url = overrideFolder ?? customFolder ?? defaultFolder
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Pasta dos carimbos importados: subpasta da pasta das capturas (migra com ela).
    static var stampsFolder: URL { folder.appendingPathComponent(stampsSubfolder, isDirectory: true) }

    /// Caminho para mostrar (`~/Pictures/TothCapture`).
    static func shortPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }

    // MARK: Migração

    /// O que pertence ao Toth dentro de uma pasta: capturas (`.capture`, ficheiro ou pasta antiga), vídeos e as suas
    /// pastas de edição (`.edicao`), e a subpasta dos carimbos. Mais nada é tocado.
    static func ownedItems(in dir: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return items.filter { u in
            let ext = u.pathExtension.lowercased()
            return ext == "capture" || ext == "edicao" || ext == VideoFiles.packageExtension || VideoFiles.isVideo(u) || u.lastPathComponent == stampsSubfolder
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    struct MigrationResult { var moved = 0; var failed: [String] = []; var removedOld = false }

    /// Move o que é do Toth de `from` para `to` (ficheiro a ficheiro, confirmando cada um no destino). Nada é apagado
    /// sem a cópia estar no sítio; se já existir um ficheiro com o mesmo nome no destino, esse fica onde está e é
    /// reportado. No fim, se a pasta antiga ficou sem nada (além de ficheiros escondidos), é removida.
    @discardableResult
    static func moveContents(from: URL, to: URL, removeEmptyOld: Bool = true) -> MigrationResult {
        var r = MigrationResult()
        let fm = FileManager.default
        guard from.standardizedFileURL != to.standardizedFileURL, fm.fileExists(atPath: from.path) else { return r }
        try? fm.createDirectory(at: to, withIntermediateDirectories: true)
        for item in ownedItems(in: from) {
            let dest = to.appendingPathComponent(item.lastPathComponent)
            if item.lastPathComponent == stampsSubfolder, fm.fileExists(atPath: dest.path) {
                // carimbos: juntam-se aos que já lá estejam
                let sub = moveContents(from: item, to: dest, removeEmptyOld: true)
                r.moved += sub.moved; r.failed += sub.failed
                continue
            }
            if fm.fileExists(atPath: dest.path) { r.failed.append(item.lastPathComponent); continue }
            do {
                try fm.moveItem(at: item, to: dest)   // entre volumes o sistema copia e só depois apaga a origem
                if fm.fileExists(atPath: dest.path) { r.moved += 1 } else { r.failed.append(item.lastPathComponent) }
            } catch { r.failed.append(item.lastPathComponent) }
        }
        if removeEmptyOld { r.removedOld = removeIfEmpty(from) }
        return r
    }

    /// Carimbos PNG soltos (pasta antiga em Application Support) para a subpasta dos carimbos.
    @discardableResult
    static func moveStampFiles(from: URL, to: URL) -> MigrationResult {
        var r = MigrationResult()
        let fm = FileManager.default
        guard from.standardizedFileURL != to.standardizedFileURL, fm.fileExists(atPath: from.path) else { return r }
        try? fm.createDirectory(at: to, withIntermediateDirectories: true)
        let items = (try? fm.contentsOfDirectory(at: from, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for item in items where item.pathExtension.lowercased() == "png" {
            let dest = to.appendingPathComponent(item.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { r.failed.append(item.lastPathComponent); continue }
            do { try fm.moveItem(at: item, to: dest); r.moved += 1 } catch { r.failed.append(item.lastPathComponent) }
        }
        r.removedOld = removeIfEmpty(from)
        return r
    }

    /// Apaga a pasta se só tiver ficheiros escondidos (`.DS_Store`). Devolve `true` se a removeu.
    static func removeIfEmpty(_ dir: URL) -> Bool {
        let fm = FileManager.default
        guard let all = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return false }
        guard all.allSatisfy({ $0.lastPathComponent.hasPrefix(".") }) else { return false }
        for h in all { try? fm.removeItem(at: h) }
        return (try? fm.removeItem(at: dir)) != nil
    }

    /// Primeira abertura depois da mudança de nome: `~/Pictures/Capture` → `~/Pictures/TothCapture` e os carimbos de
    /// Application Support para a subpasta «Carimbos». Só corre sem pasta personalizada e sem pasta de teste.
    static func migrateLegacyIfNeeded() {
        guard overrideFolder == nil else { return }
        let fm = FileManager.default
        if customFolder == nil, fm.fileExists(atPath: legacyFolder.path), !ownedItems(in: legacyFolder).isEmpty {
            moveContents(from: legacyFolder, to: defaultFolder)
        }
        if fm.fileExists(atPath: legacyStampsFolder.path) {
            moveStampFiles(from: legacyStampsFolder, to: stampsFolder)
            _ = removeIfEmpty(legacyStampsFolder.deletingLastPathComponent())   // «Toth/» em Application Support, se ficou vazia
        }
        // Até à 0.6.1 os vídeos eram ficheiros soltos com a edição numa pasta `.edicao` ao lado: passam a pacotes `.tothvideo`.
        VideoFiles.migrateLoose(in: folder)
    }

    /// Muda a pasta das capturas para `newFolder`, movendo para lá tudo o que é do Toth (capturas, vídeos, edições,
    /// carimbos). A preferência só muda depois de mover. Devolve o resultado; `failed` lista o que ficou na pasta antiga.
    static func changeFolder(to newFolder: URL) -> MigrationResult {
        let old = folder
        let dest = newFolder.standardizedFileURL
        guard dest != old.standardizedFileURL else { return MigrationResult() }
        let r = moveContents(from: old, to: dest)
        customFolder = dest == defaultFolder.standardizedFileURL ? nil : dest
        return r
    }

    // MARK: Guardar

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
