// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AVFoundation
import AppKit
import CaptureCore

/// Constrói o vídeo "cortado": junta, sem pausa, os trechos que ficam. Não copia nada: usa o ficheiro original.
enum VideoComposer {
    static let fade = 0.012   // fade de áudio nas junções (evita estalidos)

    static func build(asset: AVAsset, kept: [TimeSpan]) async throws -> (AVMutableComposition, AVAudioMix?) {
        let comp = AVMutableComposition()
        let scale: CMTimeScale = 90_000
        func time(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: scale) }
        let vsrc = try await asset.loadTracks(withMediaType: .video).first
        let asrc = try await asset.loadTracks(withMediaType: .audio).first
        let vdst = vsrc.flatMap { _ in comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) }
        let adst = asrc.flatMap { _ in comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
        if let vsrc, let vdst { vdst.preferredTransform = try await vsrc.load(.preferredTransform) }
        let total = try await asset.load(.duration).seconds

        var cursor = 0.0
        var ramps: [(CMTimeRange, Float, Float)] = []
        for seg in kept {
            let src = CMTimeRange(start: time(seg.start), duration: time(seg.length))
            if let vsrc, let vdst { try vdst.insertTimeRange(src, of: vsrc, at: time(cursor)) }
            if let asrc, let adst { try adst.insertTimeRange(src, of: asrc, at: time(cursor)) }
            // fades só onde há junção (não no início nem no fim do vídeo original)
            let f = min(fade, seg.length / 2)
            if seg.start > 0.001 { ramps.append((CMTimeRange(start: time(cursor), duration: time(f)), 0, 1)) }
            if seg.end < total - 0.001 { ramps.append((CMTimeRange(start: time(cursor + seg.length - f), duration: time(f)), 1, 0)) }
            cursor += seg.length
        }
        var mix: AVAudioMix?
        if let adst, !ramps.isEmpty {
            let p = AVMutableAudioMixInputParameters(track: adst)
            for (range, from, to) in ramps { p.setVolumeRamp(fromStartVolume: from, toEndVolume: to, timeRange: range) }
            let m = AVMutableAudioMix(); m.inputParameters = [p]; mix = m
        }
        return (comp, mix)
    }
}

/// Edição de um vídeo no editor: cortar trechos na linha de tempo (não destrutivo), reproduzir o resultado sem pausas,
/// desfazer, e guardar o vídeo cortado num ficheiro novo.
@MainActor
final class VideoEditorModel: ObservableObject {
    let url: URL
    let asset: AVURLAsset
    let player = AVPlayer()

    @Published private(set) var duration = 0.0
    @Published private(set) var cuts = VideoCuts(duration: 0)
    /// Trecho marcado na linha de tempo (em tempo do vídeo original), pronto a cortar.
    @Published var selection: TimeSpan?
    /// Posição de reprodução, em tempo do vídeo original.
    @Published private(set) var playhead = 0.0
    @Published private(set) var isPlaying = false
    @Published private(set) var thumbnails: [NSImage] = []
    @Published private(set) var exporting = false
    @Published private(set) var info = ""
    @Published var message: String?

    private var undoStack: [VideoCuts] = [], redoStack: [VideoCuts] = []
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Onde se guardam os cortes (ao lado do vídeo): ao reabrir, continuam lá.
    var sidecarURL: URL { url.appendingPathExtension("cortes") }

    init(url: URL) {
        self.url = url
        asset = AVURLAsset(url: url)
    }

    deinit { }

    func tearDown() {
        player.pause()
        if let o = timeObserver { player.removeTimeObserver(o); timeObserver = nil }
        if let e = endObserver { NotificationCenter.default.removeObserver(e); endObserver = nil }
        statusObserver = nil
    }

    // MARK: Abrir

    func load() async {
        let d = (try? await asset.load(.duration).seconds) ?? 0
        duration = d.isFinite ? d : 0
        var saved: VideoCuts?
        if let data = try? Data(contentsOf: sidecarURL), let c = try? JSONDecoder().decode(VideoCuts.self, from: data), abs(c.duration - duration) < 0.5 { saved = c }
        cuts = VideoCuts(duration: duration, cuts: saved?.cuts ?? [])
        await loadInfo()
        await rebuildPlayer(at: 0)
        installObservers()
        Task { await loadThumbnails() }
    }

    private func loadInfo() async {
        var parts: [String] = []
        if let v = try? await asset.loadTracks(withMediaType: .video).first, let size = try? await v.load(.naturalSize) { parts.append("\(Int(size.width)) × \(Int(size.height))") }
        let audio = (try? await asset.loadTracks(withMediaType: .audio).count) ?? 0
        parts.append(audio > 0 ? L("com áudio") : L("sem áudio"))
        if let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize { parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) }
        info = parts.joined(separator: " · ")
    }

    private func loadThumbnails() async {
        guard duration > 0 else { return }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 320, height: 180)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let n = 24
        let times = (0..<n).map { CMTime(seconds: duration * (Double($0) + 0.5) / Double(n), preferredTimescale: 600) }
        var images: [NSImage] = []
        for t in times {
            if let r = try? await gen.image(at: t) { images.append(NSImage(cgImage: r.image, size: NSSize(width: r.image.width, height: r.image.height))) }
            else if let last = images.last { images.append(last) }
        }
        thumbnails = images
    }

    // MARK: Reprodução

    private func installObservers() {
        if timeObserver == nil {
            timeObserver = player.addPeriodicTimeInterval(1.0 / 30) { [weak self] t in
                guard let self else { return }
                self.playhead = self.cuts.sourceTime(forEdited: t.seconds.isFinite ? t.seconds : 0)
            }
        }
        statusObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            Task { @MainActor in self?.isPlaying = p.timeControlStatus != .paused }
        }
    }

    private func rebuildPlayer(at sourceTime: Double) async {
        let wasPlaying = isPlaying
        let item: AVPlayerItem
        do {
            if cuts.hasCuts {
                let (comp, mix) = try await VideoComposer.build(asset: asset, kept: cuts.kept)
                item = AVPlayerItem(asset: comp)
                item.audioMix = mix
            } else { item = AVPlayerItem(asset: asset) }
        } catch { message = error.localizedDescription; return }
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.isPlaying = false }
        }
        player.replaceCurrentItem(with: item)
        let e = cuts.editedTime(forSource: cuts.skipCut(sourceTime))
        await player.seek(to: CMTime(seconds: e, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        playhead = cuts.sourceTime(forEdited: e)
        if wasPlaying { player.play() }
    }

    func togglePlay() {
        if isPlaying { player.pause(); return }
        if cuts.keptDuration - cuts.editedTime(forSource: playhead) < 0.05 {   // no fim: recomeça
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.play()
    }

    /// Põe a reprodução no instante `t` (tempo do vídeo original); se cair num corte, segue para onde o vídeo continua.
    func seek(toSource t: Double) {
        let t = max(0, min(t, duration))
        let e = cuts.editedTime(forSource: cuts.skipCut(t))
        playhead = cuts.sourceTime(forEdited: e)
        player.seek(to: CMTime(seconds: e, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Anda `delta` segundos (tempo do vídeo editado).
    func step(_ delta: Double) {
        let e = max(0, min(cuts.editedTime(forSource: playhead) + delta, cuts.keptDuration))
        player.seek(to: CMTime(seconds: e, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        playhead = cuts.sourceTime(forEdited: e)
    }

    // MARK: Marcar e cortar

    /// Marca o início do trecho no ponto onde está a reprodução.
    func markStart() {
        let end = selection.map { $0.end > playhead + 0.05 ? $0.end : min(duration, playhead + 1) } ?? min(duration, playhead + 1)
        selection = TimeSpan(start: playhead, end: end)
    }

    /// Marca o fim do trecho no ponto onde está a reprodução.
    func markEnd() {
        let start = selection.map { $0.start < playhead - 0.05 ? $0.start : max(0, playhead - 1) } ?? max(0, playhead - 1)
        selection = TimeSpan(start: start, end: playhead)
    }

    var canCut: Bool { selection.map { $0.length >= VideoCuts.minCut } ?? false }

    /// Retira o trecho marcado: o que sobra passa a tocar seguido.
    func cutSelection() async {
        guard let span = selection else { return }
        var next = cuts
        guard next.cut(span) else { message = L("Não dá para cortar esse trecho: é curto demais ou deixaria o vídeo vazio."); return }
        let at = span.start
        undoStack.append(cuts); redoStack = []
        cuts = next
        selection = nil
        saveSidecar()
        await rebuildPlayer(at: at)
    }

    func undo() async {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(cuts); cuts = prev; saveSidecar()
        await rebuildPlayer(at: playhead)
    }

    func redo() async {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(cuts); cuts = next; saveSidecar()
        await rebuildPlayer(at: playhead)
    }

    /// Volta a pôr um trecho retirado.
    func restoreCut(at index: Int) async {
        guard cuts.cuts.indices.contains(index) else { return }
        let at = cuts.cuts[index].start
        undoStack.append(cuts); redoStack = []
        cuts.restore(at: index)
        saveSidecar()
        await rebuildPlayer(at: at)
    }

    private func saveSidecar() {
        if cuts.hasCuts { try? JSONEncoder().encode(cuts).write(to: sidecarURL, options: .atomic) }
        else { try? FileManager.default.removeItem(at: sidecarURL) }
    }

    // MARK: Guardar

    /// Escreve o vídeo já cortado num ficheiro novo (`…_editado.mp4`, na pasta das capturas) e devolve-o.
    func exportEdited() async throws -> URL {
        exporting = true; defer { exporting = false }
        let (comp, mix) = try await VideoComposer.build(asset: asset, kept: cuts.hasCuts ? cuts.kept : [TimeSpan(start: 0, end: duration)])
        let base = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_editado", with: "")
        var out = CaptureStore.folder.appendingPathComponent("\(base)_editado.mp4")
        var n = 2
        while FileManager.default.fileExists(atPath: out.path) { out = CaptureStore.folder.appendingPathComponent("\(base)_editado_\(n).mp4"); n += 1 }
        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else { throw CocoaError(.fileWriteUnknown) }
        session.audioMix = mix
        try await session.export(to: out, as: .mp4)
        return out
    }
}

private extension AVPlayer {
    func addPeriodicTimeInterval(_ seconds: Double, _ block: @escaping @Sendable (CMTime) -> Void) -> Any {
        addPeriodicTimeObserver(forInterval: CMTime(seconds: seconds, preferredTimescale: 600), queue: .main, using: block)
    }
}
