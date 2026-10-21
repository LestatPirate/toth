// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit
import ImageIO
import UniformTypeIdentifiers
import CaptureCore

struct LibraryItem: Identifiable, Equatable {
    let url: URL
    var id: URL { url }
}

/// Estado da janela única: captura aberta + biblioteca (faixa de miniaturas).
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published private(set) var model: EditorModel?
    @Published private(set) var library: [LibraryItem] = []
    /// Muda a cada gravação, para as miniaturas recarregarem.
    @Published private(set) var revision = 0
    /// Faixa de miniaturas na parte de baixo: visível ou escondida (guarda-se entre sessões).
    @Published var showLibraryStrip: Bool = (UserDefaults.standard.object(forKey: "libraryStripVisible") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(showLibraryStrip, forKey: "libraryStripVisible") }
    }
    func toggleLibraryStrip() { showLibraryStrip.toggle() }
    /// Janela da biblioteca (grelha de pré-visualizações).
    @Published var showBrowser = false
    /// Diálogo "Imagem em branco".
    @Published var showNewImage = false
    @Published private(set) var folderCaptureCount = 0
    @Published var errorMessage: String?

    /// Definido pelo AppDelegate: inicia a captura de região.
    var onCapture: (() -> Void)?

    func open(_ url: URL) {
        do {
            let m = try EditorModel(url: url)
            m.onSaved = { [weak self] in self?.revision += 1 }
            model = m
            refreshLibrary()
        } catch {
            errorMessage = L("Não foi possível abrir %@: %@", url.lastPathComponent, error.localizedDescription)
        }
    }

    func refreshLibrary() {
        let items = (try? FileManager.default.contentsOfDirectory(at: CaptureStore.folder, includingPropertiesForKeys: nil)) ?? []
        library = items.filter { $0.pathExtension == "capture" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map(LibraryItem.init)
        folderCaptureCount = library.filter { CaptureContainer.isFolderCapture($0.url) }.count
    }

    /// Envia para o Lixo (recuperável).
    func trash(_ url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        if model?.url == url { model = nil }
        refreshLibrary()
        if model == nil, let first = library.first { open(first.url) }
    }

    /// Cria uma captura nova a partir de uma imagem na área de transferência.
    func pasteAsNewCapture() {
        guard let cg = ClipboardImage.cgImage() else {
            errorMessage = L("Não há nenhuma imagem na área de transferência.")
            return
        }
        do { open(try CaptureStore.save(cg)) } catch { errorMessage = L("Não foi possível criar a captura: %@", error.localizedDescription) }
    }

    /// Cria uma imagem nova do zero e abre-a no editor. Devolve uma mensagem de erro, ou `nil` se correu bem.
    func createBlankImage(width: Int, height: Int, backgroundHex: String, transparent: Bool) -> String? {
        let limits = NewImageForm.limits
        guard limits.contains(width), limits.contains(height), width * height <= NewImageForm.maxPixels else {
            return L("Entre %d e %d pixels de lado (no máximo 100 milhões de pixels no total).", limits.lowerBound, limits.upperBound)
        }
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return L("Não foi possível criar a imagem.")
        }
        if !transparent {
            ctx.setFillColor(NSColor(hex: backgroundHex).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        guard let image = ctx.makeImage() else { return L("Não foi possível criar a imagem.") }
        do {
            open(try CaptureStore.save(image, backgroundHex: backgroundHex, transparentBackground: transparent))
            return nil
        } catch {
            return L("Não foi possível criar a captura: %@", error.localizedDescription)
        }
    }

    /// Mostra a biblioteca: uma grelha com a pré-visualização atual de cada captura, para escolher clicando.
    func openSaved() {
        refreshLibrary()
        showBrowser = true
    }

    /// Escolhe uma captura da biblioteca e abre-a no editor.
    func openFromBrowser(_ url: URL) {
        open(url)
        showBrowser = false
    }

    /// **Abrir**: escolhe imagens de qualquer sítio do computador (ou capturas `.capture`) e abre-as no editor.
    /// Cada imagem solta vira uma captura nova (o ficheiro original não é tocado), por isso as alterações ficam guardadas
    /// e podem exportar-se depois em PNG, JPEG, HEIC ou TIFF.
    func openImages() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true   // capturas antigas são pastas
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, UTType(filenameExtension: "capture") ?? .data]
        panel.message = L("Escolha imagens ou capturas (.capture) para abrir no editor")
        guard panel.runModal() == .OK else { return }
        open(urls: panel.urls)
    }

    /// Abre ficheiros: capturas `.capture` abrem-se; imagens importam-se como captura nova. Também usado quando o macOS
    /// entrega ficheiros à app (duplo clique num `.capture`, "Abrir com" Toth, arrastar para o ícone do Dock).
    func open(urls: [URL]) {
        var skipped: [String] = []
        for url in urls {
            if url.pathExtension.lowercased() == "capture" {
                open(url)
            } else if let img = ImageFiles.load(url) {
                do { open(try CaptureStore.save(img)) } catch { skipped.append(url.lastPathComponent) }
            } else {
                skipped.append(url.lastPathComponent)
            }
        }
        if !skipped.isEmpty { errorMessage = L("Não foi possível abrir: %@", skipped.joined(separator: ", ")) }
        else { showBrowser = false }
    }

    /// Compacta as capturas antigas (pastas) em arquivos únicos `.capture`. Para cada uma: cria o arquivo ao lado,
    /// confere-o entrada a entrada e só então move a pasta para o Lixo (recuperável) e põe o arquivo no lugar.
    func compactOldCaptures() {
        let folders = library.map(\.url).filter(CaptureContainer.isFolderCapture)
        guard !folders.isEmpty else { return }
        let reopen = model?.url
        if let r = reopen, folders.contains(r) { model = nil }   // a captura aberta vai mudar de formato
        let fm = FileManager.default
        var done = 0
        var failed: [String] = []
        for folder in folders {
            let tmp = folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + ".tmp")
            do {
                try? fm.removeItem(at: tmp)
                try CaptureContainer.archive(folder: folder, to: tmp)
                try fm.trashItem(at: folder, resultingItemURL: nil)
                try fm.moveItem(at: tmp, to: folder)
                done += 1
            } catch {
                try? fm.removeItem(at: tmp)
                failed.append(folder.deletingPathExtension().lastPathComponent)
            }
        }
        refreshLibrary()
        if let r = reopen, fm.fileExists(atPath: r.path) { open(r) }
        var msg = done == 1 ? L("1 captura compactada num só ficheiro.") : L("%d capturas compactadas, cada uma num só ficheiro.", done)
        if done > 0 { msg += L(" As pastas originais estão no Lixo, caso queira recuperá-las.") }
        if !failed.isEmpty { msg += L(" Falharam (ficaram como estavam): %@.", failed.joined(separator: ", ")) }
        errorMessage = msg
    }
}
