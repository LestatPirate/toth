// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AVFoundation
import AppKit
import CaptureCore

struct TrackKey: Hashable { let media: Int; let lane: EditTrack }

/// Constrói o vídeo editado a partir das linhas: cada linha põe os seus clipes onde a linha de tempo diz; onde não há clipe
/// o vídeo fica preto e o áudio em silêncio. Não copia nada (usa os ficheiros originais e os gerados).
enum VideoComposer {
    static let fade = 0.012   // fade de áudio nas pontas dos clipes (evita estalidos)

    /// `enabled`: as linhas que entram no resultado; as outras ficam suprimidas (sem imagem ou sem som), na reprodução e ao guardar.
    static func build(timeline: EditTimeline, tracks: [TrackKey: AVAssetTrack], mediaLength: [Int: Double], enabled: Set<EditTrack>? = nil) async throws
        -> (AVMutableComposition, AVAudioMix?, AVVideoComposition?) {
        let comp = AVMutableComposition()
        let scale: CMTimeScale = 90_000
        func time(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: scale) }
        let total = timeline.duration
        var params: [AVMutableAudioMixInputParameters] = []
        var hasVideo = false

        for lane in timeline.lanes {
            guard !lane.clips.isEmpty, enabled?.contains(lane.track) ?? true else { continue }
            let dst = comp.addMutableTrack(withMediaType: lane.track == .video ? .video : .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            var transformSet = false
            var ramps: [(CMTimeRange, Float, Float)] = []
            for c in lane.clips {
                guard let srcTrack = tracks[TrackKey(media: c.media, lane: lane.track)] else { continue }
                try dst?.insertTimeRange(CMTimeRange(start: time(c.src.start), duration: time(c.length)), of: srcTrack, at: time(c.at))
                if lane.track == .video {
                    hasVideo = true
                    if !transformSet, let dst { dst.preferredTransform = try await srcTrack.load(.preferredTransform); transformSet = true }
                } else {
                    let f = min(fade, c.length / 2)
                    let mediaEnd = mediaLength[c.media] ?? c.src.end
                    if !(c.at < 0.001 && c.src.start < 0.001) { ramps.append((CMTimeRange(start: time(c.at), duration: time(f)), 0, 1)) }
                    if !(c.end >= total - 0.001 && c.src.end >= mediaEnd - 0.001) { ramps.append((CMTimeRange(start: time(c.end - f), duration: time(f)), 1, 0)) }
                }
            }
            if lane.track != .video, let dst, !ramps.isEmpty {
                let p = AVMutableAudioMixInputParameters(track: dst)
                for (r, a, b) in ramps { p.setVolumeRamp(fromStartVolume: a, toEndVolume: b, timeRange: r) }
                params.append(p)
            }
        }
        var mix: AVAudioMix?
        if !params.isEmpty { let m = AVMutableAudioMix(); m.inputParameters = params; mix = m }
        var vc: AVVideoComposition?
        if hasVideo {
            let m = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: comp)
            m.frameDuration = CMTime(value: 1, timescale: 30)         // as gravações têm ritmo variável (só mudam quando o ecrã muda); a composição sai a 30/s
            vc = m
        }
        return (comp, mix, vc)
    }
}

/// Picos de volume de uma faixa de áudio (50 por segundo), para desenhar a onda.
enum Waveform {
    static let perSecond = 50.0
    static func peaks(asset: AVAsset, track: AVAssetTrack) async -> [Float] {
        guard let reader = try? AVAssetReader(asset: asset) else { return [] }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                                                                          AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 8_000, AVNumberOfChannelsKey: 1])
        reader.add(out)
        guard reader.startReading() else { return [] }
        let bucket = Int(8_000 / perSecond)
        var peaks: [Float] = [], cur: Float = 0, n = 0
        while let sb = out.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            var len = 0; var ptr: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
            guard let ptr else { continue }
            let samples = UnsafeBufferPointer(start: UnsafeRawPointer(ptr).assumingMemoryBound(to: Float.self), count: len / 4)
            for x in samples { cur = max(cur, abs(x)); n += 1; if n == bucket { peaks.append(cur); cur = 0; n = 0 } }
        }
        if n > 0 { peaks.append(cur) }
        return peaks
    }
}

/// Edição de um vídeo no editor: várias linhas (vídeo, áudio do sistema, microfone), cortar juntando ou deixando espaço,
/// copiar, colar, inverter, desfazer e guardar. Tudo sem tocar no ficheiro original.
@MainActor
final class VideoEditorModel: ObservableObject {
    enum Edge { case start, end }

    let url: URL
    let asset: AVURLAsset
    let player = AVPlayer()

    @Published private(set) var timeline = EditTimeline(sourceDuration: 0, tracks: [])
    /// Trecho marcado (em tempo da linha de tempo).
    @Published var selection: TimeSpan?
    /// A ponta do trecho que as setas movem e que se vê no leitor.
    @Published var activeEdge = Edge.end
    /// Posição de reprodução (tempo da linha de tempo).
    @Published private(set) var playhead = 0.0
    @Published private(set) var isPlaying = false
    /// Linhas que entram no resultado (na reprodução e ao guardar). Uma linha desmarcada fica suprimida.
    @Published private(set) var enabled: Set<EditTrack> = []
    /// Linhas protegidas: não mudam com cortes, cópias, colagens, inversões nem movimentos (mas continuam a tocar).
    @Published private(set) var locked: Set<EditTrack> = []
    /// Linhas a que as operações se aplicam: as que entram no resultado e não estão protegidas.
    var mask: Set<EditTrack> {
        get { enabled.subtracting(locked) }
        set { enabled.formUnion(newValue); locked = Set(timeline.tracks).subtracting(newValue) }
    }
    /// Zoom da linha de tempo (1 = tudo à vista; menos que 1 afasta, para ter espaço à volta; mais que 1 aproxima) e o instante
    /// que está no limite esquerdo.
    @Published private(set) var zoom = 1.0
    @Published private(set) var viewStart = 0.0
    /// Largura (em píxeis) da zona das faixas; quem a conhece é a vista.
    var trackWidth: Double = 800 { didSet { if abs(trackWidth - oldValue) > 0.5 { clampView() } } }
    @Published private(set) var clipboard: EditPiece?
    @Published private(set) var working: String?
    @Published private(set) var peaks: [TrackKey: [Float]] = [:]
    @Published private(set) var info = ""
    /// Texto sobre o leitor quando se está a ver o ponto exato de uma ponta do trecho.
    @Published private(set) var previewLabel: String?
    @Published var message: String?
    private(set) var frameStep = 1.0 / 30

    private struct Snapshot { var timeline: EditTimeline; var media: [Int: URL]; var nextMedia: Int }
    private var undoStack: [Snapshot] = [], redoStack: [Snapshot] = []
    private var media: [Int: URL] = [:]
    private var nextMedia = 1
    private var assets: [Int: AVURLAsset] = [:]
    private var tracks: [TrackKey: AVAssetTrack] = [:]
    private var mediaLength: [Int: Double] = [:]
    /// Para testes: as faixas e comprimentos usados na composição.
    var trackMap: [TrackKey: AVAssetTrack] { tracks }
    var mediaLengths: [Int: Double] { mediaLength }
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var rebuildToken = 0
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var duration: Double { timeline.duration }
    /// Com um só áudio (vídeos antigos), a linha chama-se «Áudio».
    private(set) var singleAudio = false

    /// Onde se guarda a edição (ao lado do vídeo): o ficheiro dos cortes e os trechos invertidos. Ao reabrir, continua lá.
    var editFolder: URL { url.appendingPathExtension("edicao") }
    private var editFile: URL { editFolder.appendingPathComponent("edicao.json") }

    init(url: URL) {
        self.url = url
        asset = AVURLAsset(url: url)
    }

    func tearDown() {
        player.pause()
        if let o = timeObserver { player.removeTimeObserver(o); timeObserver = nil }
        if let e = endObserver { NotificationCenter.default.removeObserver(e); endObserver = nil }
        statusObserver = nil
    }

    // MARK: Abrir

    func load() async {
        let d = (try? await asset.load(.duration).seconds) ?? 0
        let duration = d.isFinite ? d : 0
        assets[0] = asset; media[0] = url; mediaLength[0] = duration
        var lanes: [EditTrack] = []
        if let v = try? await asset.loadTracks(withMediaType: .video).first {
            lanes.append(.video); tracks[TrackKey(media: 0, lane: .video)] = v
            if let r = try? await v.load(.minFrameDuration), r.seconds > 0, r.seconds < 0.2 { frameStep = r.seconds }
            else if let f = try? await v.load(.nominalFrameRate), f > 0 { frameStep = 1.0 / Double(f) }
        }
        let audios = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        if audios.count >= 3 {                                   // gravações do Toth: mistura, sistema, microfone
            lanes += [.system, .microphone]
            tracks[TrackKey(media: 0, lane: .system)] = audios[1]; tracks[TrackKey(media: 0, lane: .microphone)] = audios[2]
        } else if let a = audios.first { lanes.append(.system); singleAudio = true; tracks[TrackKey(media: 0, lane: .system)] = a }
        timeline = EditTimeline(sourceDuration: duration, tracks: lanes)
        enabled = Set(lanes); locked = []
        loadSaved()
        await finishLoadingGenerated()
        await loadInfo(audioCount: audios.count)
        await rebuildPlayer(at: 0)
        installObservers()
        Task { await loadPeaks() }
    }

    private func loadInfo(audioCount: Int) async {
        var parts: [String] = []
        if let v = try? await asset.loadTracks(withMediaType: .video).first, let size = try? await v.load(.naturalSize) { parts.append("\(Int(size.width)) × \(Int(size.height))") }
        parts.append(audioCount > 0 ? L("com áudio") : L("sem áudio"))
        if let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize { parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) }
        info = parts.joined(separator: " · ")
    }

    private func loadPeaks() async {
        for lane in timeline.tracks where lane != .video {
            for (id, a) in assets {
                let key = TrackKey(media: id, lane: lane)
                guard peaks[key] == nil, let t = tracks[key] else { continue }
                peaks[key] = await Waveform.peaks(asset: a, track: t)
            }
        }
    }

    /// Descobre a faixa de `lane` numa média gerada (um trecho invertido).
    private func registerGenerated(_ id: Int, lane: EditTrack, file: URL, length: Double) async {
        media[id] = file; mediaLength[id] = length
        let a = AVURLAsset(url: file); assets[id] = a
        let type: AVMediaType = lane == .video ? .video : .audio
        if let t = try? await a.loadTracks(withMediaType: type).first {
            tracks[TrackKey(media: id, lane: lane)] = t
            if lane != .video { peaks[TrackKey(media: id, lane: lane)] = await Waveform.peaks(asset: a, track: t) }
        }
    }

    // MARK: Reprodução

    private func installObservers() {
        if timeObserver == nil {
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1.0 / 30, preferredTimescale: 600), queue: .main) { [weak self] t in
                MainActor.assumeIsolated {
                    guard let self, t.seconds.isFinite else { return }
                    self.playhead = t.seconds
                    if self.isPlaying { self.pan(toShow: t.seconds) }
                }
            }
        }
        statusObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            Task { @MainActor in self?.isPlaying = p.timeControlStatus != .paused }
        }
    }

    private func rebuildPlayer(at time: Double) async {
        rebuildToken += 1
        let token = rebuildToken
        let wasPlaying = isPlaying
        let item: AVPlayerItem
        do {
            let (comp, mix, vc) = try await VideoComposer.build(timeline: timeline, tracks: tracks, mediaLength: mediaLength, enabled: enabled)
            guard token == rebuildToken else { return }
            item = AVPlayerItem(asset: comp)
            item.audioMix = mix
            item.videoComposition = vc
        } catch { message = error.localizedDescription; return }
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.isPlaying = false }
        }
        player.replaceCurrentItem(with: item)
        let t = max(0, min(time, timeline.duration))
        await player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        playhead = t
        if wasPlaying { player.play() }
    }

    func togglePlay() {
        previewLabel = nil
        if isPlaying { player.pause(); return }
        if playhead >= timeline.duration - 0.05 { player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) }
        player.play()
    }

    func seek(to t: Double) {
        let t = max(0, min(t, timeline.duration))
        playhead = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Mostra no leitor o fotograma exato de `t` (para decidir os pontos de corte), com uma legenda.
    func preview(_ t: Double, label: String) {
        player.pause()
        let t = max(0, min(t, max(0, timeline.duration - frameStep / 2)))
        playhead = t
        previewLabel = "\(label) · \(TimelineNSView.format(t, tenths: true)) · \(L("quadro")) \(Int((t / frameStep).rounded()))"
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func clearPreview() { previewLabel = nil }

    /// Anda `delta` segundos (a reprodução), ou, com uma ponta ativa, move essa ponta.
    func step(_ delta: Double, moveEdge: Bool) {
        if moveEdge, let sel = selection {
            var s = sel
            if activeEdge == .start { s.start = max(0, min(sel.start + delta, sel.end - frameStep)) }
            else { s.end = min(timeline.duration, max(sel.end + delta, sel.start + frameStep)) }
            selection = s
            preview(activeEdge == .start ? s.start : s.end, label: activeEdge == .start ? L("Início do trecho") : L("Fim do trecho"))
        } else { previewLabel = nil; seek(to: playhead + delta) }
    }

    // MARK: Marcar

    func markStart() {
        let end = selection.map { $0.end > playhead + frameStep ? $0.end : min(timeline.duration, playhead + 1) } ?? min(timeline.duration, playhead + 1)
        selection = TimeSpan(start: playhead, end: end); activeEdge = .start
    }

    func markEnd() {
        let start = selection.map { $0.start < playhead - frameStep ? $0.start : max(0, playhead - 1) } ?? max(0, playhead - 1)
        selection = TimeSpan(start: start, end: playhead); activeEdge = .end
    }

    /// Inclui ou suprime a linha no resultado (reprodução e guardar). Tem de ficar pelo menos uma.
    func toggleEnabled(_ t: EditTrack) async {
        if enabled.contains(t) { guard enabled.count > 1 else { return }; enabled.remove(t) } else { enabled.insert(t) }
        saveEdit()
        await rebuildPlayer(at: playhead)
    }

    /// Protege ou liberta a linha das operações de edição.
    func toggleLocked(_ t: EditTrack) { if locked.contains(t) { locked.remove(t) } else { locked.insert(t) }; saveEdit() }

    // MARK: Zoom da linha de tempo

    static let zoomRange = 0.25...80.0
    /// Píxeis por segundo para o zoom atual.
    var pixelsPerSecond: Double { trackWidth / max(0.5, timeline.duration) * zoom }
    var visibleDuration: Double { trackWidth / max(0.001, pixelsPerSecond) }

    /// Ajusta o zoom por `factor`, mantendo no mesmo sítio o instante `anchor` (por omissão a posição de reprodução, se estiver à
    /// vista, ou o meio) que está à fração `frac` da largura.
    func zoom(by factor: Double, anchor: Double? = nil, atFraction frac: Double? = nil) {
        let visible = playhead >= viewStart && playhead <= viewStart + visibleDuration
        let t = anchor ?? (visible ? playhead : viewStart + visibleDuration / 2)
        let f = frac ?? ((t - viewStart) / max(0.001, visibleDuration))
        zoom = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, zoom * factor))
        viewStart = t - f * visibleDuration
        clampView()
    }
    func zoomFit() { zoom = 1; viewStart = 0 }
    func pan(bySeconds d: Double) { viewStart += d; clampView() }
    func pan(toShow t: Double) { if t < viewStart || t > viewStart + visibleDuration * 0.95 { viewStart = t - visibleDuration * 0.1; clampView() } }

    private func clampView() {
        if zoom <= 1.0001 { viewStart = 0; return }
        viewStart = max(0, min(viewStart, max(0, timeline.duration - visibleDuration * 0.9)))
    }

    var canCut: Bool { (selection?.length ?? 0) >= EditTimeline.minCut && !mask.isEmpty }
    var canPaste: Bool { clipboard != nil }

    // MARK: Editar

    private func snapshot() -> Snapshot { Snapshot(timeline: timeline, media: media, nextMedia: nextMedia) }

    private func commit(_ before: Snapshot, at time: Double) async {
        undoStack.append(before); redoStack = []
        saveEdit()
        await rebuildPlayer(at: time)
    }

    /// Retira o trecho marcado das linhas escolhidas. `join`: o que vem depois recua e toca seguido; senão fica um espaço
    /// (sem vídeo, se o vídeo estiver entre as linhas escolhidas; sem som, nas de áudio).
    func cut(join: Bool) async {
        guard let sel = selection else { return }
        let before = snapshot()
        var next = timeline
        guard next.remove(sel, tracks: mask, ripple: join) else { message = L("Não dá para cortar esse trecho: é curto demais ou deixaria tudo vazio."); return }
        timeline = next
        selection = nil; previewLabel = nil
        await commit(before, at: sel.start)
    }

    func copySelection() {
        guard let sel = selection, !mask.isEmpty else { return }
        clipboard = timeline.extract(sel, tracks: mask)
    }

    /// Cola o que foi copiado na posição de reprodução. `insert`: dá lugar (o resto avança); senão substitui o que lá estiver.
    func paste(insert: Bool) async {
        guard let piece = clipboard, !piece.isEmpty else { return }
        let before = snapshot()
        timeline.insert(piece, at: playhead, ripple: insert)
        let start = playhead
        selection = TimeSpan(start: start, end: min(timeline.duration, start + piece.length))
        previewLabel = nil
        await commit(before, at: start)
    }

    /// Inverte o trecho marcado nas linhas escolhidas (passa a tocar de trás para a frente).
    func reverseSelection() async {
        guard let sel = selection, !mask.isEmpty, working == nil else { return }
        let piece = timeline.extract(sel, tracks: mask)
        guard !piece.isEmpty else { return }
        working = L("A inverter o trecho…")
        defer { working = nil }
        let before = snapshot()
        try? FileManager.default.createDirectory(at: editFolder, withIntermediateDirectories: true)
        var replacement: [EditTrack: [Clip]] = [:]
        do {
            for (lane, clips) in piece.lanes {
                for c in clips {
                    guard let src = assets[c.media], let srcTrack = tracks[TrackKey(media: c.media, lane: lane)] else { continue }
                    let id = nextMedia; nextMedia += 1
                    let file = editFolder.appendingPathComponent("invertido-\(id)-\(lane.rawValue).mp4")
                    if lane == .video { try await MediaReverser.reverseVideo(asset: src, range: c.src, to: file) }
                    else { try await MediaReverser.reverseAudio(asset: src, track: srcTrack, range: c.src, to: file) }
                    await registerGenerated(id, lane: lane, file: file, length: c.length)
                    replacement[lane, default: []].append(Clip(media: id, src: TimeSpan(start: 0, end: c.length), at: EditTimeline.mirroredAt(c, length: piece.length)))
                }
            }
        } catch { message = error.localizedDescription; return }
        timeline.replace(sel, tracks: mask, with: replacement)
        previewLabel = nil
        await commit(before, at: sel.start)
    }

    /// Muda de sítio o trecho marcado (nas linhas escolhidas) para começar em `newStart`. Sem `insert`, onde estava fica um espaço
    /// e no destino substitui o que lá estiver; com `insert`, o espaço de origem fecha e o destino dá lugar.
    func moveSelection(to newStart: Double, insert: Bool) async {
        guard let sel = selection, !mask.isEmpty else { return }
        let before = snapshot()
        var next = timeline
        guard let at = next.move(sel, tracks: mask, to: newStart, ripple: insert) else { return }
        timeline = next
        selection = TimeSpan(start: at, end: at + sel.length)
        previewLabel = nil
        await commit(before, at: at)
    }

    /// Marca o clipe (ou o espaço) da linha `lane` que está no instante `t`.
    func selectPart(at t: Double, in lane: EditTrack) {
        if let c = timeline.clip(at: t, in: lane) { selection = TimeSpan(start: c.at, end: c.end) }
        else if let g = timeline.gaps(lane).first(where: { $0.contains(t) }) { selection = g }
        else { return }
        activeEdge = .start
        clearPreview()
    }

    func undo() async {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(snapshot()); restore(prev); saveEdit()
        await rebuildPlayer(at: playhead)
    }

    func redo() async {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot()); restore(next); saveEdit()
        await rebuildPlayer(at: playhead)
    }

    private func restore(_ s: Snapshot) { timeline = s.timeline; media = s.media; nextMedia = s.nextMedia; selection = nil; previewLabel = nil }

    // MARK: Guardar a edição (ao lado do vídeo)

    private struct EditFile: Codable { var timeline: EditTimeline; var media: [String: String]; var nextMedia: Int; var enabled: [String]?; var locked: [String]? }

    private func saveEdit() {
        if timeline.isEdited || enabled.count != timeline.tracks.count || !locked.isEmpty {
            try? FileManager.default.createDirectory(at: editFolder, withIntermediateDirectories: true)
            let f = EditFile(timeline: timeline, media: Dictionary(uniqueKeysWithValues: media.filter { $0.key != 0 }.map { (String($0.key), $0.value.lastPathComponent) }), nextMedia: nextMedia,
                             enabled: enabled.map(\.rawValue).sorted(), locked: locked.map(\.rawValue).sorted())
            try? JSONEncoder().encode(f).write(to: editFile, options: .atomic)
        } else { try? FileManager.default.removeItem(at: editFolder) }
    }

    /// Volta a ler a edição guardada (se houver e for deste vídeo).
    private func loadSaved() {
        guard let data = try? Data(contentsOf: editFile), let f = try? JSONDecoder().decode(EditFile.self, from: data),
              abs(f.timeline.sourceDuration - timeline.sourceDuration) < 0.5, f.timeline.tracks == timeline.tracks else { return }
        var ok = true
        for (k, name) in f.media {
            guard let id = Int(k) else { continue }
            let file = editFolder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) { media[id] = file } else { ok = false }
        }
        guard ok else { return }
        timeline = f.timeline; nextMedia = f.nextMedia
        if let e = f.enabled { let set = Set(e.compactMap(EditTrack.init(rawValue:))).intersection(timeline.tracks); if !set.isEmpty { enabled = set } }
        if let l = f.locked { locked = Set(l.compactMap(EditTrack.init(rawValue:))).intersection(timeline.tracks) }
        for (id, file) in media where id != 0 {
            let a = AVURLAsset(url: file); assets[id] = a
            registerSync(id, file: file, asset: a)
        }
    }

    /// Prepara, na abertura, as faixas dos trechos invertidos já guardados (o nome do ficheiro diz a linha).
    private func registerSync(_ id: Int, file: URL, asset a: AVURLAsset) {
        for lane in timeline.tracks {
            guard file.lastPathComponent.contains("-\(lane.rawValue).") else { continue }
            pendingGenerated.append((id, lane, file))
        }
    }
    private var pendingGenerated: [(Int, EditTrack, URL)] = []

    /// Conclui o registo dos trechos invertidos guardados (async, depois de abrir).
    func finishLoadingGenerated() async {
        for (id, lane, file) in pendingGenerated {
            let a = assets[id] ?? AVURLAsset(url: file)
            let len = (try? await a.load(.duration).seconds) ?? 0
            await registerGenerated(id, lane: lane, file: file, length: len)
        }
        pendingGenerated = []
    }

    // MARK: Guardar o vídeo editado

    /// Escreve o vídeo já editado num ficheiro novo (`…_editado.mp4`, na pasta das capturas) e devolve-o.
    func exportEdited() async throws -> URL {
        working = L("A guardar o vídeo…"); defer { working = nil }
        let (comp, mix, vc) = try await VideoComposer.build(timeline: timeline, tracks: tracks, mediaLength: mediaLength, enabled: enabled)
        let base = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_editado", with: "")
        var out = CaptureStore.folder.appendingPathComponent("\(base)_editado.mp4")
        var n = 2
        while FileManager.default.fileExists(atPath: out.path) { out = CaptureStore.folder.appendingPathComponent("\(base)_editado_\(n).mp4"); n += 1 }
        try await VideoExporter.export(composition: comp, videoComposition: vc, audioMix: mix, to: out)
        return out
    }
}
