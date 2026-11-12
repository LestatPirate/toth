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
    @ObservedObject var index: LibraryIndex = .shared
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
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L("Pesquisar por nome, texto das anotações ou texto da imagem"), text: $state.searchText).textFieldStyle(.plain)
                        .accessibilityIdentifier("library-search")
                    if !state.searchText.isEmpty {
                        Button { state.searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                Picker("", selection: $state.searchDate) { ForEach(LibraryIndex.DateFilter.allCases) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 150)
                if index.pending > 0 {
                    ProgressView().controlSize(.small)
                    Text(L("A reconhecer o texto de %d capturas…", index.pending)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if state.library.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text(L("Ainda não há capturas")).font(.title3)
                    Text(L("Tire uma com %@ ou importe uma imagem.", settings.shortcut.shown)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let shown = index.filter(state.library, query: state.searchText, date: state.searchDate)
                if shown.isEmpty {
                    VStack(spacing: 6) {
                        Text(L("Nenhuma captura bate com a pesquisa")).font(.title3)
                        if index.pending > 0 { Text(L("O texto das imagens ainda está a ser reconhecido.")).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 18) {
                            ForEach(shown) { item in
                                BrowserCell(item: item, state: state, index: index)
                            }
                        }
                        .padding(16)
                    }
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
    @ObservedObject var index: LibraryIndex

    private var title: String { index.title(for: item.url) }

    var body: some View {
        let isCurrent = state.isCurrent(item.url)
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
    nonisolated(unsafe) private static let parser: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    /// Nomes atuais "Toth_2026-10-15_17.43.28[_2]"; também os antigos "Toth 2026-…" e "Capture 2026-…" (com espaços).
    static func title(forFileName name: String) -> String { date(forFileName: name).map(display) ?? name }

    /// A data no nome do ficheiro, se o tiver.
    nonisolated static func date(forFileName name: String) -> Date? {
        for prefix in ["Toth_", "Toth ", "Capture "] where name.hasPrefix(prefix) {
            let stamp = String(name.dropFirst(prefix.count).prefix(19)).replacingOccurrences(of: "_", with: " ")
            if let d = parser.date(from: stamp) { return d }
        }
        return nil
    }

    private static func display(_ d: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .medium; f.locale = Localizer.shared.locale
        return f.string(from: d)
    }
}
