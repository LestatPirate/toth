// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AVFoundation
import AVKit
import AppKit
import SwiftUI

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

/// O vídeo no editor: leitor, linha de tempo e a barra de edição (cortar um trecho para o retirar). O que sobra toca seguido.
struct VideoWorkspace: View {
    @StateObject private var model: VideoEditorModel
    @ObservedObject private var state = AppState.shared

    init(url: URL) { _model = StateObject(wrappedValue: VideoEditorModel(url: url)) }
    init(model: VideoEditorModel) { _model = StateObject(wrappedValue: model) }

    private var keptText: String {
        let removed = model.duration - model.cuts.keptDuration
        return model.cuts.hasCuts
            ? L("%@ no total · %@ retirados em %d corte(s)", TimelineNSView.format(model.cuts.keptDuration), TimelineNSView.format(removed), model.cuts.cuts.count)
            : TimelineNSView.format(model.duration)
    }

    var body: some View {
        VStack(spacing: 0) {
            PlayerView(player: model.player)
                .background(Color.black)
                .frame(minWidth: 160, maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
                .overlay { if model.exporting { ProgressView(L("A guardar o vídeo…")).padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)) } }
                .onTapGesture { model.togglePlay() }
            Divider()
            HStack(spacing: 6) {
                VideoIconButton(symbol: model.isPlaying ? "pause.fill" : "play.fill", help: model.isPlaying ? L("Pausar (espaço)") : L("Reproduzir (espaço)")) { model.togglePlay() }
                Text(TimelineNSView.format(model.cuts.editedTime(forSource: model.playhead))).font(.system(size: 12, weight: .medium, design: .monospaced))
                Text("/ " + TimelineNSView.format(model.cuts.keptDuration)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                Divider().frame(height: 18).padding(.horizontal, 4)
                VideoIconButton(symbol: "arrow.right.to.line.compact", help: L("Marcar o início do trecho aqui (I)")) { model.markStart() }
                VideoIconButton(symbol: "arrow.left.to.line.compact", help: L("Marcar o fim do trecho aqui (O)")) { model.markEnd() }
                VideoIconButton(symbol: "scissors", help: L("Cortar o trecho marcado: o resto toca seguido (Delete)"), prominent: true, disabled: !model.canCut) { Task { await model.cutSelection() } }
                Divider().frame(height: 18).padding(.horizontal, 4)
                VideoIconButton(symbol: "arrow.uturn.backward", help: L("Desfazer o corte"), disabled: !model.canUndo) { Task { await model.undo() } }
                VideoIconButton(symbol: "arrow.uturn.forward", help: L("Refazer o corte"), disabled: !model.canRedo) { Task { await model.redo() } }
                Spacer()
                Text(keptText).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                VideoIconButton(symbol: "square.and.arrow.down.on.square", help: L("Guardar o vídeo cortado (ficheiro novo)"), disabled: model.exporting) {
                    Task {
                        do { state.open(try await model.exportEdited()) }
                        catch { state.errorMessage = L("Não foi possível guardar o vídeo: %@", error.localizedDescription) }
                    }
                }
                VideoIconButton(symbol: "folder", help: L("Mostrar no Finder")) { NSWorkspace.shared.activateFileViewerSelecting([model.url]) }
            }
            .padding(.horizontal, 10).frame(height: 36)
            .background(.bar)
            VideoTimeline(model: model)
                .frame(height: 104)
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "video.fill").foregroundStyle(.secondary)
                Text(model.url.lastPathComponent).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Text(model.info).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text(L("Arraste na linha de tempo para marcar um trecho e corte-o.")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 12).frame(height: 24)
            .background(.bar)
        }
        .task { await model.load() }
        .onDisappear { model.tearDown() }
        .alert(L("Cortar"), isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK") { model.message = nil }
        } message: { Text(model.message ?? "") }
    }
}
