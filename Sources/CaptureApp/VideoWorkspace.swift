// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AVFoundation
import AVKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Vídeo aberto no editor: o leitor ocupa a área de trabalho, com os controlos de reprodução. (A edição do vídeo vem depois.)
enum VideoFiles {
    static let extensions: Set<String> = ["mp4", "mov", "m4v"]
    static func isVideo(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }
}

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .none          // os controlos são os da linha de tempo do Toth (tempo do vídeo editado)
        v.showsFullScreenToggleButton = false
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) { if v.player !== player { v.player = player } }
}

/// Abre um menu do sistema junto ao rato (para os botões da barra do vídeo que têm várias opções).
private func popUpMenu(_ items: [(title: String, checked: Bool, enabled: Bool, action: (() -> Void)?)]) {
    let menu = NSMenu()
    for item in items {
        if item.title == "-" { menu.addItem(.separator()); continue }
        let entry = NSMenuItem(title: item.title, action: item.action == nil ? nil : #selector(MenuAction.fire), keyEquivalent: "")
        if let a = item.action { let ma = MenuAction(a); entry.target = ma; entry.representedObject = ma }
        entry.state = item.checked ? .on : .off
        entry.isEnabled = item.enabled
        menu.addItem(entry)
    }
    menu.autoenablesItems = false
    menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
}

/// Um botão só com ícone para a barra do vídeo.
private struct VideoIconButton: View {
    let symbol: String
    let help: String
    var prominent = false
    var disabled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).frame(width: 30, height: 26)
                .foregroundStyle(prominent && !disabled ? Color.white : Color.primary)
                .background(RoundedRectangle(cornerRadius: 6).fill(prominent && !disabled ? Color.accentColor : Color.clear))
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .help(help)
    }
}

/// O vídeo no editor: leitor, barra de edição e linha de tempo com uma linha por faixa. Marca-se um trecho na linha de tempo
/// (o leitor mostra o ponto exato da ponta que se move), e cortam-se, copiam-se, colam-se ou invertem-se esse trecho nas
/// linhas escolhidas. O que sobra pode juntar-se (toca seguido) ou ficar com um espaço.
/// A barra da «Tela» do vídeo (sob o leitor, só no modo de enquadramento): largura, altura, manter proporção, rotação,
/// atalhos de escala e voltar ao natural. Os mesmos valores que as alças mudam com o rato.
private final class OutputFields: ObservableObject {
    @Published var width = 0.0
    @Published var height = 0.0
    @Published var rotation = 0.0
}

private struct OutputFrameBar: View {
    @ObservedObject var model: VideoEditorModel
    @ObservedObject var fields: OutputFields

    private func sync() { fields.width = model.effectiveOutputSize.width; fields.height = model.effectiveOutputSize.height; fields.rotation = model.outputRotation }
    private func field(_ title: String, _ value: Binding<Double>, unit: String, width: CGFloat = 64, apply: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 4) { Text(title).font(.system(size: 11)).fixedSize()
            TextField("", value: value, format: .number.precision(.fractionLength(0...1))).frame(width: width).multilineTextAlignment(.trailing).font(.system(size: 11))
                .onSubmit { apply(value.wrappedValue) }
            Text(unit).font(.caption2).foregroundStyle(.secondary) }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "aspectratio").foregroundStyle(Color.accentColor)
            field(L("Largura"), $fields.width, unit: "px") { v in Task { await model.setOutputSize(width: v); sync() } }
            field(L("Altura"), $fields.height, unit: "px") { v in Task { await model.setOutputSize(height: v); sync() } }
            Toggle(L("Manter proporção"), isOn: $model.outputKeepAspect).font(.system(size: 11)).toggleStyle(.checkbox)
            Divider().frame(height: 16)
            field(L("Rotação"), $fields.rotation, unit: "°", width: 50) { v in Task { await model.setOutputRotation(v); sync() } }
            Button { Task { await model.rotateOutput(by: -90); sync() } } label: { Image(systemName: "rotate.left") }.help(L("Rodar 90° para a esquerda"))
            Button { Task { await model.rotateOutput(by: 90); sync() } } label: { Image(systemName: "rotate.right") }.help(L("Rodar 90° para a direita"))
            Divider().frame(height: 16)
            ForEach([25, 50, 75], id: \.self) { k in Button("\(k)%") { Task { await model.setOutputScale(Double(k) / 100); sync() } } }
            Button(L("Original")) { Task { await model.resetOutputSize(); sync() } }.disabled(!model.isOutputTransformed)
            Spacer()
            Text(L("Saída: %@", "\(Int(model.canvasSize.width)) × \(Int(model.canvasSize.height))")).font(.system(size: 11)).foregroundStyle(.secondary)
            Button(L("Concluído")) { model.frameMode = false }.keyboardShortcut(.return, modifiers: [])
        }
        .controlSize(.small)
        .padding(.horizontal, 10).frame(height: 30)
        .background(.bar)
        .onAppear(perform: sync)
        .onChange(of: model.outputSize) { _, _ in sync() }
        .onChange(of: model.outputRotation) { _, _ in sync() }
    }
}

/// Barra do modo Anotar (sob o editor): início e fim da anotação selecionada, «Seguir» e «Concluído».
private final class OverlayFields: ObservableObject { @Published var start = 0.0; @Published var end = 0.0 }

private struct OverlayTimeBar: View {
    @ObservedObject var model: VideoEditorModel
    @ObservedObject var editor: EditorModel
    @ObservedObject var fields: OverlayFields

    private var current: VideoOverlay? { editor.selection.flatMap { model.overlay(for: $0) } }
    private func sync() { if let o = current { fields.start = (o.start * 100).rounded() / 100; fields.end = (o.end * 100).rounded() / 100 } }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil.and.outline").foregroundStyle(Color.purple)
            if let o = current {
                Text(L("Início")).font(.system(size: 11))
                TextField("", value: $fields.start, format: .number.precision(.fractionLength(0...2))).frame(width: 60).font(.system(size: 11)).multilineTextAlignment(.trailing)
                    .onSubmit { model.setOverlayRange(o.id, start: fields.start); sync() }
                Button(L("= agora")) { model.setOverlayRange(o.id, start: model.playhead); sync() }.help(L("O início passa a ser a posição de reprodução"))
                Text(L("Fim")).font(.system(size: 11))
                TextField("", value: $fields.end, format: .number.precision(.fractionLength(0...2))).frame(width: 60).font(.system(size: 11)).multilineTextAlignment(.trailing)
                    .onSubmit { model.setOverlayRange(o.id, end: fields.end); sync() }
                Button(L("= agora")) { model.setOverlayRange(o.id, end: model.playhead); sync() }.help(L("O fim passa a ser a posição de reprodução"))
                Text(L("(%@ s)", String(format: "%.2f", o.length))).font(.system(size: 11)).foregroundStyle(.secondary)
                Divider().frame(height: 16)
                if o.endOffset != nil {
                    Button(L("Deixar de seguir")) { model.setOverlayFollow(o.id, clear: true) }.help(L("A anotação volta a ficar parada"))
                } else {
                    Button(L("Seguir")) { model.setOverlayFollow(o.id) }
                        .help(L("Para a anotação acompanhar algo que se move: ponha a reprodução perto do fim da anotação, arraste o elemento para onde deve estar nesse instante e carregue aqui. Ela desloca-se em linha reta do início ao fim."))
                }
                Button(L("Apagar")) { model.deleteOverlay(o.id) }
            } else {
                Text(L("Desenhe sobre o fotograma com qualquer ferramenta: a anotação começa na posição de reprodução e dura 3 s. Arraste a linha vermelha para mudar o fotograma; os blocos na linha «Anotações» ajustam o início e o fim.")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button(L("Concluído")) { model.annotateMode = false }.keyboardShortcut(.return, modifiers: [.command])
        }
        .controlSize(.small)
        .padding(.horizontal, 10).frame(height: 30)
        .background(.bar)
        .onAppear(perform: sync)
        .onChange(of: editor.selection) { _, _ in sync() }
        .onChange(of: model.overlays) { _, _ in sync() }
    }
}

struct VideoWorkspace: View {
    @StateObject private var model: VideoEditorModel
    @ObservedObject private var state = AppState.shared
    @StateObject private var outputFields = OutputFields()
    @StateObject private var overlayFields = OverlayFields()

    init(url: URL) { _model = StateObject(wrappedValue: VideoEditorModel(url: url)) }
    init(model: VideoEditorModel) { _model = StateObject(wrappedValue: model) }

    private var totalText: String { TimelineNSView.format(model.duration) }

    private func saveAs(ext: String, type: UTType, _ work: @escaping (URL) async throws -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = model.url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_editado", with: "") + "." + ext
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { do { try await work(url) } catch { state.errorMessage = L("Não foi possível guardar: %@", error.localizedDescription) } }
    }

    private func importAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.message = L("Escolha um ficheiro de áudio (MP3, M4A, WAV, AIFF…) para pôr na linha «Música», a começar na posição de reprodução")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.importAudio(url) }
    }

    private func perform(_ a: TimelineNSView.Action) {
        switch a {
        case .cutJoin: Task { await model.cut(join: true) }
        case .cutGap: Task { await model.cut(join: false) }
        case .insertBreak: Task { await model.insertBreak() }
        case .copy: model.copySelection()
        case .paste: Task { await model.paste(insert: true) }
        case .pasteOver: Task { await model.paste(insert: false) }
        case .reverse: Task { await model.reverseSelection() }
        case .togglePlay: model.togglePlay()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.annotateMode, let editor = model.overlayEditor {
                // modo Anotar: o editor de imagem sobre o fotograma atual (ferramentas, tela, propriedades)
                HStack(alignment: .top, spacing: 4) {
                    ToolsBar(model: editor)
                    BarButton(symbol: "arrow.uturn.backward", label: L("Desfazer"), disabled: !editor.canUndo) { editor.undo() }
                    BarButton(symbol: "arrow.uturn.forward", label: L("Refazer"), disabled: !editor.canRedo) { editor.redo() }
                }
                .padding(.horizontal, 10).padding(.vertical, 4).background(.bar)
                Divider()
                HStack(spacing: 0) {
                    CanvasRepresentable(model: editor).id(editor.url)
                        .frame(minWidth: 160, maxWidth: .infinity, minHeight: 120, maxHeight: .infinity).clipped()
                    Divider()
                    PropertiesPanel(model: editor).frame(width: 290)
                }
                .overlay { if let w = model.working { ProgressView(w).padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)) } }
                OverlayTimeBar(model: model, editor: editor, fields: overlayFields)
            } else {
            PlayerView(player: model.player)
                .padding(model.frameMode ? VideoFrameOverlayView.inset : 0)   // na Tela, uma margem para trabalhar à volta do vídeo
                .background(Color.black)
                .frame(minWidth: 160, maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    if let label = model.previewLabel {
                        Text(label).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6)).padding(10)
                    }
                }
                .overlay { if model.frameMode { VideoFrameOverlay(model: model) } }
                .overlay { if let w = model.working { ProgressView(w).padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)) } }
                .onTapGesture { if !model.frameMode { model.togglePlay() } }
            if model.frameMode { OutputFrameBar(model: model, fields: outputFields) }
            }
            Divider()
            HStack(spacing: 4) {
                VideoIconButton(symbol: model.isPlaying ? "pause.fill" : "play.fill", help: model.isPlaying ? L("Pausar (espaço)") : L("Reproduzir (espaço)")) { model.togglePlay() }
                Text(TimelineNSView.format(model.playhead)).font(.system(size: 12, weight: .medium, design: .monospaced))
                Text("/ " + totalText).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                Divider().frame(height: 18).padding(.horizontal, 3)
                VideoIconButton(symbol: "arrow.right.to.line.compact", help: L("Marcar o início do trecho aqui (I)")) { model.markStart(); if let s = model.selection { model.preview(s.start, label: L("Início do trecho")) } }
                VideoIconButton(symbol: "arrow.left.to.line.compact", help: L("Marcar o fim do trecho aqui (O)")) { model.markEnd(); if let s = model.selection { model.preview(s.end, label: L("Fim do trecho")) } }
                Divider().frame(height: 18).padding(.horizontal, 3)
                VideoIconButton(symbol: "scissors", help: L("Cortar e juntar: o resto toca seguido (Delete)"), prominent: true, disabled: !model.canCut) { perform(.cutJoin) }
                VideoIconButton(symbol: "square.split.2x1", help: L("Inserir uma quebra na posição de reprodução, na linha escolhida (B)"), disabled: model.working != nil) { perform(.insertBreak) }
                VideoIconButton(symbol: "scissors.badge.ellipsis", help: L("Cortar deixando um espaço (sem vídeo e sem som) (⇧Delete)"), disabled: !model.canCut) { perform(.cutGap) }
                Divider().frame(height: 18).padding(.horizontal, 3)
                VideoIconButton(symbol: "doc.on.doc", help: L("Copiar o trecho marcado (⌘C)"), disabled: !model.canCut) { perform(.copy) }
                VideoIconButton(symbol: "doc.on.clipboard", help: L("Colar na posição de reprodução, empurrando o resto (⌘V)"), disabled: !model.canPaste) { perform(.paste) }
                VideoIconButton(symbol: "rectangle.on.rectangle", help: L("Colar por cima, substituindo o que lá estiver (⌥⌘V)"), disabled: !model.canPaste) { perform(.pasteOver) }
                VideoIconButton(symbol: "backward.fill", help: L("Inverter o trecho: passa a tocar de trás para a frente"), disabled: !model.canCut || model.working != nil) { perform(.reverse) }
                VideoIconButton(symbol: "gauge.with.needle", help: L("Velocidade do clipe marcado (2× acelera, 0,5× é câmara lenta; o som acompanha)"), prominent: (model.selectedRate ?? 1) != 1, disabled: model.selectedRate == nil) {
                    let cur = model.selectedRate ?? 1
                    popUpMenu(VideoEditorModel.speeds.map { r in (r == r.rounded() ? "\(Int(r))×" : String(format: "%.2g×", r), abs(cur - r) < 1e-9, true, { Task { await model.setSpeed(r) } }) })
                }
                VideoIconButton(symbol: model.isNarrating ? "stop.circle.fill" : "waveform.and.mic", help: model.isNarrating ? L("Parar a narração (entra na linha «Narração»)") : L("Áudio: importar música, gravar uma narração, microfone, volumes…"), prominent: model.isNarrating) {
                    if model.isNarrating { Task { await model.stopNarration() }; return }
                    var items: [(String, Bool, Bool, (() -> Void)?)] = [
                        (L("Importar áudio… (música de fundo, na posição de reprodução)"), false, true, { importAudio() }),
                        (L("Gravar narração a partir daqui (o vídeo toca enquanto fala)"), false, true, { Task { await model.startNarration() } }),
                        ("-", false, true, nil),
                        (L("Volume e fade: botão direito no nome da linha de áudio"), false, false, nil),
                        ("-", false, true, nil),
                        (L("Microfone: %@", MicrophoneChoice.selectedName), false, false, nil),
                        (L("Predefinido do sistema"), MicrophoneChoice.selectedID == nil, true, { MicrophoneChoice.selectedID = nil }),
                    ]
                    for m in MicrophoneChoice.available() { items.append((m.name, MicrophoneChoice.selectedID == m.id, true, { MicrophoneChoice.selectedID = m.id })) }
                    popUpMenu(items)
                }
                Divider().frame(height: 18).padding(.horizontal, 3)
                VideoIconButton(symbol: "minus.magnifyingglass", help: L("Afastar a linha de tempo (-)"), disabled: model.zoom <= VideoEditorModel.zoomRange.lowerBound + 0.001) { model.zoom(by: 1 / 1.5) }
                VideoIconButton(symbol: "plus.magnifyingglass", help: L("Aproximar a linha de tempo (+)"), disabled: model.zoom >= VideoEditorModel.zoomRange.upperBound - 0.001) { model.zoom(by: 1.5) }
                VideoIconButton(symbol: "arrow.left.and.right.square", help: L("Ver tudo (0)"), disabled: abs(model.zoom - 1) < 0.001) { model.zoomFit() }
                VideoIconButton(symbol: "photo.on.rectangle", help: L("Miniaturas na linha do vídeo"), prominent: model.showThumbnails) { model.showThumbnails.toggle() }
                Divider().frame(height: 18).padding(.horizontal, 3)
                VideoIconButton(symbol: "aspectratio", help: L("Tela do vídeo: redimensionar e rodar com o rato (ou pelos campos)"), prominent: model.frameMode || model.isOutputTransformed, disabled: model.sourceSize.width == 0) { model.frameMode.toggle() }
                VideoIconButton(symbol: "pencil.and.outline", help: L("Anotar: setas, texto, carimbos, pixelização… sobre o vídeo, com início e fim (A)"), prominent: model.annotateMode || model.hasOverlays, disabled: model.sourceSize.width == 0) { model.frameMode = false; model.annotateMode.toggle() }
                VideoIconButton(symbol: "arrow.uturn.backward", help: L("Desfazer"), disabled: !model.canUndo) { Task { await model.undo() } }
                VideoIconButton(symbol: "arrow.uturn.forward", help: L("Refazer"), disabled: !model.canRedo) { Task { await model.redo() } }
                Spacer()
                VideoIconButton(symbol: "square.and.arrow.down.on.square", help: L("Guardar: MP4 editado (na biblioteca), GIF animado ou só o áudio"), disabled: model.working != nil) {
                    popUpMenu([
                        (L("Guardar o vídeo editado (MP4, na biblioteca)"), false, true, { Task {
                            do { state.open(try await model.exportEdited()) } catch { state.errorMessage = L("Não foi possível guardar o vídeo: %@", error.localizedDescription) } } }),
                        (L("Guardar como GIF animado…"), false, model.sourceSize.width > 0, { saveAs(ext: "gif", type: .gif) { url in try await model.exportGIF(to: url) } }),
                        (L("Guardar só o áudio (M4A)…"), false, true, { saveAs(ext: "m4a", type: .mpeg4Audio) { url in try await model.exportAudio(to: url) } }),
                    ])
                }
                VideoIconButton(symbol: "folder", help: L("Mostrar no Finder")) { NSWorkspace.shared.activateFileViewerSelecting([model.url]) }
            }
            .padding(.horizontal, 10).frame(height: 36)
            .background(.bar)
            VideoTimeline(model: model, onAction: perform)
                .frame(height: min(TimelineNSView.maxHeight, TimelineNSView.idealHeight(lanes: max(1, model.timeline.tracks.count), overlayRows: model.hasOverlays || model.annotateMode ? max(1, TimelineNSView.packOverlays(model.overlays).count) : 0)))
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "video.fill").foregroundStyle(.secondary)
                Text(model.url.lastPathComponent).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Text(model.info).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                if model.isOutputTransformed { Text("→ \(Int(model.canvasSize.width)) × \(Int(model.canvasSize.height))" + (model.outputRotation != 0 ? " · \(Int(model.outputRotation.rounded()))°" : "")).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.accentColor) }
                Spacer()
                Text(model.isNarrating ? L("A gravar a narração… carregue no botão vermelho para parar.") : L("Arraste um bloco para o mover (entra entre blocos). ⇧+arrastar marca um trecho para recortar. Olho: entra no resultado. Cadeado: protege. Botão direito no nome de uma linha de áudio: volume e fade.")).font(.system(size: 11)).foregroundStyle(model.isNarrating ? Color.red : Color.secondary).lineLimit(1)
            }
            .padding(.horizontal, 12).frame(height: 24)
            .background(.bar)
        }
        .task { await model.load(); await model.loadThumbnails() }
        .onDisappear { model.tearDown() }
        .alert(L("Editar"), isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK") { model.message = nil }
        } message: { Text(model.message ?? "") }
    }
}
