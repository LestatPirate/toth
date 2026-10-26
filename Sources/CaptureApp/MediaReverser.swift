// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AVFoundation
import AppKit
import CaptureCore
import CoreVideo

/// Gera uma versão **invertida** (a tocar de trás para a frente) de um trecho de vídeo ou de áudio, num ficheiro novo.
/// O original nunca muda. O vídeo faz-se por janelas, do fim para o princípio, para não encher a memória.
enum MediaReverser {
    enum Failure: LocalizedError {
        case noTrack, reader(String), writer(String)
        var errorDescription: String? {
            switch self {
            case .noTrack: L("O ficheiro não tem essa faixa.")
            case let .reader(m): L("Não foi possível ler o trecho: %@", m)
            case let .writer(m): L("Não foi possível escrever o trecho invertido: %@", m)
            }
        }
    }

    // MARK: Vídeo

    /// `range`: segundos da média. O resultado dura `range.length` e começa em 0.
    static func reverseVideo(asset: AVAsset, range: TimeSpan, to url: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noTrack }
        let size = try await track.load(.naturalSize)
        let w = max(2, Int(size.width) / 2 * 2), h = max(2, Int(size.height) / 2 * 2)
        let frameBytes = Double(w * h * 4)
        let window = min(4.0, max(0.25, 150_000_000 / (frameBytes * 30)))      // segundos por janela, para limitar a memória

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let bits = max(1_500_000, min(40_000_000, Int(Double(w * h) * 3.0)))
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bits, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel, AVVideoAllowFrameReorderingKey: false] as [String: Any],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        guard writer.canAdd(input) else { throw Failure.writer("formato não suportado") }
        writer.add(input)
        guard writer.startWriting() else { throw Failure.writer(writer.error?.localizedDescription ?? "?") }
        writer.startSession(atSourceTime: .zero)

        let a = range.start, b = range.end, length = range.length
        var windowEnd = b                       // fim (na média) da janela a processar
        var nextFirstPTS = b                    // onde começa o que já foi processado (o "q" do último fotograma da janela)
        var lastWritten = -1.0
        var lastBuffer: CVPixelBuffer?
        while windowEnd > a + 1e-6 {
            let windowStart = max(a, windowEnd - window)
            let frames = try await readFrames(asset: asset, track: track, from: windowStart, to: windowEnd, width: w, height: h, clampStart: a)
            // frames: (pts, buffer) por ordem crescente, com pts limitado a ≥ a; o último "mantém-se" até `nextFirstPTS`
            for i in stride(from: frames.count - 1, through: 0, by: -1) {
                let q = i + 1 < frames.count ? frames[i + 1].pts : nextFirstPTS
                let y = max(0, b - q)                                       // reflexo: o que acabava em q começa em b − q
                let t = max(y, lastWritten + 1.0 / 600)                     // sempre crescente
                while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 4_000_000) }
                if !adaptor.append(frames[i].buffer, withPresentationTime: CMTime(seconds: t, preferredTimescale: 90_000)) {
                    throw Failure.writer(writer.error?.localizedDescription ?? "?")
                }
                lastWritten = t; lastBuffer = frames[i].buffer
            }
            if let first = frames.first { nextFirstPTS = first.pts }
            windowEnd = windowStart
            progress?(1 - (windowEnd - a) / max(length, 0.001))
        }
        // mantém o último fotograma até ao fim do trecho (o ficheiro tem de durar tanto como o trecho)
        if let last = lastBuffer, lastWritten < length - 0.02 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 4_000_000) }
            _ = adaptor.append(last, withPresentationTime: CMTime(seconds: length - 0.01, preferredTimescale: 90_000))
            lastWritten = length - 0.01
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: max(length, lastWritten + 0.04), preferredTimescale: 90_000))
        await writer.finishWriting()
        if writer.status != .completed { throw Failure.writer(writer.error?.localizedDescription ?? "?") }
    }

    /// Fotogramas com `pts` em `[from, to)`; o que cobre `from` (e começou antes) entra com `pts = clampStart`/`from`.
    private static func readFrames(asset: AVAsset, track: AVAssetTrack, from: Double, to: Double, width: Int, height: Int, clampStart: Double) async throws -> [(pts: Double, buffer: CVPixelBuffer)] {
        let lead = 2.5                                                      // um pouco antes, para apanhar o fotograma que já estava no ecrã
        let start = max(0, from - lead)
        guard let reader = try? AVAssetReader(asset: asset) else { throw Failure.reader("sem leitor") }
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 90_000), end: CMTime(seconds: to, preferredTimescale: 90_000))
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        out.alwaysCopiesSampleData = true
        reader.add(out)
        guard reader.startReading() else { throw Failure.reader(reader.error?.localizedDescription ?? "?") }
        var frames: [(Double, CVPixelBuffer)] = []
        var holder: (Double, CVPixelBuffer)?                                // último fotograma antes de `from`
        while let sb = out.copyNextSampleBuffer() {
            guard let src = CMSampleBufferGetImageBuffer(sb) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            guard pts < to - 1e-9 else { continue }
            let copy = try copyBuffer(src, width: width, height: height)
            if pts < from - 1e-9 { holder = (max(pts, clampStart), copy) } else { frames.append((max(pts, clampStart), copy)) }
        }
        if let h = holder, frames.first.map({ $0.0 > from + 1e-6 }) ?? true { frames.insert((max(from, clampStart), h.1), at: 0) }
        return frames.map { (pts: $0.0, buffer: $0.1) }
    }

    private static func copyBuffer(_ src: CVPixelBuffer, width: Int, height: Int) throws -> CVPixelBuffer {
        var dst: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &dst)
        guard let dst else { throw Failure.reader("sem memória") }
        CVPixelBufferLockBaseAddress(src, .readOnly); CVPixelBufferLockBaseAddress(dst, [])
        defer { CVPixelBufferUnlockBaseAddress(src, .readOnly); CVPixelBufferUnlockBaseAddress(dst, []) }
        let sb = CVPixelBufferGetBytesPerRow(src), db = CVPixelBufferGetBytesPerRow(dst)
        let rows = min(CVPixelBufferGetHeight(src), height), bytes = min(CVPixelBufferGetWidth(src) * 4, width * 4)
        if let s = CVPixelBufferGetBaseAddress(src), let d = CVPixelBufferGetBaseAddress(dst) {
            for y in 0..<rows { memcpy(d + y * db, s + y * sb, bytes) }
        }
        return dst
    }

    // MARK: Áudio

    static func reverseAudio(asset: AVAsset, track: AVAssetTrack, range: TimeSpan, to url: URL) async throws {
        guard let reader = try? AVAssetReader(asset: asset) else { throw Failure.reader("sem leitor") }
        reader.timeRange = CMTimeRange(start: CMTime(seconds: range.start, preferredTimescale: 48_000), duration: CMTime(seconds: range.length, preferredTimescale: 48_000))
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                                                                          AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2])
        reader.add(out)
        guard reader.startReading() else { throw Failure.reader(reader.error?.localizedDescription ?? "?") }
        var pcm: [Float] = []
        while let sb = out.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            var len = 0; var ptr: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
            if let ptr { pcm += Array(UnsafeBufferPointer(start: UnsafeRawPointer(ptr).assumingMemoryBound(to: Float.self), count: len / 4)) }
        }
        // o comprimento certo (preenche com silêncio se faltar) e inverte frame a frame (não amostra a amostra: os canais ficam no sítio)
        let frames = Int((range.length * 48_000).rounded())
        if pcm.count < frames * 2 { pcm += [Float](repeating: 0, count: frames * 2 - pcm.count) }
        var rev = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames { rev[2 * i] = pcm[2 * (frames - 1 - i)]; rev[2 * i + 1] = pcm[2 * (frames - 1 - i) + 1] }

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw Failure.writer("formato não suportado") }
        writer.add(input)
        guard writer.startWriting() else { throw Failure.writer(writer.error?.localizedDescription ?? "?") }
        writer.startSession(atSourceTime: .zero)
        var f = 0
        while f < frames {
            let n = min(4_096, frames - f)
            guard let sb = AudioConversion.sampleBuffer(from: Array(rev[(2 * f)..<(2 * (f + n))]), startFrame: Int64(f)) else { throw Failure.writer("bloco de áudio") }
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            if !input.append(sb) { throw Failure.writer(writer.error?.localizedDescription ?? "?") }
            f += n
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw Failure.writer(writer.error?.localizedDescription ?? "?") }
    }
}
