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
    /// `renderSize`: tamanho do vídeo na saída (em proporção ou não); `nil` = o natural. `rotation`: graus (sentido dos ponteiros
    /// do relógio); a saída passa a ser a caixa envolvente do vídeo rodado, com o resto a preto.
    /// `volumes`: ganho por linha de áudio (1 = como está); `fades`: segundos de fade na entrada e saída de cada clipe (0 = só o
    /// anti-estalido). A velocidade de cada clipe (`Clip.rate`) aplica-se aqui (o áudio mantém o tom).
    static func build(timeline: EditTimeline, tracks: [TrackKey: AVAssetTrack], mediaLength: [Int: Double], enabled: Set<EditTrack>? = nil,
                      renderSize: CGSize? = nil, rotation: Double = 0, volumes: [EditTrack: Double] = [:], fades: [EditTrack: Double] = [:]) async throws
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
            let gain = Float(volumes[lane.track] ?? 1)
            let userFade = fades[lane.track] ?? 0
            for c in lane.clips {
                guard let srcTrack = tracks[TrackKey(media: c.media, lane: lane.track)] else { continue }
                try dst?.insertTimeRange(CMTimeRange(start: time(c.src.start), duration: time(c.src.length)), of: srcTrack, at: time(c.at))
                if abs(c.rate - 1) > 1e-9 { dst?.scaleTimeRange(CMTimeRange(start: time(c.at), duration: time(c.src.length)), toDuration: time(c.length)) }
                if lane.track == .video {
                    hasVideo = true
                    if !transformSet, let dst { dst.preferredTransform = try await srcTrack.load(.preferredTransform); transformSet = true }
                } else {
                    let f = min(max(fade, userFade), c.length / 2)
                    let mediaEnd = mediaLength[c.media] ?? c.src.end
                    if userFade > 0 || !(c.at < 0.001 && c.src.start < 0.001) { ramps.append((CMTimeRange(start: time(c.at), duration: time(f)), 0, gain)) }
                    if userFade > 0 || !(c.end >= total - 0.001 && c.src.end >= mediaEnd - 0.001) { ramps.append((CMTimeRange(start: time(c.end - f), duration: time(f)), gain, 0)) }
                }
            }
            if lane.track != .video, let dst, !ramps.isEmpty || abs(gain - 1) > 0.001 {
                let p = AVMutableAudioMixInputParameters(track: dst)
                p.setVolume(gain, at: .zero)
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
            let rot = Geometry.normalizedDegrees(rotation)
            if (renderSize != nil || rot != 0), m.renderSize.width > 0, m.renderSize.height > 0 {
                // redimensionar e rodar: escala cada camada (por cima da transformação que já traz), roda à volta do centro e
                // centra na saída, que passa a ser a caixa envolvente (a par)
                let size = renderSize ?? m.renderSize
                let sx = size.width / m.renderSize.width, sy = size.height / m.renderSize.height
                let canvas = Self.canvasSize(for: size, rotation: rot)
                let t = CGAffineTransform(scaleX: sx, y: sy)
                    .concatenating(CGAffineTransform(translationX: -size.width / 2, y: -size.height / 2))
                    .concatenating(CGAffineTransform(rotationAngle: CGFloat(rot * .pi / 180)))
                    .concatenating(CGAffineTransform(translationX: canvas.width / 2, y: canvas.height / 2))
                for case let inst as AVMutableVideoCompositionInstruction in m.instructions {
                    for case let layer as AVMutableVideoCompositionLayerInstruction in inst.layerInstructions {
                        var start = CGAffineTransform.identity, end = CGAffineTransform.identity, range = CMTimeRange()
                        if !layer.getTransformRamp(for: inst.timeRange.start, start: &start, end: &end, timeRange: &range) { start = .identity }
                        layer.setTransform(start.concatenating(t), at: .zero)
                    }
                }
                m.renderSize = canvas
            }
            vc = m
        }
        return (comp, mix, vc)
    }
}

extension VideoComposer {
    /// Tamanho da saída para um vídeo `size` rodado por `rotation`: a caixa envolvente, arredondada a par (mínimo 16).
    static func canvasSize(for size: CGSize, rotation: Double) -> CGSize {
        let b = Geometry.boundingBox(of: Rect(x: 0, y: 0, width: size.width, height: size.height), rotatedBy: rotation)
        return CGSize(width: max(16, (b.width / 2).rounded() * 2), height: max(16, (b.height / 2).rounded() * 2))
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
    @Published var selection: TimeSpan? { didSet { if selection == nil { selectionLanes = [] } } }
    /// As linhas em que o trecho foi marcado (a marcação é por linha); vazio = as linhas ativas e livres.
    @Published var selectionLanes: Set<EditTrack> = []
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
        get { let base = enabled.subtracting(locked); return selectionLanes.isEmpty ? base : base.intersection(selectionLanes) }
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
    /// Tamanho natural do vídeo (já com a orientação) e o tamanho de saída escolhido (`nil` = natural). O tamanho aplica-se
    /// à reprodução e ao guardar; pode ser em proporção ou livre.
    @Published private(set) var sourceSize = CGSize.zero
    @Published private(set) var outputSize: CGSize?
    /// Rotação do vídeo na saída (graus, sentido dos ponteiros do relógio); a saída é a caixa envolvente.
    @Published private(set) var outputRotation = 0.0
    @Published var outputKeepAspect = true
    /// Modo «Tela» do vídeo: alças sobre o leitor para redimensionar e rodar com o rato, e a barra com os campos.
    @Published var frameMode = false
    var effectiveOutputSize: CGSize { outputSize ?? sourceSize }
    /// Tamanho do ficheiro de saída (o vídeo redimensionado e rodado, a par).
    var canvasSize: CGSize { VideoComposer.canvasSize(for: effectiveOutputSize, rotation: outputRotation) }
    var isOutputTransformed: Bool { outputSize != nil || outputRotation != 0 }

    // MARK: Volume, fade, velocidade, áudio importado, narração e miniaturas

    /// Ganho por linha de áudio (1 = como está) e fade (s) na entrada e saída de cada clipe.
    @Published private(set) var laneVolume: [EditTrack: Double] = [:]
    @Published private(set) var laneFade: [EditTrack: Double] = [:]
    func setLaneVolume(_ t: EditTrack, _ v: Double) async { laneVolume[t] = abs(v - 1) < 0.001 ? nil : max(0, min(2, v)); saveEdit(); await rebuildPlayer(at: playhead) }
    func setLaneFade(_ t: EditTrack, _ f: Double) async { laneFade[t] = f <= 0 ? nil : min(10, f); saveEdit(); await rebuildPlayer(at: playhead) }

    /// Velocidades oferecidas no menu.
    static let speeds: [Double] = [0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4]
    /// A velocidade do que está marcado (o primeiro clipe que começa dentro do trecho, em qualquer linha ativa); sem
    /// trecho marcado, a do clipe na posição de reprodução (ou 1).
    var selectedRate: Double? {
        let lanes = enabled.subtracting(locked)
        if let sel = selection {
            for l in lanes { if let c = timeline.clips(l).first(where: { $0.at >= sel.start - 1e-6 && $0.at < sel.end - 1e-6 }) { return c.rate } }
            return nil
        }
        for l in lanes { if let c = timeline.clip(at: playhead, in: l) { return c.rate } }
        return timeline.tracks.isEmpty ? nil : 1
    }
    /// Muda a velocidade do trecho marcado (os clipes partem-se nas pontas do trecho, para a velocidade valer só ali) ou,
    /// sem trecho marcado, do vídeo todo. Vale em todas as linhas não protegidas (mesmo as suprimidas, para o som acompanhar a
    /// imagem se voltarem a entrar). O trecho marcado passa a cobrir o mesmo conteúdo na nova duração.
    func setSpeed(_ rate: Double) async {
        let tracks = Set(timeline.tracks).subtracting(locked)
        let before = snapshot()
        var next = timeline
        let sel = selection ?? TimeSpan(start: 0, end: timeline.duration)
        if selection != nil {
            _ = next.split(at: sel.start, tracks: tracks)
            _ = next.split(at: sel.end, tracks: tracks)
        }
        // quantos clipes (na linha de referência) ficam dentro do trecho: para voltar a marcar o mesmo conteúdo depois
        let ref = timeline.tracks.first { tracks.contains($0) && !next.clips($0).filter { $0.at >= sel.start - 1e-6 && $0.end <= sel.end + 1e-6 }.isEmpty }
        let count = ref.map { next.clips($0).filter { $0.at >= sel.start - 1e-6 && $0.end <= sel.end + 1e-6 }.count } ?? 0
        guard count > 0, next.setRate(rate, in: sel, tracks: tracks) else {
            if (selectedRate ?? rate) == rate { return }
            message = L("Não dá para mudar a velocidade desse trecho: é curto demais."); return
        }
        timeline = next
        let lanesSel = selectionLanes
        if selection != nil, let ref {
            let inside = Array(next.clips(ref).filter { $0.at >= sel.start - 1e-6 }.prefix(count))
            if let last = inside.last { selection = TimeSpan(start: sel.start, end: last.end); selectionLanes = lanesSel }
        }
        previewLabel = nil
        await commit(before, at: min(playhead, next.duration))
    }

    /// Importa um ficheiro de áudio (MP3, M4A, WAV, AAC, AIFF…) para a linha «Música», a começar na posição de reprodução
    /// (uma cópia fica na pasta da edição).
    func importAudio(_ file: URL) async {
        let a = AVURLAsset(url: file)
        guard let len = try? await a.load(.duration).seconds, len > 0.05, let _ = try? await a.loadTracks(withMediaType: .audio).first else { message = L("Não foi possível ler o áudio de %@.", file.lastPathComponent); return }
        try? FileManager.default.createDirectory(at: editFolder, withIntermediateDirectories: true)
        let id = nextMedia; nextMedia += 1
        let dest = editFolder.appendingPathComponent("importado-\(id)-music.\(file.pathExtension.isEmpty ? "m4a" : file.pathExtension)")
        do { try? FileManager.default.removeItem(at: dest); try FileManager.default.copyItem(at: file, to: dest) } catch { message = L("Não foi possível copiar o áudio: %@", error.localizedDescription); return }
        let before = snapshot()
        await registerGenerated(id, lane: .music, file: dest, length: len)
        await addAudioClip(lane: .music, media: id, length: len, at: playhead, before: before)
    }

    private func addAudioClip(lane: EditTrack, media id: Int, length: Double, at t: Double, before: Snapshot) async {
        let clip = Clip(media: id, src: TimeSpan(start: 0, end: length), at: t)
        if timeline.tracks.contains(lane) { timeline.insert(EditPiece(length: length, lanes: [lane: [Clip(media: id, src: clip.src, at: 0)]]), at: t, ripple: false) }
        else { timeline.addLane(lane, clips: [clip]) }
        enabled.insert(lane)
        selectionLanes = [lane]; selection = TimeSpan(start: t, end: t + length)
        await commit(before, at: t)
    }

    /// Tira uma linha acrescentada (música, narração) e os seus ficheiros.
    func removeLane(_ t: EditTrack) async {
        guard t == .music || t == .narration else { return }
        let before = snapshot()
        timeline.removeLane(t)
        enabled.remove(t); locked.remove(t); laneVolume[t] = nil; laneFade[t] = nil
        if selectionLanes.contains(t) { selection = nil }
        await commit(before, at: playhead)
    }

    // Narração: grava do microfone escolhido enquanto o vídeo toca, a partir da posição de reprodução; ao parar entra na
    // linha «Narração».
    @Published private(set) var isNarrating = false
    private var narrator: NarrationRecorder?
    private var narrationStart = 0.0

    func startNarration() async {
        guard !isNarrating, working == nil else { return }
        guard await MicrophonePermission.request() else { message = L("Sem permissão para o microfone: ative o Toth em Definições do Sistema → Privacidade e Segurança → Microfone."); return }
        try? FileManager.default.createDirectory(at: editFolder, withIntermediateDirectories: true)
        annotateMode = false; frameMode = false
        let id = nextMedia
        let dest = editFolder.appendingPathComponent("narracao-\(id)-narration.m4a")
        do {
            let n = try NarrationRecorder(to: dest, device: MicrophoneChoice.device())
            try n.start()
            narrator = n
        } catch { message = L("Não foi possível começar a gravar: %@", error.localizedDescription); return }
        narrationStart = playhead
        isNarrating = true
        if playhead >= timeline.duration - 0.05 { seek(to: 0); narrationStart = 0 }
        player.play()
    }

    func stopNarration() async {
        guard isNarrating, let n = narrator else { return }
        player.pause()
        isNarrating = false
        narrator = nil
        do {
            let (file, len) = try await n.finish()
            guard len > 0.1 else { try? FileManager.default.removeItem(at: file); message = L("A narração ficou vazia."); return }
            let before = snapshot()
            let id = nextMedia; nextMedia += 1
            await registerGenerated(id, lane: .narration, file: file, length: len)
            await addAudioClip(lane: .narration, media: id, length: len, at: narrationStart, before: before)
        } catch { message = L("Não foi possível guardar a narração: %@", error.localizedDescription) }
    }

    /// Miniaturas na linha do vídeo (opção; por omissão a linha é simples).
    @Published var showThumbnails: Bool = UserDefaults.standard.bool(forKey: "timelineThumbnails") {
        didSet { UserDefaults.standard.set(showThumbnails, forKey: "timelineThumbnails"); if showThumbnails { Task { await loadThumbnails() } } }
    }
    @Published private(set) var thumbnails: [Int: [CGImage]] = [:]
    private var thumbnailsLoading: Set<Int> = []

    /// Gera as miniaturas de cada média com vídeo (uma por segundo, até 150, com 76 px de altura), em segundo plano.
    func loadThumbnails() async {
        guard showThumbnails else { return }
        for (id, a) in assets where thumbnails[id] == nil && !thumbnailsLoading.contains(id) && tracks[TrackKey(media: id, lane: .video)] != nil {
            thumbnailsLoading.insert(id)
            let len = mediaLength[id] ?? 0
            let n = max(1, min(150, Int(len.rounded(.up))))
            let gen = AVAssetImageGenerator(asset: a)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 400, height: 76)
            gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600); gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
            var out: [CGImage] = []
            for i in 0..<n {
                let t = CMTime(seconds: (Double(i) + 0.5) * len / Double(n), preferredTimescale: 600)
                if let (img, _) = try? await gen.image(at: t) { out.append(img) } else if let last = out.last { out.append(last) }
            }
            thumbnails[id] = out
            thumbnailsLoading.remove(id)
        }
    }

    // MARK: Anotações sobre o vídeo (com início e fim)

    /// As anotações (tempos); o desenho de cada uma vive no editor de imagem `overlayEditor` (pacote `anotacoes.capture`).
    @Published private(set) var overlays: [VideoOverlay] = []
    /// Modo «Anotar»: o leitor dá lugar ao editor de imagem sobre o fotograma atual; as anotações ativas no instante editam-se
    /// como numa captura (todas as ferramentas), e cada uma tem início e fim na linha de tempo.
    @Published var annotateMode = false { didSet { if annotateMode != oldValue { Task { await annotateModeChanged() } } } }
    @Published private(set) var overlayEditor: EditorModel?
    let overlayProvider = OverlayProvider()
    /// A composição sem anotações (para tirar o fotograma de fundo do editor).
    private var plain: (AVMutableComposition, AVVideoComposition?)?
    private var frameToken = 0
    var overlayPackage: URL { editFolder.appendingPathComponent("anotacoes.capture") }
    var hasOverlays: Bool { !overlays.isEmpty }
    func overlay(for id: UUID) -> VideoOverlay? { overlays.first { $0.id == id } }
    /// A anotação selecionada no editor (em modo Anotar).
    var selectedOverlay: VideoOverlay? { overlayEditor?.selection.flatMap { overlay(for: $0) } }

    private func annotateModeChanged() async {
        if annotateMode {
            player.pause()
            await prepareOverlayEditor()
            await refreshOverlayFrame()
        } else {
            overlayEditor?.selection = nil
            await rebuildPlayer(at: playhead)
        }
    }

    /// Cria (uma vez) o pacote das anotações e o editor sobre ele.
    private func prepareOverlayEditor() async {
        guard overlayEditor == nil else { return }
        try? FileManager.default.createDirectory(at: editFolder, withIntermediateDirectories: true)
        let size = canvasSize
        if !FileManager.default.fileExists(atPath: overlayPackage.path) {
            // começa com um fotograma preto do tamanho da saída (o fundo é substituído pelo fotograma atual)
            guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(origin: .zero, size: size))
            guard let img = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { return }
            var doc = CaptureDocument(canvasWidth: size.width, canvasHeight: size.height)
            doc.autoExpand = false
            guard let data = try? CapturePackage.encode(doc) else { return }
            _ = try? CaptureContainer.createArchive(at: overlayPackage, entries: [CapturePackage.documentFile: data, CapturePackage.originalFile: png])
        }
        guard let m = try? EditorModel(url: overlayPackage) else { message = L("Não foi possível abrir as anotações do vídeo."); return }
        m.isVideoOverlay = true
        m.tool = .arrow
        m.mutate { $0.autoExpand = false; $0.workArea = nil; $0.canvasWidth = size.width; $0.canvasHeight = size.height }
        m.onCreated = { [weak self] id in self?.overlayCreated(id) }
        m.onSaved = { [weak self] in self?.syncOverlays() }
        overlayEditor = m
        syncOverlays()
    }

    /// Uma anotação nova ganha início na posição de reprodução e 3 s de duração (ou até ao fim).
    private func overlayCreated(_ id: UUID) {
        guard overlay(for: id) == nil else { return }
        overlays.append(VideoOverlay(id: id, start: playhead, end: min(max(timeline.duration, playhead + 0.1), playhead + 3)))
        syncOverlays()
    }

    /// Depois de cada alteração no editor: as anotações apagadas perdem os tempos, as novas (por colar/duplicar) ganham-nos,
    /// o compositor recebe o documento novo e a edição fica gravada.
    private func syncOverlays() {
        guard let m = overlayEditor else { return }
        let ids = Set(m.doc.annotations.map(\.id))
        var next = overlays.filter { ids.contains($0.id) }
        for a in m.doc.annotations where !next.contains(where: { $0.id == a.id }) {
            next.append(VideoOverlay(id: a.id, start: playhead, end: min(max(timeline.duration, playhead + 0.1), playhead + 3)))
        }
        if next != overlays { overlays = next }
        overlayProvider.update(doc: m.doc, overlays: overlays, assets: m.assets)
        refreshShown()
        saveEdit()
    }

    /// Só as anotações ativas na posição de reprodução se mostram (e editam) no editor.
    private func refreshShown() {
        let shown = Set(overlays.filter { $0.contains(playhead) }.map(\.id))
        if overlayEditor?.shownIDs != shown { overlayEditor?.shownIDs = shown }
    }

    /// O fotograma atual (sem anotações) passa a ser o fundo do editor.
    func refreshOverlayFrame() async {
        guard annotateMode, let m = overlayEditor, let (comp, vc) = plain else { return }
        frameToken += 1; let token = frameToken
        let gen = AVAssetImageGenerator(asset: comp)
        gen.videoComposition = vc
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        gen.appliesPreferredTrackTransform = true
        let t = CMTime(seconds: max(0, min(playhead, max(0, timeline.duration - frameStep / 2))), preferredTimescale: 600)
        guard let (img, _) = try? await gen.image(at: t), token == frameToken else { return }
        m.base = img
        if Double(img.width) != m.doc.canvasWidth || Double(img.height) != m.doc.canvasHeight { m.mutate { $0.canvasWidth = Double(img.width); $0.canvasHeight = Double(img.height) } }
        refreshShown()
    }

    /// Muda os tempos de uma anotação (início ≥ 0, fim ≤ duração, pelo menos um quadro).
    func setOverlayRange(_ id: UUID, start: Double? = nil, end: Double? = nil) {
        guard let i = overlays.firstIndex(where: { $0.id == id }) else { return }
        var o = overlays[i]
        if let start { o.start = max(0, min(start, timeline.duration - frameStep)) }
        if let end { o.end = min(timeline.duration, max(end, o.start + frameStep)) }
        if o.start > o.end - frameStep { o.start = max(0, o.end - frameStep) }
        overlays[i] = o
        overlayProvider.update(doc: overlayEditor?.doc, overlays: overlays, assets: overlayEditor?.assets)
        refreshShown(); saveEdit()
    }

    /// «Seguir»: a posição atual do elemento passa a ser onde ele deve estar no **fim**; o elemento volta ao sítio de partida.
    /// Com `clear`, deixa de seguir.
    func setOverlayFollow(_ id: UUID, clear: Bool = false) {
        guard let i = overlays.firstIndex(where: { $0.id == id }), let m = overlayEditor, var a = m.doc.annotations.first(where: { $0.id == id }) else { return }
        if clear { overlays[i].endOffset = nil }
        else {
            // o elemento foi arrastado para a posição final: o deslocamento é a diferença para onde estava (a posição de início)
            let o = overlays[i]
            let k = o.length > 1e-6 ? max(0, min(1, (playhead - o.start) / o.length)) : 1
            guard k > 0.01 else { message = L("Ponha a reprodução mais à frente (perto do fim da anotação) e arraste o elemento para onde deve estar nesse instante."); return }
            let startShape = m.undoShape(of: id)   // a forma antes do último arrasto
            guard let s0 = startShape, s0 != a.shape else { message = L("Primeiro arraste o elemento para onde deve estar no fim; depois carregue em «Seguir»."); return }
            let dx = (a.shape.bounds.minX - s0.bounds.minX) / k, dy = (a.shape.bounds.minY - s0.bounds.minY) / k
            overlays[i].endOffset = Point(x: dx, y: dy)
            a.shape = s0; m.undo()   // volta à posição de início (o movimento passa a ser o seguimento)
        }
        overlayProvider.update(doc: m.doc, overlays: overlays, assets: m.assets)
        saveEdit()
    }

    /// Seleciona uma anotação (da linha de tempo): vai para o seu início e abre o modo Anotar com ela selecionada.
    func selectOverlay(_ id: UUID) {
        guard let o = overlay(for: id) else { return }
        if !(o.contains(playhead)) { seek(to: o.start) }
        if !annotateMode { annotateMode = true } else { Task { await refreshOverlayFrame() } }
        refreshShown()
        overlayEditor?.selection = id
    }

    func deleteOverlay(_ id: UUID) {
        guard let m = overlayEditor else { overlays.removeAll { $0.id == id }; saveEdit(); return }
        m.delete(id)
    }

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

    /// Onde se guarda a edição: dentro do pacote `.tothvideo`; num vídeo solto, numa pasta `.edicao` ao lado. Ao reabrir, continua lá.
    var editFolder: URL { VideoFiles.editFolder(for: url) }
    private var editFile: URL { editFolder.appendingPathComponent("edicao.json") }
    /// O ficheiro de vídeo em si (dentro do pacote, ou o próprio).
    let mediaURL: URL

    /// `url`: um pacote `.tothvideo` ou um vídeo solto.
    init(url: URL) {
        self.url = url
        mediaURL = VideoFiles.mediaURL(url) ?? url
        asset = AVURLAsset(url: mediaURL)
    }

    func tearDown() {
        player.pause()
        if let o = timeObserver { player.removeTimeObserver(o); timeObserver = nil }
        if let e = endObserver { NotificationCenter.default.removeObserver(e); endObserver = nil }
        statusObserver = nil
    }

    // MARK: Abrir

    private var loaded = false
    func load() async {
        guard !loaded else { return }   // (a vista chama-o ao aparecer; os testes já o chamaram)
        loaded = true
        let d = (try? await asset.load(.duration).seconds) ?? 0
        let duration = d.isFinite ? d : 0
        assets[0] = asset; media[0] = mediaURL; mediaLength[0] = duration
        var lanes: [EditTrack] = []
        if let v = try? await asset.loadTracks(withMediaType: .video).first {
            lanes.append(.video); tracks[TrackKey(media: 0, lane: .video)] = v
            if let n = try? await v.load(.naturalSize), let t = try? await v.load(.preferredTransform) {
                let r = CGRect(origin: .zero, size: n).applying(t); sourceSize = CGSize(width: abs(r.width).rounded(), height: abs(r.height).rounded())
            }
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
            let (comp, mix, vc) = try await VideoComposer.build(timeline: timeline, tracks: tracks, mediaLength: mediaLength, enabled: enabled, renderSize: outputSize, rotation: outputRotation, volumes: laneVolume, fades: laneFade)
            guard token == rebuildToken else { return }
            plain = (comp, vc)
            item = AVPlayerItem(asset: comp)
            item.audioMix = mix
            item.audioTimePitchAlgorithm = .spectral   // com a velocidade alterada o tom mantém-se
            item.videoComposition = vc.map { hasOverlays ? OverlayCompositor.wrap($0, provider: overlayProvider) : $0 }
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
        if annotateMode { annotateMode = false }   // reproduzir sai do modo Anotar (o leitor mostra as anotações no seu tempo)
        if isPlaying { player.pause(); return }
        if playhead >= timeline.duration - 0.05 { player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) }
        player.play()
    }

    func seek(to t: Double) {
        let t = max(0, min(t, timeline.duration))
        playhead = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if annotateMode { refreshShown(); Task { await refreshOverlayFrame() } }
    }

    /// Mostra no leitor o fotograma exato de `t` (para decidir os pontos de corte), com uma legenda.
    func preview(_ t: Double, label: String) {
        player.pause()
        let t = max(0, min(t, max(0, timeline.duration - frameStep / 2)))
        playhead = t
        previewLabel = "\(label) · \(TimelineNSView.format(t, tenths: true)) · \(L("quadro")) \(Int((t / frameStep).rounded()))"
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if annotateMode { refreshShown(); Task { await refreshOverlayFrame() } }
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

    // MARK: Tamanho de saída

    /// Muda uma medida (a outra acompanha se `outputKeepAspect`); mínimo 16 px, arredondado a par.
    func setOutputSize(width: Double? = nil, height: Double? = nil) async {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return }
        let ratio = sourceSize.width / sourceSize.height
        var w = effectiveOutputSize.width, h = effectiveOutputSize.height
        if let width { w = max(16, width); if outputKeepAspect { h = max(16, w / ratio) } }
        if let height { h = max(16, height); if outputKeepAspect { w = max(16, h * ratio) } }
        await applyOutputSize(CGSize(width: w, height: h))
    }
    func setOutputScale(_ k: Double) async { await applyOutputSize(CGSize(width: sourceSize.width * k, height: sourceSize.height * k)) }
    func resetOutputSize() async { await applyOutputTransform(size: nil, rotation: 0) }
    func setOutputRotation(_ d: Double) async { await applyOutputTransform(size: outputSize, rotation: d) }
    func rotateOutput(by d: Double) async { await setOutputRotation(outputRotation + d) }

    private func applyOutputSize(_ s: CGSize?) async { await applyOutputTransform(size: s, rotation: outputRotation) }

    /// Durante um gesto com o rato: só os valores (as alças seguem); o vídeo refaz-se ao largar (`commitOutputTransform`).
    func setOutputTransformLive(size: CGSize, rotation: Double) {
        outputSize = Self.cleanSize(size, natural: sourceSize)
        outputRotation = Geometry.normalizedDegrees(rotation)
    }
    func commitOutputTransform() async { saveEdit(); await rebuildPlayer(at: playhead) }

    private static func cleanSize(_ s: CGSize, natural: CGSize) -> CGSize? {
        let n = CGSize(width: max(16, (s.width / 2).rounded() * 2), height: max(16, (s.height / 2).rounded() * 2))
        return (abs(n.width - natural.width) < 1 && abs(n.height - natural.height) < 1) ? nil : n
    }

    private func applyOutputTransform(size: CGSize?, rotation: Double) async {
        let next = size.flatMap { Self.cleanSize($0, natural: sourceSize) }
        let rot = Geometry.normalizedDegrees(rotation)
        guard next != outputSize || rot != outputRotation else { return }
        outputSize = next; outputRotation = rot
        saveEdit()
        await rebuildPlayer(at: playhead)
    }

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

    /// Muda de sítio o trecho marcado (nas linhas escolhidas) para começar perto de `newStart`. Sem `insert`, onde estava fica um espaço
    /// e no destino substitui o que lá estiver; com `insert`, o espaço de origem fecha e o destino dá lugar.
    func moveSelection(to newStart: Double, insert: Bool) async {
        guard let sel = selection, !mask.isEmpty else { return }
        let before = snapshot()
        var next = timeline
        // inserir nunca parte um clipe: o bloco vai para a junção mais próxima
        let target = insert ? next.snapDrop(sel, tracks: mask, start: newStart) : newStart
        if insert, abs(target - sel.start) < 1e-6 || abs(target - sel.end) < 1e-6 { return }
        guard let at = next.move(sel, tracks: mask, to: target, ripple: insert) else { return }
        timeline = next
        selection = TimeSpan(start: at, end: at + sel.length)
        previewLabel = nil
        await commit(before, at: at)
    }

    /// Insere uma quebra no instante `t` (por omissão na posição de reprodução) nas linhas `lanes` (por omissão as escolhidas):
    /// o clipe divide-se em dois sem cortar nada, para cada parte se poder marcar e mover à parte.
    func insertBreak(at t: Double? = nil, lanes: Set<EditTrack>? = nil) async {
        let at = t ?? playhead
        let before = snapshot()
        var next = timeline
        guard next.split(at: at, tracks: lanes ?? mask) else { message = L("Não dá para pôr uma quebra aqui: não há clipe, ou está colada a uma ponta."); return }
        timeline = next
        await commit(before, at: at)
    }

    /// Marca o clipe (ou o espaço) da linha `lane` que está no instante `t`.
    func selectPart(at t: Double, in lane: EditTrack) {
        selectionLanes = [lane]
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

    private struct EditFile: Codable { var timeline: EditTimeline; var media: [String: String]; var nextMedia: Int; var enabled: [String]?; var locked: [String]?; var outputWidth: Double?; var outputHeight: Double?; var outputRotation: Double?; var overlays: [VideoOverlay]?; var volumes: [String: Double]?; var fades: [String: Double]? }

    private func saveEdit() {
        if timeline.isEdited || enabled.count != timeline.tracks.count || !locked.isEmpty || isOutputTransformed || hasOverlays || !laneVolume.isEmpty || !laneFade.isEmpty {
            try? FileManager.default.createDirectory(at: editFolder, withIntermediateDirectories: true)
            let f = EditFile(timeline: timeline, media: Dictionary(uniqueKeysWithValues: media.filter { $0.key != 0 }.map { (String($0.key), $0.value.lastPathComponent) }), nextMedia: nextMedia,
                             enabled: enabled.map(\.rawValue).sorted(), locked: locked.map(\.rawValue).sorted(), outputWidth: outputSize.map { Double($0.width) }, outputHeight: outputSize.map { Double($0.height) }, outputRotation: outputRotation == 0 ? nil : outputRotation,
                             overlays: overlays.isEmpty ? nil : overlays,
                             volumes: laneVolume.isEmpty ? nil : Dictionary(uniqueKeysWithValues: laneVolume.map { ($0.key.rawValue, $0.value) }),
                             fades: laneFade.isEmpty ? nil : Dictionary(uniqueKeysWithValues: laneFade.map { ($0.key.rawValue, $0.value) }))
            try? JSONEncoder().encode(f).write(to: editFile, options: .atomic)
        } else if overlayEditor == nil && !VideoFiles.isPackage(url) { try? FileManager.default.removeItem(at: editFolder) }   // (pasta .edicao de um vídeo solto; com o editor das anotações aberto fica)
        else { try? FileManager.default.removeItem(at: editFile) }   // (num pacote, só o ficheiro da edição: o vídeo vive lá dentro)
    }

    /// Volta a ler a edição guardada (se houver e for deste vídeo).
    private func loadSaved() {
        guard let data = try? Data(contentsOf: editFile), let f = try? JSONDecoder().decode(EditFile.self, from: data),
              abs(f.timeline.sourceDuration - timeline.sourceDuration) < 0.5, f.timeline.tracks.starts(with: timeline.tracks) else { return }
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
        if let w = f.outputWidth, let h = f.outputHeight, w >= 16, h >= 16 { outputSize = CGSize(width: w, height: h) }
        if let r = f.outputRotation { outputRotation = Geometry.normalizedDegrees(r) }
        if let v = f.volumes { laneVolume = Dictionary(uniqueKeysWithValues: v.compactMap { k, val in EditTrack(rawValue: k).map { ($0, val) } }) }
        if let fd = f.fades { laneFade = Dictionary(uniqueKeysWithValues: fd.compactMap { k, val in EditTrack(rawValue: k).map { ($0, val) } }) }
        if let o = f.overlays, !o.isEmpty, overlayEditor == nil, FileManager.default.fileExists(atPath: overlayPackage.path) {
            overlays = o
            // as anotações desenham-se desde a abertura: o editor carrega-se já (sem entrar no modo Anotar)
            if let m = try? EditorModel(url: overlayPackage) {
                m.isVideoOverlay = true; m.tool = .arrow
                m.mutate { $0.autoExpand = false; $0.workArea = nil }
                m.onCreated = { [weak self] id in self?.overlayCreated(id) }
                m.onSaved = { [weak self] in self?.syncOverlays() }
                overlayEditor = m
                overlays = o.filter { ov in m.doc.annotations.contains { $0.id == ov.id } }
                overlayProvider.update(doc: m.doc, overlays: overlays, assets: m.assets)
            } else { overlays = [] }
        }
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

    /// Escreve o vídeo já editado num pacote novo (`…_editado.tothvideo`, na pasta das capturas) e devolve-o.
    func exportEdited() async throws -> URL {
        working = L("A guardar o vídeo…"); defer { working = nil }
        let (comp, mix, vc) = try await finalComposition()
        let base = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_editado", with: "")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("Toth-editado-\(UUID().uuidString).mp4")
        try await VideoExporter.export(composition: comp, videoComposition: vc, audioMix: mix, to: tmp)
        return try VideoFiles.makePackage(from: tmp, move: true, name: "\(base)_editado")
    }

    /// A composição final (cortes, tamanho, rotação, volumes, velocidade e anotações), como vai para o ficheiro.
    func finalComposition() async throws -> (AVMutableComposition, AVAudioMix?, AVVideoComposition?) {
        let (comp, mix, vc0) = try await VideoComposer.build(timeline: timeline, tracks: tracks, mediaLength: mediaLength, enabled: enabled, renderSize: outputSize, rotation: outputRotation, volumes: laneVolume, fades: laneFade)
        return (comp, mix, vc0.map { hasOverlays ? OverlayCompositor.wrap($0, provider: overlayProvider) : $0 })
    }

    /// Guarda o vídeo editado como GIF animado (10 imagens por segundo, até 640 px de largura).
    func exportGIF(to out: URL) async throws {
        working = L("A guardar o GIF…"); defer { working = nil }
        let (comp, _, vc) = try await finalComposition()
        try await VideoExporter.exportGIF(composition: comp, videoComposition: vc, to: out)
    }

    /// Guarda só o áudio (misturado, com volumes e fades) em M4A.
    func exportAudio(to out: URL) async throws {
        working = L("A guardar o áudio…"); defer { working = nil }
        let (comp, mix, _) = try await finalComposition()
        try await VideoExporter.exportAudio(composition: comp, audioMix: mix, to: out)
    }
}
