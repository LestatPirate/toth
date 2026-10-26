// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AVFoundation
import AppKit
import CaptureCore
import CoreMedia
import CoreVideo
import ScreenCaptureKit

// Gravação de vídeo do ecrã (MP4: vídeo H.264 e áudio AAC).
//
// - `RecordingEngine`: recebe fotogramas e áudio (com a hora do relógio do sistema), trata das pausas, mistura o áudio do
//   sistema e do microfone numa só faixa (qualquer um pode ser ligado ou desligado a qualquer momento) e escreve o MP4.
//   Não conhece o ecrã nem o microfone: por isso testa-se com fotogramas e sons sintéticos.
// - `ScreenRecordingSource`: a captura real (ScreenCaptureKit: vídeo, áudio do sistema e microfone).

/// Hora do relógio do sistema, em segundos (a mesma que o ScreenCaptureKit usa nas suas imagens e áudio).
func hostSeconds() -> Double { CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) }

final class RecordingEngine: @unchecked Sendable {
    enum Failure: LocalizedError {
        case noVideo
        case writer(String)
        var errorDescription: String? {
            switch self {
            case .noVideo: L("Não chegou nenhuma imagem do ecrã: o vídeo ficou vazio.")
            case let .writer(m): L("Não foi possível escrever o vídeo: %@", m)
            }
        }
    }

    let url: URL
    let width: Int, height: Int
    /// Relógio (em segundos). Os testes põem aqui um relógio simulado.
    var now: () -> Double = hostSeconds

    private let queue = DispatchQueue(label: "pt.toth.recording")
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput
    private var mixer: AudioMixer
    private var timer: DispatchSourceTimer?

    // linha do tempo
    private var startHost: Double?             // hora (do sistema) do 1.º fotograma
    private var intervals: [(from: Double, to: Double?)] = []   // pausas
    private var lastVideoPTS: Double = -1
    private var started = false, finished = false, failed: String?
    private var framesWritten = 0

    private var nextFrame: [AudioSource: Int64] = [:]
    private var converters: [AudioSource: (AVAudioConverter, AVAudioFormat)] = [:]
    private static let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!

    /// - Parameter fps: taxa esperada (só orienta o codificador; o ecrã parado não gera imagens).
    init(url: URL, width: Int, height: Int, fps: Int = 30, system: Bool, microphone: Bool) throws {
        self.url = url; self.width = width; self.height = height
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let bits = max(1_500_000, min(40_000_000, Int(Double(width * height) * 3.0)))   // ~3 bits por píxel e segundo
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bits, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: fps * 2, AVVideoExpectedSourceFrameRateKey: fps, AVVideoAllowFrameReorderingKey: false,
            ] as [String: Any],
        ])
        videoInput.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000,
        ])
        audioInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else { throw Failure.writer("formato não suportado") }
        writer.add(videoInput); writer.add(audioInput)
        mixer = AudioMixer(system: system, microphone: microphone)
    }

    // MARK: Controlo

    func start(pump: Bool = true) {
        queue.sync {
            guard !started else { return }
            started = true
            guard writer.startWriting() else { failed = writer.error?.localizedDescription ?? "?"; return }
            if pump {
                let t = DispatchSource.makeTimerSource(queue: queue)
                t.schedule(deadline: .now() + 0.05, repeating: 0.05)
                t.setEventHandler { [weak self] in self?.pumpLocked() }
                t.resume(); timer = t
            }
        }
    }

    func pause() { queue.sync { if intervals.last?.to != nil || intervals.isEmpty { intervals.append((now(), nil)) } } }

    func resume() {
        queue.sync {
            guard let last = intervals.last, last.to == nil else { return }
            intervals[intervals.count - 1].to = now()
        }
    }

    var isPaused: Bool { queue.sync { intervals.last?.to == nil && !intervals.isEmpty } }

    func setEnabled(_ s: AudioSource, _ on: Bool) { queue.sync { mixer.setEnabled(s, on); nextFrame[s] = nil } }
    func isEnabled(_ s: AudioSource) -> Bool { queue.sync { mixer.isEnabled(s) } }

    /// Tempo gravado até agora (sem as pausas), em segundos.
    func elapsed() -> Double { queue.sync { startHost.map { adjusted(now()) ?? pausedAdjusted($0) } ?? 0 } }

    // MARK: Linha do tempo

    /// Hora gravada (sem pausas) de um instante do relógio; `nil` se cai dentro de uma pausa.
    private func adjusted(_ t: Double) -> Double? {
        guard let s = startHost else { return nil }
        var skipped = 0.0
        for iv in intervals {
            if t >= iv.from && (iv.to == nil || t < iv.to!) { return nil }
            if let to = iv.to, to <= t { skipped += to - iv.from }
        }
        return t - s - skipped
    }

    /// Durante uma pausa, o tempo gravado fica parado no início dessa pausa.
    private func pausedAdjusted(_ s: Double) -> Double {
        guard let iv = intervals.last, iv.to == nil else { return 0 }
        return adjusted(iv.from - 1e-6) ?? 0
    }

    // MARK: Entrada

    func ingestVideo(_ pb: CVPixelBuffer, hostPTS: Double) {
        queue.async { [self] in
            guard started, !finished, failed == nil else { return }
            if startHost == nil { startHost = hostPTS; writer.startSession(atSourceTime: .zero) }
            guard let t = adjusted(hostPTS), t > lastVideoPTS, videoInput.isReadyForMoreMediaData else { return }
            if adaptor.append(pb, withPresentationTime: CMTime(seconds: t, preferredTimescale: 90_000)) {
                lastVideoPTS = t; framesWritten += 1
            } else if writer.status == .failed { failed = writer.error?.localizedDescription ?? "?" }
            mixer.advance(toFrame: Int64(t * 48_000))
            drainAudio()
        }
    }

    /// Áudio já em estéreo intercalado a 48 kHz (ver `AudioConversion`).
    func ingestAudio(_ source: AudioSource, samples: [Float], hostPTS: Double) {
        queue.async { [self] in
            guard started, !finished, failed == nil, let t = adjusted(hostPTS) else { return }
            var start = Int64((t * 48_000).rounded())
            // Cada fonte é um fluxo contínuo: os blocos entram seguidos (a conversão de frequência devolve um número de
            // amostras que varia de bloco para bloco, e pô-los pela hora deixaria silêncios). Só se volta a sincronizar
            // pela hora quando há um salto maior que 100 ms (por exemplo, depois de uma pausa).
            if let next = nextFrame[source], abs(start - next) < 4_800 { start = next }
            nextFrame[source] = start + Int64(samples.count / 2)
            mixer.push(source, samples: samples, startFrame: start)
            drainAudio()
        }
    }

    /// Converte e entrega um bloco de áudio do ScreenCaptureKit.
    func ingestAudio(_ source: AudioSource, sampleBuffer sb: CMSampleBuffer) {
        guard let samples = AudioConversion.stereo48k(sb, converter: converterFor(source, sb)) else { return }
        ingestAudio(source, samples: samples, hostPTS: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb)))
    }

    private let convLock = NSLock()
    private func converterFor(_ s: AudioSource, _ sb: CMSampleBuffer) -> (AudioFormatKey) -> AVAudioConverter? {
        { [self] key in
            convLock.lock(); defer { convLock.unlock() }
            if let (c, f) = converters[s], f.isEqual(key.format) { return c }
            guard let c = AVAudioConverter(from: key.format, to: Self.target) else { return nil }
            converters[s] = (c, key.format)
            return c
        }
    }

    // MARK: Saída

    private func pumpLocked() {
        guard started, !finished, startHost != nil else { return }
        if let t = adjusted(now()) { mixer.advance(toFrame: Int64(t * 48_000)) }
        drainAudio()
    }

    /// Para testes: avança o relógio do áudio como o temporizador faria.
    func pump() { queue.sync { pumpLocked() } }

    private func drainAudio() {
        for chunk in mixer.pop() { writeAudio(chunk.samples, frame: chunk.frame) }
    }

    private func writeAudio(_ samples: [Float], frame: Int64) {
        guard audioInput.isReadyForMoreMediaData, let sb = AudioConversion.sampleBuffer(from: samples, startFrame: frame) else { return }
        if !audioInput.append(sb), writer.status == .failed { failed = writer.error?.localizedDescription ?? "?" }
    }

    /// Termina o ficheiro. `discard`: apaga-o em vez de o guardar.
    func finish(discard: Bool = false) async throws {
        let outcome: Result<Void, Error> = await withCheckedContinuation { cont in
            queue.async { [self] in
                timer?.cancel(); timer = nil
                guard started, !finished else { cont.resume(returning: .success(())); return }
                finished = true
                if discard || startHost == nil || framesWritten == 0 {
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: url)
                    cont.resume(returning: discard ? .success(()) : .failure(Failure.noVideo)); return
                }
                let end = max(lastVideoPTS, adjusted(now()) ?? pausedAdjusted(startHost!))
                mixer.advance(toFrame: Int64(end * 48_000))
                for chunk in mixer.pop(flush: true) { writeAudio(chunk.samples, frame: chunk.frame) }
                videoInput.markAsFinished(); audioInput.markAsFinished()
                writer.endSession(atSourceTime: CMTime(seconds: max(end, lastVideoPTS), preferredTimescale: 90_000))
                writer.finishWriting {
                    if self.writer.status == .completed { cont.resume(returning: .success(())) }
                    else { cont.resume(returning: .failure(Failure.writer(self.writer.error?.localizedDescription ?? "?"))) }
                }
            }
        }
        if case let .failure(e) = outcome { throw e }
        if let f = failed { throw Failure.writer(f) }
    }
}

// MARK: - Áudio: conversão

struct AudioFormatKey { let format: AVAudioFormat }

enum AudioConversion {
    /// Bloco do ScreenCaptureKit → estéreo intercalado a 48 kHz (converte frequência e canais se for preciso).
    static func stereo48k(_ sb: CMSampleBuffer, converter: (AudioFormatKey) -> AVAudioConverter?) -> [Float]? {
        guard let fd = CMSampleBufferGetFormatDescription(sb), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd),
              let format = AVAudioFormat(streamDescription: asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard frames > 0, let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        input.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames), into: input.mutableAudioBufferList) == noErr else { return nil }
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        var out = input
        if !(format.commonFormat == .pcmFormatFloat32 && format.sampleRate == 48_000 && format.channelCount == 2 && !format.isInterleaved) {
            guard let conv = converter(AudioFormatKey(format: format)) else { return nil }
            let cap = AVAudioFrameCount(Double(frames) * 48_000 / format.sampleRate) + 64
            guard let dst = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return nil }
            var fed = false
            var err: NSError?
            conv.convert(to: dst, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return input
            }
            guard err == nil else { return nil }
            out = dst
        }
        guard let ch = out.floatChannelData else { return nil }
        let n = Int(out.frameLength)
        var samples = [Float](repeating: 0, count: n * 2)
        let left = ch[0], right = out.format.channelCount > 1 ? ch[1] : ch[0]
        for i in 0..<n { samples[2 * i] = left[i]; samples[2 * i + 1] = right[i] }
        return samples
    }

    /// Estéreo intercalado a 48 kHz → bloco de áudio do sistema (para o escritor), com o 1.º frame em `startFrame`.
    static func sampleBuffer(from samples: [Float], startFrame: Int64) -> CMSampleBuffer? {
        let frames = samples.count / 2
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
                                               mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var fd: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                             extensions: nil, formatDescriptionOut: &fd) == noErr, let fd else { return nil }
        let bytes = samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block) == noErr, let block else { return nil }
        guard samples.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }) == noErr else { return nil }
        var sb: CMSampleBuffer?
        let pts = CMTime(value: startFrame, timescale: 48_000)
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: fd, sampleCount: frames,
                                                                    presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }
}

// MARK: - Permissão do microfone

enum MicrophonePermission {
    static var status: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }
    static var isGranted: Bool { status == .authorized }

    /// Pede a permissão se ainda não foi decidida (o macOS mostra o seu aviso). `true` se pode usar o microfone.
    static func request() async -> Bool {
        switch status {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
}

// MARK: - Captura real do ecrã

/// Vídeo, áudio do sistema e microfone do ScreenCaptureKit, entregues ao `RecordingEngine`.
final class ScreenRecordingSource: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private let engine: RecordingEngine
    private var config = SCStreamConfiguration()
    var onStop: ((Error?) -> Void)?

    init(engine: RecordingEngine) { self.engine = engine }

    /// Tamanho em píxeis a gravar: o da área (em píxeis do ecrã), reduzido se passar do que o H.264 aceita, e par.
    static func videoSize(for rect: CGRect, scale: CGFloat) -> (width: Int, height: Int) {
        var w = rect.width * scale, h = rect.height * scale
        let k = min(1, 4096 / w, 2304 / h)
        w *= k; h *= k
        return (max(2, Int(w) / 2 * 2), max(2, Int(h) / 2 * 2))
    }

    func start(screen: NSScreen, rect: CGRect, microphone: Bool) async throws {
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == id }) else { throw ScreenCapturer.Failure.displayNotFound }
        let own = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingWindows: own)
        let c = SCStreamConfiguration()
        c.sourceRect = rect
        c.width = engine.width; c.height = engine.height
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        c.queueDepth = 6
        c.showsCursor = true
        c.capturesAudio = true
        c.excludesCurrentProcessAudio = true
        c.sampleRate = 48_000; c.channelCount = 2
        if microphone { c.captureMicrophone = true }
        config = c
        let s = SCStream(filter: filter, configuration: c, delegate: self)
        let q = DispatchQueue(label: "pt.toth.recording.frames")
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: q)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: q)
        try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: q)
        try await s.startCapture()
        stream = s
    }

    /// Liga o microfone com a gravação já a correr (depois de a permissão ser dada).
    func enableMicrophone() async {
        guard let s = stream, !config.captureMicrophone else { return }
        config.captureMicrophone = true
        try? await s.updateConfiguration(config)
    }

    func stop() async { try? await stream?.stopCapture(); stream = nil }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid else { return }
        switch type {
        case .screen:
            guard let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = atts.first?[.status] as? Int, raw == SCFrameStatus.complete.rawValue,
                  let pb = CMSampleBufferGetImageBuffer(sb) else { return }
            engine.ingestVideo(pb, hostPTS: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb)))
        case .audio: engine.ingestAudio(.system, sampleBuffer: sb)
        case .microphone: engine.ingestAudio(.microphone, sampleBuffer: sb)
        @unknown default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { onStop?(error) }
}
