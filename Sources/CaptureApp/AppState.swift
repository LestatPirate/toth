// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit
import ImageIO
import UniformTypeIdentifiers
import CaptureCore

struct LibraryItem: Identifiable, Equatable {
    let url: URL
    var id: URL { url }
    var isVideo: Bool { VideoFiles.isVideo(url) }
}

/// Estado da janela única: captura aberta + biblioteca (faixa de miniaturas).
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published private(set) var model: EditorModel?
    /// Vídeo aberto no editor (em vez de uma imagem): o leitor ocupa a área de trabalho.
    @Published private(set) var videoURL: URL?
    /// A captura (imagem ou vídeo) que está aberta é esta?
    func isCurrent(_ url: URL) -> Bool { model?.url == url || videoURL == url }
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
        if VideoFiles.isVideo(url) { openVideo(url); return }
        do {
            let m = try EditorModel(url: url)
            m.onSaved = { [weak self] in self?.revision += 1; LibraryIndex.shared.reload(url) }
            model = m
            videoURL = nil
            refreshLibrary()
        } catch {
            errorMessage = L("Não foi possível abrir %@: %@", url.lastPathComponent, error.localizedDescription)
        }
    }

    /// Abre um vídeo (MP4, MOV, M4V) na área de trabalho do editor.
    func openVideo(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = L("Não foi possível abrir %@: %@", url.lastPathComponent, L("o ficheiro não existe"))
            return
        }
        model = nil
        videoURL = url
        refreshLibrary()
    }

    func refreshLibrary() {
        let items = (try? FileManager.default.contentsOfDirectory(at: CaptureStore.folder, includingPropertiesForKeys: nil)) ?? []
        library = items.filter { $0.pathExtension == "capture" || VideoFiles.isVideo($0) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map(LibraryItem.init)
        folderCaptureCount = library.filter { CaptureContainer.isFolderCapture($0.url) }.count
        LibraryIndex.shared.openURL = { [weak self] in self?.model?.url }
        if showBrowser { LibraryIndex.shared.sync(library) }
    }

    /// Texto e data da pesquisa na biblioteca.
    @Published var searchText = ""
    @Published var searchDate: LibraryIndex.DateFilter = .all
    func openBrowser() { showBrowser = true; LibraryIndex.shared.sync(library) }

    // MARK: Faixa de baixo (só as mais recentes)

    /// Quantas capturas a faixa de baixo mostra (as mais recentes); o resto está em «Abrir Biblioteca».
    static let stripLimit = 20
    /// As capturas da faixa: as `stripLimit` mais recentes que não foram ocultadas e, se for mais antiga, também a que está aberta.
    var stripItems: [LibraryItem] {
        var items = Array(library.filter { !isHiddenFromStrip($0.url) }.prefix(Self.stripLimit))
        if let open = library.first(where: { isCurrent($0.url) }), !items.contains(open) { items.append(open) }
        return items
    }

    // MARK: Ocultar da faixa (fica na biblioteca)

    private static let hiddenKey = "stripHidden"
    /// Nomes dos ficheiros ocultados da faixa de baixo (continuam na biblioteca).
    @Published private(set) var hiddenFromStrip: Set<String> = Set(UserDefaults.standard.stringArray(forKey: AppState.hiddenKey) ?? [])
    func isHiddenFromStrip(_ url: URL) -> Bool { hiddenFromStrip.contains(url.lastPathComponent) }
    func setHiddenFromStrip(_ url: URL, _ hidden: Bool) {
        if hidden { hiddenFromStrip.insert(url.lastPathComponent) } else { hiddenFromStrip.remove(url.lastPathComponent) }
        UserDefaults.standard.set(Array(hiddenFromStrip).sorted(), forKey: Self.hiddenKey)
    }

    /// Miniatura da faixa em que se clicou por último: Backspace/Delete envia-a para o Lixo. Limpa-se ao clicar noutro
    /// sítio ou ao premir outra tecla, para o Backspace nunca apagar uma captura por engano.
    @Published var stripSelection: URL?
    private var stripMonitor: Any?

    /// Clicou-se numa miniatura da faixa: abre-a e fica marcada para o Backspace.
    func selectInStrip(_ url: URL) {
        open(url)
        stripSelection = isCurrent(url) ? url : nil
        installStripMonitor()
    }

    /// Backspace/Delete com uma miniatura marcada: vai para o Lixo. Devolve `true` se apagou.
    @discardableResult
    func deleteStripSelection() -> Bool {
        guard let url = stripSelection else { return false }
        stripSelection = nil
        trash(url)
        return true
    }

    private func installStripMonitor() {
        guard stripMonitor == nil else { return }
        stripMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { event in
            MainActor.assumeIsolated {
                let state = AppState.shared
                guard state.stripSelection != nil else { return event }
                // qualquer clique desmarca (clicar numa miniatura volta a marcar, ao soltar)
                guard event.type == .keyDown else { state.stripSelection = nil; return event }
                let isDelete = (event.keyCode == 51 || event.keyCode == 117) && event.modifierFlags.intersection([.command, .option, .control]).isEmpty
                let typing = event.window?.firstResponder is NSText
                guard isDelete, !typing, event.window?.attachedSheet == nil else { state.stripSelection = nil; return event }
                state.deleteStripSelection()
                return nil   // consumido: não apaga também um elemento da imagem
            }
        }
    }

    // MARK: Pasta das capturas

    /// Muda a pasta das capturas, movendo para lá tudo o que é do Toth; a captura aberta reabre no sítio novo.
    /// Devolve a mensagem a mostrar ao utilizador.
    @discardableResult
    func changeCaptureFolder(to newFolder: URL) -> String {
        let openName = model?.url.lastPathComponent ?? videoURL?.lastPathComponent
        model = nil; videoURL = nil   // fecha o que está aberto (o ficheiro vai mudar de sítio)
        let r = CaptureStore.changeFolder(to: newFolder)
        StampLibrary.shared.reload()
        refreshLibrary()
        if let name = openName, let again = library.first(where: { $0.url.lastPathComponent == name }) { open(again.url) }
        else if let first = library.first { open(first.url) }
        var msg = r.moved == 1 ? L("1 item movido para %@.", CaptureStore.shortPath(CaptureStore.folder)) : L("%d itens movidos para %@.", r.moved, CaptureStore.shortPath(CaptureStore.folder))
        if !r.failed.isEmpty { msg += " " + L("Ficaram na pasta antiga (já existia um com o mesmo nome no destino): %@.", r.failed.joined(separator: ", ")) }
        errorMessage = msg
        return msg
    }

    /// Envia para o Lixo (recuperável).
    func trash(_ url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        if VideoFiles.isRawVideo(url) { try? FileManager.default.removeItem(at: url.appendingPathExtension("edicao")) }
        setHiddenFromStrip(url, false)
        if model?.url == url { model = nil }
        if videoURL == url { videoURL = nil }
        refreshLibrary()
        if model == nil, videoURL == nil, let first = library.first { open(first.url) }
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

    /// «Salvar como» para um vídeo: copia o ficheiro de vídeo (o de dentro do pacote) para onde o utilizador escolher.
    func saveVideoAs(_ url: URL) {
        guard let media = VideoFiles.mediaURL(url) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + "." + media.pathExtension
        panel.allowedContentTypes = [UTType(filenameExtension: media.pathExtension) ?? .mpeg4Movie]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: media, to: dest)
        } catch { errorMessage = L("Não foi possível guardar o vídeo: %@", error.localizedDescription) }
    }

    /// Mostra a biblioteca: uma grelha com a pré-visualização atual de cada captura, para escolher clicando.
    func openSaved() {
        refreshLibrary()
        openBrowser()
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
        panel.allowedContentTypes = [.image, .movie, UTType(filenameExtension: "capture") ?? .data]
        panel.message = L("Escolha imagens, vídeos ou capturas (.capture) para abrir no editor")
        guard panel.runModal() == .OK else { return }
        open(urls: panel.urls)
    }

    /// Abre ficheiros: capturas `.capture` e pacotes `.tothvideo` abrem-se; imagens e vídeos de fora da biblioteca
    /// importam-se (cópia) como captura ou pacote novo, sem tocar no original. Também usado quando o macOS entrega
    /// ficheiros à app (duplo clique, "Abrir com" Toth, arrastar para o ícone do Dock).
    func open(urls: [URL]) {
        var skipped: [String] = []
        let lib = CaptureStore.folder.standardizedFileURL.resolvingSymlinksInPath().path
        for url in urls {
            let inLibrary = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path == lib
            if url.pathExtension.lowercased() == "capture" || VideoFiles.isPackage(url) || (VideoFiles.isRawVideo(url) && inLibrary) {
                open(url)
            } else if VideoFiles.isRawVideo(url) {
                do { open(try VideoFiles.makePackage(from: url, move: false)) } catch { skipped.append(url.lastPathComponent) }
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
