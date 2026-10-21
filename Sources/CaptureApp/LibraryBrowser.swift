// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import SwiftUI
import AppKit
import CaptureCore

/// Biblioteca: grelha com a pré-visualização atual de cada captura (com as anotações). Clicar abre no editor.
struct LibraryBrowser: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: ShortcutSettings = .shared
    @ObservedObject var localizer: Localizer = .shared
    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(L("Capturas")).font(.title3.weight(.semibold))
                Text("\(state.library.count)").foregroundStyle(.secondary)
                Spacer()
                if state.folderCaptureCount > 0 {
                    Button(L("Compactar %d antigas", state.folderCaptureCount)) { state.compactOldCaptures() }
                        .help(L("Junta cada captura antiga (pasta) num só ficheiro .capture. As pastas vão para o Lixo."))
                }
                Button(L("Importar imagem…")) { state.openImages() }
                Button(L("Fechar")) { state.showBrowser = false }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            if state.library.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text(L("Ainda não há capturas")).font(.title3)
                    Text(L("Tire uma com %@ ou importe uma imagem.", settings.shortcut.shown)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(state.library) { item in
                            BrowserCell(item: item, state: state)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 780, idealWidth: 940, minHeight: 540, idealHeight: 660)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct BrowserCell: View {
    let item: LibraryItem
    @ObservedObject var state: AppState

    private var title: String { LibraryNames.title(forFileName: item.url.deletingPathExtension().lastPathComponent) }

    var body: some View {
        let isCurrent = state.model?.url == item.url
        VStack(spacing: 6) {
            ThumbnailView(item: item, revision: state.revision, selected: isCurrent, width: 200, height: 130)
            Text(title).font(.system(size: 11)).lineLimit(1)
            if CaptureContainer.isFolderCapture(item.url) {
                Text(L("formato antigo (pasta)")).font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .contentShape(Rectangle())
        .onTapGesture { state.openFromBrowser(item.url) }
        .contextMenu {
            Button(L("Abrir")) { state.openFromBrowser(item.url) }
            Button(L("Mostrar no Finder")) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button(L("Mover para o Lixo"), role: .destructive) { state.trash(item.url) }
        }
        .help(item.url.lastPathComponent)
    }
}

/// Nome do ficheiro -> título legível (a data da captura, no idioma da app).
@MainActor
enum LibraryNames {
    private static let parser: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    /// Nomes atuais "Toth_2026-10-15_17.43.28[_2]"; também os antigos "Toth 2026-…" e "Capture 2026-…" (com espaços).
    static func title(forFileName name: String) -> String {
        for prefix in ["Toth_", "Toth ", "Capture "] where name.hasPrefix(prefix) {
            let stamp = String(name.dropFirst(prefix.count).prefix(19)).replacingOccurrences(of: "_", with: " ")
            if let d = parser.date(from: stamp) { return display(d) }
        }
        return name
    }

    private static func display(_ d: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .medium; f.locale = Localizer.shared.locale
        return f.string(from: d)
    }
}
