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

@MainActor
final class VideoWorkspaceModel: ObservableObject {
    let url: URL
    let player: AVPlayer
    @Published var info = ""

    init(url: URL) {
        self.url = url
        player = AVPlayer(url: url)
        Task { await loadInfo() }
    }

    private func loadInfo() async {
        let asset = AVURLAsset(url: url)
        var parts: [String] = []
        if let d = try? await asset.load(.duration).seconds, d.isFinite {
            let s = Int(d.rounded())
            parts.append(String(format: "%d:%02d", s / 60, s % 60))
        }
        if let v = try? await asset.loadTracks(withMediaType: .video).first, let size = try? await v.load(.naturalSize) {
            parts.append("\(Int(size.width)) × \(Int(size.height))")
        }
        let audio = (try? await asset.loadTracks(withMediaType: .audio).count) ?? 0
        parts.append(audio > 0 ? L("com áudio") : L("sem áudio"))
        if let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        }
        info = parts.joined(separator: " · ")
    }

    func stop() { player.pause() }
}

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .floating
        v.showsFullScreenToggleButton = false
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) { if v.player !== player { v.player = player } }
}

struct VideoWorkspace: View {
    @StateObject private var model: VideoWorkspaceModel

    init(url: URL) { _model = StateObject(wrappedValue: VideoWorkspaceModel(url: url)) }

    var body: some View {
        VStack(spacing: 0) {
            PlayerView(player: model.player)
                .background(Color.black)
                .frame(minWidth: 160, maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
            Divider()
            HStack(spacing: 10) {
                Image(systemName: "video.fill").foregroundStyle(.secondary)
                Text(model.url.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(model.info).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text(L("A edição de vídeo chega em breve.")).font(.system(size: 11)).foregroundStyle(.secondary)
                Button { NSWorkspace.shared.activateFileViewerSelecting([model.url]) } label: { Image(systemName: "folder") }
                    .help(L("Mostrar no Finder")).buttonStyle(.borderless)
            }
            .padding(.horizontal, 12).frame(height: 34)
            .background(.bar)
        }
        .onDisappear { model.stop() }
    }
}
