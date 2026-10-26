// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AVFoundation
import AppKit
import CoreVideo

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
            let bits = max(1_500_000, min(40_000_000, Int(Double(w * h) * 3.0)))
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
        }
        writer.endSession(atSourceTime: CMTime(seconds: total, preferredTimescale: 90_000))
        await writer.finishWriting()
        if writer.status != .completed { throw Failure.io(writer.error?.localizedDescription ?? "?") }
    }
}
