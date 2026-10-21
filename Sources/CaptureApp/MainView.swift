// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import SwiftUI
import AppKit
import CaptureCore

struct MainView: View {
    @ObservedObject var state: AppState
    @ObservedObject var localizer: Localizer = .shared
    @ObservedObject var panel: PanelLayout = .shared

    var body: some View {
        VStack(spacing: 0) {
            TopBar(state: state)
            Divider()
            HStack(spacing: 0) {
                if let model = state.model {
                    CanvasRepresentable(model: model).id(model.url)
                        .frame(minWidth: 160, maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
                        .clipped()   // a área de trabalho nunca desenha fora do seu espaço (nem por cima da barra de ferramentas)
                    PanelDivider(layout: panel)
                    if panel.isVisible {
                        PropertiesPanel(model: model).frame(width: panel.width)
                    }
                } else {
                    EmptyState(state: state)
                }
            }
            Divider()
            FooterBar(state: state)
            if state.showLibraryStrip {
                Divider()
                LibraryStrip(state: state)
            }
        }
        .id(localizer.language)   // reconstrói a interface ao mudar o idioma
        .sheet(isPresented: $state.showBrowser) { LibraryBrowser(state: state) }
        .sheet(isPresented: $state.showNewImage) { NewImageSheet(state: state) }
        .alert("Toth", isPresented: Binding(get: { state.errorMessage != nil }, set: { if !$0 { state.errorMessage = nil } })) {
            Button("OK") { state.errorMessage = nil }
        } message: { Text(state.errorMessage ?? "") }
    }
}

// MARK: - Barra superior

private struct TopBar: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            BarButton(symbol: "camera.viewfinder", label: L("Capturar"), tint: .red) { state.onCapture?() }
            BarMenu(symbol: "plus.square", label: L("Novo"), items: [
                (L("Imagem em branco…"), { state.showNewImage = true }),
                (L("Da área de transferência"), { state.pasteAsNewCapture() }),
            ])
            BarButton(symbol: "folder", label: L("Abrir")) { state.openImages() }
            BarButton(symbol: "square.and.arrow.down", label: L("Salvar como"), disabled: state.model == nil) { state.model?.exportToFile() }
            if let model = state.model { ToolsBar(model: model) } else { Spacer(minLength: 0) }
            if let model = state.model { RightActions(model: model) }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.bar)
    }
}

struct BarButton: View {
    let symbol: String
    let label: String
    var tint: Color? = nil
    var selected = false
    var disabled = false
    /// Largura fixa do botão (as ferramentas têm todas a mesma, para o deslize da barra ser exato).
    var fixedWidth: CGFloat? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 18)).frame(height: 22)
                    .foregroundStyle(tint ?? (selected ? Color.accentColor : Color.primary))
                Text(label).font(.system(size: 10)).lineLimit(1).minimumScaleFactor(fixedWidth == nil ? 1 : 0.75)
                    .fixedSize(horizontal: fixedWidth == nil, vertical: true)
            }
            .frame(minWidth: fixedWidth ?? 56, maxWidth: fixedWidth).padding(.vertical, 4).padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.15) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled).opacity(disabled ? 0.35 : 1)
    }
}

/// Guarda a ação de um item de menu do sistema.
final class MenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

/// Como `BarButton` (mesmo aspeto e alinhamento), mas abre um menu do sistema junto ao rato.
struct BarMenu: View {
    let symbol: String
    let label: String
    let items: [(title: String, action: () -> Void)]

    var body: some View {
        BarButton(symbol: symbol, label: label) { show() }
    }

    private func show() {
        let menu = NSMenu()
        for item in items {
            let action = MenuAction(item.action)
            let entry = NSMenuItem(title: item.title, action: #selector(MenuAction.fire), keyEquivalent: "")
            entry.target = action
            entry.representedObject = action   // mantém a ação viva enquanto o menu existir
            menu.addItem(entry)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

private struct RightActions: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        HStack(spacing: 4) {
            BarButton(symbol: "arrow.uturn.backward", label: L("Desfazer"), disabled: !model.canUndo) { model.undo() }
            BarButton(symbol: "arrow.uturn.forward", label: L("Refazer"), disabled: !model.canRedo) { model.redo() }
            BarButton(symbol: "doc.on.doc", label: L("Copiar tudo")) { model.copyToPasteboard() }
            BarButton(symbol: "doc.on.clipboard", label: L("Colar")) { model.paste() }
        }
    }
}

// MARK: - Estado vazio

private struct EmptyState: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: ShortcutSettings = .shared
    var body: some View {
        VStack(spacing: 12) {
            LogoView(size: 110)
            Text(L("Nenhuma captura aberta")).font(.title3)
            Text(L("Carregue em %@ ou escolha uma captura na faixa abaixo.", settings.shortcut.shown)).foregroundStyle(.secondary)
            HStack {
                Button(L("Capturar")) { state.onCapture?() }.buttonStyle(.borderedProminent)
                Button(L("Imagem em branco…")) { state.showNewImage = true }
                Button(L("Da área de transferência")) { state.pasteAsNewCapture() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

// MARK: - Rodapé

private struct FooterBar: View {
    @ObservedObject var state: AppState
    var body: some View {
        ZStack {
            HStack { Spacer(); if let model = state.model { ZoomControls(model: model) }; Spacer() }
            HStack {
                Spacer()
                // mostrar/ocultar a biblioteca (faixa de miniaturas)
                Button { withAnimation(.easeInOut(duration: 0.2)) { state.toggleLibraryStrip() } } label: {
                    HStack(spacing: 4) {
                        Image(systemName: state.showLibraryStrip ? "chevron.down" : "chevron.up").font(.system(size: 10, weight: .bold))
                        Text(L("Biblioteca")).font(.system(size: 12))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(state.showLibraryStrip ? L("Ocultar a biblioteca") : L("Mostrar a biblioteca"))
            }
        }
        .padding(.horizontal, 12).frame(height: 30)
        .background(.bar)
    }
}

private struct ZoomControls: View {
    @ObservedObject var model: EditorModel

    private var size: String {
        let a = model.doc.area
        return "\(Int(a.width.rounded())) × \(Int(a.height.rounded()))"
    }

    var body: some View {
        HStack(spacing: 8) {
            Button { model.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }.help(L("Reduzir"))
            Text("\(Int((model.zoom ?? model.fitScale) * 100))%").monospacedDigit().frame(minWidth: 48)
            Button { model.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }.help(L("Ampliar"))
            Button("1:1") { model.zoomActual() }.help(L("Tamanho real (100%)"))
            Button(L("Ajustar")) { model.zoomFit() }
            Text("·").foregroundStyle(.secondary)
            Text(size).monospacedDigit().foregroundStyle(.secondary)
        }
        .buttonStyle(.plain).font(.system(size: 12))
    }
}

// MARK: - Faixa de miniaturas

private struct LibraryStrip: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(state.library) { item in
                        ThumbnailView(item: item, revision: state.revision, selected: state.model?.url == item.url)
                            .onTapGesture { state.open(item.url) }
                            .contextMenu {
                                Button(L("Mostrar no Finder")) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                                Button(L("Mover para o Lixo"), role: .destructive) { state.trash(item.url) }
                            }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            Divider()
            // Fixo à direita: abre imagens guardadas no editor.
            Button { state.openSaved() } label: {
                VStack(spacing: 4) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 22))
                    Text(L("Abrir Biblioteca")).font(.system(size: 11))
                }
                .frame(width: 96, height: 70)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .help(L("Abrir a biblioteca de capturas"))
        }
        .frame(height: 92)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Carrega a miniatura fora da thread principal. (Sem @State: o plugin de macros do SwiftUI não existe só com as Command Line Tools.)
@MainActor
final class ThumbLoader: ObservableObject {
    @Published var image: NSImage?
    private var loadedKey: String?

    func load(_ url: URL, key: String) {
        guard key != loadedKey else { return }
        loadedKey = key
        Task.detached(priority: .utility) {
            let img = Thumbnails.load(url)
            await MainActor.run { [weak self] in self?.image = img }
        }
    }
}

struct ThumbnailView: View {
    let item: LibraryItem
    let revision: Int
    let selected: Bool
    var width: CGFloat = 104
    var height: CGFloat = 70
    @StateObject private var loader = ThumbLoader()

    var body: some View {
        let key = "\(item.url.path)-\(selected ? revision : 0)"
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .controlBackgroundColor))
            if let image = loader.image {
                Image(nsImage: image).resizable().scaledToFit().padding(2)
            }
        }
        .frame(width: width, height: height)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: selected ? 2.5 : 1))
        .onAppear { loader.load(item.url, key: key) }
        .onChange(of: key) { _, new in loader.load(item.url, key: new) }
        .help(item.url.deletingPathExtension().lastPathComponent)
    }
}
