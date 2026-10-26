// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AVFoundation
import AppKit
import CaptureCore
import CoreVideo

/// Autoteste da gravação de vídeo com fotogramas e sons sintéticos e um relógio simulado (sem ecrã nem microfone).
enum VideoSelfTest {
    static func pixelBuffer(_ w: Int, _ h: Int, frame n: Int) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        let buf = pb!
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self), bpr = CVPixelBufferGetBytesPerRow(buf)
        for y in 0..<h { for x in 0..<w {
            let i = y * bpr + x * 4
            base[i] = UInt8((n * 3) & 255); base[i + 1] = UInt8((y * 255) / h); base[i + 2] = UInt8((x * 255) / w); base[i + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return buf
    }

    static func tone(_ f: Double, fromSec t0: Double, frames: Int, amp: Float = 0.4) -> [Float] {
        var out = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames { let v = amp * Float(sin(2 * Double.pi * f * (t0 + Double(i) / 48_000))); out[2 * i] = v; out[2 * i + 1] = v }
        return out
    }

    static func goertzel(_ s: ArraySlice<Float>, _ f: Double) -> Double {
        guard !s.isEmpty else { return 0 }
        let k = 2 * cos(2 * Double.pi * f / 48_000)
        var a = 0.0, b = 0.0
        for x in s { let n = Double(x) + k * a - b; b = a; a = n }
        return (a * a + b * b - k * a * b) / Double(s.count * s.count)
    }

    static func run(dir: URL) async -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { fails.append(what) } }
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("teste.mp4")
        let W = 640, H = 360

        do {
            let engine = try RecordingEngine(url: url, width: W, height: H, system: true, microphone: true)
            var t = 1000.0                         // relógio simulado (segundos)
            engine.now = { t }
            engine.start(pump: false)

            // Linha do tempo (relógio): 0–1 s ambos; 1 s microfone desligado; 1,5–2,5 s PAUSA; 2,7 s microfone ligado; fim aos 3,5 s
            let t0 = t
            var sentAudio = 0.0                    // até onde já se entregou áudio (segundos de relógio)
            var n = 0
            var step = 0.0
            while step < 3.5 - 1e-9 {
                t = t0 + step
                if abs(step - 1.0) < 1e-6 { engine.setEnabled(.microphone, false) }
                if abs(step - 1.5) < 1e-6 { engine.pause() }
                if abs(step - 2.5) < 1e-6 { engine.resume() }
                if step >= 2.7 - 1e-6 && !engine.isEnabled(.microphone) { engine.setEnabled(.microphone, true) }
                engine.ingestVideo(pixelBuffer(W, H, frame: n), hostPTS: t); n += 1
                // áudio (continua a chegar durante a pausa: tem de ser ignorado)
                while sentAudio + 1024.0 / 48_000 <= step + 1.0 / 30 {
                    engine.ingestAudio(.system, samples: tone(440, fromSec: sentAudio, frames: 1024), hostPTS: t0 + sentAudio)
                    engine.ingestAudio(.microphone, samples: tone(880, fromSec: sentAudio, frames: 1024), hostPTS: t0 + sentAudio)
                    sentAudio += 1024.0 / 48_000
                }
                engine.pump()
                step += 1.0 / 30
            }
            t = t0 + 3.5
            try await engine.finish()
            check(FileManager.default.fileExists(atPath: url.path), "o MP4 não foi criado")

            // ---- ler o ficheiro
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            let vtracks = try await asset.loadTracks(withMediaType: .video), atracks = try await asset.loadTracks(withMediaType: .audio)
            check(vtracks.count == 1 && atracks.count == 1, "faixas: \(vtracks.count) de vídeo e \(atracks.count) de áudio (esperava 1 e 1)")
            check(abs(duration - 2.5) < 0.3, "duração \(String(format: "%.2f", duration)) s, esperada ≈ 2,5 s (3,5 s menos 1 s de pausa)")
            if let v = vtracks.first {
                let size = try await v.load(.naturalSize)
                check(Int(size.width) == W && Int(size.height) == H, "tamanho do vídeo \(size)")
            }
            // número de fotogramas
            if let v = vtracks.first, let reader = try? AVAssetReader(asset: asset) {
                let out = AVAssetReaderTrackOutput(track: v, outputSettings: nil)
                reader.add(out); reader.startReading()
                var count = 0
                while out.copyNextSampleBuffer() != nil { count += 1 }
                check((60...85).contains(count), "fotogramas \(count), esperava ≈ 75 (os da pausa não contam)")
            }
            // áudio descodificado
            var pcm: [Float] = []
            if let a = atracks.first, let reader = try? AVAssetReader(asset: asset) {
                let out = AVAssetReaderTrackOutput(track: a, outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2])
                reader.add(out); reader.startReading()
                while let sb = out.copyNextSampleBuffer() {
                    guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
                    var len = 0; var ptr: UnsafeMutablePointer<Int8>?
                    CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
                    if let ptr { pcm += Array(UnsafeBufferPointer(start: UnsafeRawPointer(ptr).assumingMemoryBound(to: Float.self), count: len / 4)) }
                }
            }
            func seg(_ a: Double, _ b: Double, _ f: Double) -> Double {
                var left: [Float] = []
                let i0 = Int(a * 48_000), i1 = min(Int(b * 48_000), pcm.count / 2)
                if i1 > i0 { for i in i0..<i1 { left.append(pcm[2 * i]) } }
                return goertzel(left[...], f)
            }
            check(pcm.count / 2 >= 48_000 * 2, "áudio curto: \(pcm.count / 2) frames")
            // tempo gravado (sem pausa): 0–1 s ambos; 1–1,5 s só sistema; 1,5–1,7 só sistema; 1,7–2,5 s ambos
            let sys = [seg(0.2, 0.9, 440), seg(1.1, 1.4, 440), seg(1.55, 1.65, 440), seg(1.9, 2.4, 440)]
            let micOn = [seg(0.2, 0.9, 880), seg(1.9, 2.4, 880)], micOff = [seg(1.1, 1.4, 880), seg(1.55, 1.65, 880)]
            check(sys.allSatisfy { $0 > 0.004 }, "o áudio do sistema devia estar sempre presente: \(sys)")
            check(micOn.allSatisfy { $0 > 0.004 }, "o microfone devia estar presente quando ligado: \(micOn)")
            check(micOff.allSatisfy { $0 < 0.0008 }, "o microfone devia estar ausente quando desligado: \(micOff)")
        } catch { fails.append("exceção: \(error)") }

        // cancelar apaga o ficheiro
        do {
            let u2 = dir.appendingPathComponent("cancelado.mp4")
            let e = try RecordingEngine(url: u2, width: 320, height: 180, system: false, microphone: false)
            e.start(pump: false)
            e.ingestVideo(pixelBuffer(320, 180, frame: 0), hostPTS: 5)
            try await e.finish(discard: true)
            check(!FileManager.default.fileExists(atPath: u2.path), "cancelar devia apagar o ficheiro")
            // sem imagens: erro claro
            let u3 = dir.appendingPathComponent("vazio.mp4")
            let e3 = try RecordingEngine(url: u3, width: 320, height: 180, system: false, microphone: false)
            e3.start(pump: false)
            do { try await e3.finish(); fails.append("sem imagens devia dar erro") } catch {}
        } catch { fails.append("exceção (cancelar): \(error)") }

        // fluxo contínuo: blocos de tamanho variável (como a conversão de frequência devolve) não podem deixar silêncios entre si
        do {
            let u = dir.appendingPathComponent("continuo.mp4")
            let e = try RecordingEngine(url: u, width: 160, height: 90, system: false, microphone: true)
            var t = 2000.0
            e.now = { t }
            e.start(pump: false)
            let sizes = [20_480, 27_520, 21_000, 27_000, 24_000, 24_000]   // como a conversão de frequência: varia por bloco, a soma converge
            var sentBlocks = 0, cumulative = 0, step = 0.0
            while step < 2.0 {
                t = 2000.0 + step
                e.ingestVideo(pixelBuffer(160, 90, frame: Int(step * 30)), hostPTS: t)
                while Double(sentBlocks) * 0.5 <= step && sentBlocks < sizes.count {            // um bloco a cada 0,5 s
                    let n = sizes[sentBlocks]
                    e.ingestAudio(.microphone, samples: tone(880, fromSec: Double(cumulative) / 48_000, frames: n), hostPTS: 2000.0 + Double(sentBlocks) * 0.5)
                    cumulative += n; sentBlocks += 1
                }
                e.pump(); step += 1.0 / 30
            }
            t = 2002.0
            try await e.finish()
            let asset = AVURLAsset(url: u)
            if let a = try? await asset.loadTracks(withMediaType: .audio).first, let reader = try? AVAssetReader(asset: asset) {
                let out = AVAssetReaderTrackOutput(track: a, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                                                                              AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2])
                reader.add(out); reader.startReading()
                var pcm: [Float] = []
                while let sb = out.copyNextSampleBuffer() {
                    guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
                    var len = 0; var ptr: UnsafeMutablePointer<Int8>?
                    CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
                    if let ptr { pcm += Array(UnsafeBufferPointer(start: UnsafeRawPointer(ptr).assumingMemoryBound(to: Float.self), count: len / 4)) }
                }
                // maior trecho (em frames) com som muito baixo, ignorando o início (preenchimento do codificador) e o fim
                var run = 0, longest = 0
                for i in stride(from: 2 * 4_800, to: min(pcm.count, 2 * 90_000), by: 2) { if abs(pcm[i]) < 0.01 { run += 1; longest = max(longest, run) } else { run = 0 } }
                check(longest < 200, "o fluxo contínuo tem um silêncio de \(longest) amostras (devia ser contínuo)")
            } else { fails.append("sem áudio no teste contínuo") }
        } catch { fails.append("exceção (contínuo): \(error)") }

        // conversão do áudio do microfone: mono a 44,1 kHz e estéreo a 48 kHz → estéreo intercalado a 48 kHz
        for (rate, channels) in [(44_100.0, 1), (48_000.0, 2), (16_000.0, 1)] {
            let n = Int(rate * 0.5)
            var data = [Float](repeating: 0, count: n * channels)
            for i in 0..<n { let v = 0.4 * Float(sin(2 * Double.pi * 440 * Double(i) / rate)); for c in 0..<channels { data[i * channels + c] = v } }
            var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                   mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
                                                   mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
            var fd: CMAudioFormatDescription?
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fd)
            let bytes = data.count * 4
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block)
            if let block { _ = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) } }
            var sb: CMSampleBuffer?
            if let fd, let block { CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: fd, sampleCount: n, presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sb) }
            guard let sb else { fails.append("sem bloco de teste a \(rate) Hz"); continue }
            let engine = try? RecordingEngine(url: dir.appendingPathComponent("c.mp4"), width: 64, height: 64, system: false, microphone: true)
            var converters: [String: AVAudioConverter] = [:]
            let out = AudioConversion.stereo48k(sb) { key in
                let id = "\(key.format.sampleRate)-\(key.format.channelCount)"
                if let c = converters[id] { return c }
                let c = AVAudioConverter(from: key.format, to: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!)
                if let c { converters[id] = c }
                return c
            }
            _ = engine
            if let out {
                let frames = out.count / 2
                check(frames >= (rate == 48_000 ? 23_900 : 18_000) && frames <= 24_100, "\(Int(rate)) Hz/\(channels) canal(is): \(frames) frames")
                check(goertzel(out.enumerated().filter { $0.offset % 2 == 0 }.map { $0.element }[2_000..<20_000], 440) > 0.01, "\(Int(rate)) Hz: falta o tom de 440 Hz depois de converter")
                check(zip(stride(from: 0, to: out.count, by: 2), stride(from: 1, to: out.count, by: 2)).allSatisfy { abs(out[$0] - out[$1]) < 1e-6 }, "\(Int(rate)) Hz: os dois canais deviam ser iguais")
            } else { fails.append("conversão de \(Int(rate)) Hz/\(channels) canal(is) falhou") }
        }

        // tamanho: reduz o que o H.264 não aceita e mantém números pares
        let big = ScreenRecordingSource.videoSize(for: CGRect(x: 0, y: 0, width: 3440, height: 1440), scale: 2)
        check(big.width <= 4096 && big.height <= 2304 && big.width % 2 == 0 && big.height % 2 == 0, "tamanho grande \(big)")
        let small = ScreenRecordingSource.videoSize(for: CGRect(x: 0, y: 0, width: 501, height: 301), scale: 1)
        check(small.width == 500 && small.height == 300, "tamanho pequeno \(small)")
        try? FileManager.default.removeItem(at: dir)
        return fails
    }
}


/// Ponta a ponta (flag `--video-e2e`): editor do Toth aberto, outra app à frente; escolhe a área no seletor real, grava vídeo
/// (com pausa), roda a página de teste, para, e confere o MP4, o editor e a janela de topo durante a gravação.
@MainActor
enum VideoE2ETest {
    static func run(rect: CGRect, owner: String, dir: URL) async -> String {
        guard let screen = NSScreen.main else { return "sem ecrã" }
        try? FileManager.default.removeItem(at: dir)
        CaptureStore.overrideFolder = dir.appendingPathComponent("biblioteca")
        MainWindow.show()
        try? await Task.sleep(nanoseconds: 800_000_000)
        let activate = Process(); activate.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        activate.arguments = ["-e", "tell application \"\(owner)\" to activate"]
        try? activate.run(); activate.waitUntilExit()
        try? await Task.sleep(nanoseconds: 1_200_000_000)

        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let center = CGPoint(x: screen.frame.minX + rect.midX, y: primaryHeight - (screen.frame.maxY - rect.minY) + rect.height / 2)
        func topOwnerAtCenter() -> String {
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
                guard let b = w[kCGWindowBounds as String] as? [String: Double] else { continue }
                if CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0).contains(center) { return (w[kCGWindowOwnerName as String] as? String) ?? "?" }
            }
            return "nenhuma"
        }
        func scroll(_ steps: Int) async {
            CGWarpMouseCursorPosition(center)
            for _ in 0..<steps {
                for _ in 0..<8 {
                    if let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -40, wheel2: 0, wheel3: 0) { e.location = center; e.post(tap: .cghidEventTap) }
                    try? await Task.sleep(nanoseconds: 16_000_000)
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }

        guard let snap = try? await ScreenCapturer.snapshot(of: screen) else { return "sem instantâneo (permissão?)" }
        var owners: [String] = []
        var result = "sem resultado"
        var finalURL: URL?
        let selector = RegionSelector()
        selector.onVideo = { scr, r in
            Task { @MainActor in
                let session = VideoCaptureSession(screen: scr, rect: r)
                let runTask = Task { await session.run() }
                let watcher = Task { @MainActor in
                    while !Task.isCancelled { owners.append(topOwnerAtCenter()); try? await Task.sleep(nanoseconds: 300_000_000) }
                }
                try? await Task.sleep(nanoseconds: 800_000_000)
                await session.record()
                await scroll(8)                       // ≈ 2,5 s a gravar
                session.pauseResume()                 // pausa
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                session.pauseResume()                 // retoma
                await scroll(5)                       // ≈ 1,5 s
                await session.stop()
                finalURL = await runTask.value
                watcher.cancel()
                result = finalURL == nil ? "sem ficheiro" : "ok"
            }
        }
        selector.begin(snapshots: [(screen, snap)]) { _ in }
        selector.debugPreselect(rect)
        try? await Task.sleep(nanoseconds: 500_000_000)
        let hiddenDuringSelection = !MainWindow.isVisible
        selector.debugVideo()
        for _ in 0..<120 { if result != "sem resultado" { break }; try? await Task.sleep(nanoseconds: 500_000_000) }
        guard let url = finalURL else { return result }

        // ---- ficheiro
        var report: [String] = []
        let asset = AVURLAsset(url: url)
        let dur = (try? await asset.load(.duration).seconds) ?? 0
        let v = try? await asset.loadTracks(withMediaType: .video).first, a = try? await asset.loadTracks(withMediaType: .audio).first
        var frames = 0
        if let v, let reader = try? AVAssetReader(asset: asset) {
            let out = AVAssetReaderTrackOutput(track: v, outputSettings: nil); reader.add(out); reader.startReading()
            while out.copyNextSampleBuffer() != nil { frames += 1 }
        }
        let size = (try? await v?.load(.naturalSize)) ?? .zero
        report.append("duração \(String(format: "%.1f", dur)) s, \(frames) fotogramas, vídeo \(Int(size.width))×\(Int(size.height)), áudio \(a != nil ? "sim" : "não")")
        // ---- editor
        AppState.shared.open(url)
        MainWindow.show()
        try? await Task.sleep(nanoseconds: 800_000_000)
        report.append("no editor: \(AppState.shared.videoURL == url ? "sim" : "NÃO"), na biblioteca: \(AppState.shared.library.contains { $0.url == url } ? "sim" : "NÃO")")
        let bad = owners.filter { $0 != owner }
        report.append("editor escondido durante a seleção: \(hiddenDuringSelection ? "sim" : "NÃO"); janela de topo: \(owners.count) verificações, \(bad.count) com outra janela\(bad.isEmpty ? "" : " (" + Set(bad).joined(separator: ", ") + ")")")
        report.append("ficheiro: \(url.lastPathComponent)")
        return report.joined(separator: " | ")
    }
}
