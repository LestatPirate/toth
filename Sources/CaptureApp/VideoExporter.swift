// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AVFoundation
import AppKit
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

/// Escreve o vídeo editado num MP4: lê a composição (espaços a preto no vídeo e em silêncio no áudio), mistura todas as
/// faixas de áudio numa só, e codifica H.264 + AAC. Assim o ficheiro toca em qualquer leitor.
enum VideoExporter {
    enum Failure: LocalizedError {
        case nothing, io(String)
        var errorDescription: String? {
            switch self {
            case .nothing: L("Não há nada para guardar.")
            case let .io(m): L("Não foi possível guardar o vídeo: %@", m)
            }
        }
    }

    static func export(composition: AVComposition, videoComposition: AVVideoComposition?, audioMix: AVAudioMix?, to url: URL,
                       progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let videoTracks = try await composition.loadTracks(withMediaType: .video)
        let audioTracks = try await composition.loadTracks(withMediaType: .audio)
        let total = try await composition.load(.duration).seconds
        guard total > 0, !videoTracks.isEmpty || !audioTracks.isEmpty else { throw Failure.nothing }

        let reader = try AVAssetReader(asset: composition)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        try? FileManager.default.removeItem(at: url)

        var vOut: AVAssetReaderVideoCompositionOutput?, vIn: AVAssetWriterInput?
        if !videoTracks.isEmpty {
            var size = try await videoTracks[0].load(.naturalSize)
            if let rs = videoComposition?.renderSize, rs.width > 0 { size = rs }
            let w = max(2, Int(size.width) / 2 * 2), h = max(2, Int(size.height) / 2 * 2)
            let out = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            out.videoComposition = videoComposition
            let bits = max(2_000_000, min(60_000_000, Int(Double(w * h) * 6.0)))   // ~6 bits por píxel e segundo (texto nítido)
            let inp = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bits, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel, AVVideoAllowFrameReorderingKey: false] as [String: Any]])
            inp.expectsMediaDataInRealTime = false
            guard reader.canAdd(out), writer.canAdd(inp) else { throw Failure.io("formato não suportado") }
            reader.add(out); writer.add(inp); vOut = out; vIn = inp
        }
        var aOut: AVAssetReaderAudioMixOutput?, aIn: AVAssetWriterInput?
        if !audioTracks.isEmpty {
            let out = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                                                                                            AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2])
            out.audioMix = audioMix
            out.audioTimePitchAlgorithm = .spectral   // velocidade alterada: o tom mantém-se
            let inp = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000])
            inp.expectsMediaDataInRealTime = false
            guard reader.canAdd(out), writer.canAdd(inp) else { throw Failure.io("formato de áudio não suportado") }
            reader.add(out); writer.add(inp); aOut = out; aIn = inp
        }
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: total, preferredTimescale: 90_000))   // nem um fotograma para lá do fim
        guard reader.startReading() else { throw Failure.io(reader.error?.localizedDescription ?? "?") }
        guard writer.startWriting() else { throw Failure.io(writer.error?.localizedDescription ?? "?") }
        writer.startSession(atSourceTime: .zero)

        var videoDone = vIn == nil, audioDone = aIn == nil
        var lastVideo = 0.0
        while !(videoDone && audioDone) {
            var progressed = false
            if !videoDone, let vIn, let vOut, vIn.isReadyForMoreMediaData {
                if let sb = vOut.copyNextSampleBuffer() {
                    if !vIn.append(sb) { throw Failure.io(writer.error?.localizedDescription ?? "?") }
                    lastVideo = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                    progress?(min(1, lastVideo / total))
                } else { vIn.markAsFinished(); videoDone = true }
                progressed = true
            }
            if !audioDone, let aIn, let aOut, aIn.isReadyForMoreMediaData {
                if let sb = aOut.copyNextSampleBuffer() { if !aIn.append(sb) { throw Failure.io(writer.error?.localizedDescription ?? "?") } }
                else { aIn.markAsFinished(); audioDone = true }
                progressed = true
            }
            if !progressed { try await Task.sleep(nanoseconds: 3_000_000) }
            if reader.status == .failed { throw Failure.io(reader.error?.localizedDescription ?? "?") }
            if writer.status == .failed { throw Failure.io(writer.error?.localizedDescription ?? "?") }   // senão ficava à espera para sempre
        }
        writer.endSession(atSourceTime: CMTime(seconds: total, preferredTimescale: 90_000))
        await writer.finishWriting()
        if writer.status != .completed { throw Failure.io(writer.error?.localizedDescription ?? "?") }
    }

    /// GIF animado: lê a composição a `fps` imagens por segundo, reduz a `maxWidth` e escreve com repetição infinita.
    static func exportGIF(composition: AVComposition, videoComposition: AVVideoComposition?, to url: URL, fps: Double = 10, maxWidth: Int = 640) async throws {
        let videoTracks = try await composition.loadTracks(withMediaType: .video)
        let total = try await composition.load(.duration).seconds
        guard total > 0, !videoTracks.isEmpty else { throw Failure.nothing }
        let reader = try AVAssetReader(asset: composition)
        let out = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        let vc: AVMutableVideoComposition
        if let m = videoComposition?.mutableCopy() as? AVMutableVideoComposition { vc = m } else { vc = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: composition) }
        vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
        out.videoComposition = vc
        guard reader.canAdd(out) else { throw Failure.io("formato não suportado") }
        reader.add(out)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: total, preferredTimescale: 90_000))
        guard reader.startReading() else { throw Failure.io(reader.error?.localizedDescription ?? "?") }
        try? FileManager.default.removeItem(at: url)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 0, nil) else { throw Failure.io("GIF") }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / fps, kCGImagePropertyGIFUnclampedDelayTime: 1.0 / fps]] as CFDictionary
        var n = 0
        var due = 0.0   // (o leitor entrega todos os fotogramas da composição; ficam só os que caem na cadência pedida)
        while let sb = out.copyNextSampleBuffer() {
            let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            guard t + 1e-6 >= due else { continue }
            due += 1 / fps
            guard let pb = CMSampleBufferGetImageBuffer(sb), let img = OverlayCompositor.image(from: pb) else { continue }
            let k = min(1, Double(maxWidth) / Double(img.width))
            let w = max(1, Int(Double(img.width) * k)), h = max(1, Int(Double(img.height) * k))
            var small = img
            if k < 1, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.interpolationQuality = .high; ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h)); small = ctx.makeImage() ?? img
            }
            CGImageDestinationAddImage(dest, small, frameProps)
            n += 1
        }
        if reader.status == .failed { throw Failure.io(reader.error?.localizedDescription ?? "?") }
        guard n > 0, CGImageDestinationFinalize(dest) else { throw Failure.io("GIF") }
    }

    /// Só o áudio (já misturado, com volumes e fades), em M4A (AAC).
    static func exportAudio(composition: AVComposition, audioMix: AVAudioMix?, to url: URL) async throws {
        guard !(try await composition.loadTracks(withMediaType: .audio)).isEmpty else { throw Failure.nothing }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else { throw Failure.io("M4A") }
        session.audioMix = audioMix
        session.audioTimePitchAlgorithm = .spectral
        try? FileManager.default.removeItem(at: url)
        try await session.export(to: url, as: .m4a)
    }
}
