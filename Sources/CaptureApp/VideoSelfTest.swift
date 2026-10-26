// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AVFoundation
import AppKit
import CaptureCore
import CoreVideo
import SwiftUI

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
            check(vtracks.count == 1 && atracks.count == 3, "faixas: \(vtracks.count) de vídeo e \(atracks.count) de áudio (esperava 1 e 3: mistura, sistema, microfone)")
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
            func decodeTrack(_ a: AVAssetTrack) -> [Float] {
                var pcm: [Float] = []
                guard let reader = try? AVAssetReader(asset: asset) else { return pcm }
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
                return pcm
            }
            let enabledFlags = try await atracks.asyncMap { try await $0.load(.isEnabled) }
            check(enabledFlags == [true, false, false], "a mistura devia estar ativa e as faixas separadas desativadas: \(enabledFlags)")
            var pcm: [Float] = atracks.first.map(decodeTrack) ?? []
            let sysPCM = atracks.count > 1 ? decodeTrack(atracks[1]) : [], micPCM = atracks.count > 2 ? decodeTrack(atracks[2]) : []
            func segIn(_ p: [Float], _ a: Double, _ b: Double, _ f: Double) -> Double {
                var left: [Float] = []
                let i0 = Int(a * 48_000), i1 = min(Int(b * 48_000), p.count / 2)
                if i1 > i0 { for i in i0..<i1 { left.append(p[2 * i]) } }
                return goertzel(left[...], f)
            }
            // faixas separadas: o sistema só tem 440 Hz (sempre); o microfone só tem 880 Hz (quando ligado)
            check(segIn(sysPCM, 0.2, 0.9, 440) > 0.004 && segIn(sysPCM, 1.1, 1.4, 440) > 0.004 && segIn(sysPCM, 0.2, 2.4, 880) < 0.0008, "faixa do sistema: só devia ter o seu tom")
            check(segIn(micPCM, 0.2, 0.9, 880) > 0.004 && segIn(micPCM, 1.9, 2.4, 880) > 0.004, "faixa do microfone devia ter o seu tom quando ligado")
            check(segIn(micPCM, 1.1, 1.4, 880) < 0.0008 && segIn(micPCM, 1.1, 1.4, 440) < 0.0008, "faixa do microfone devia estar muda quando desligado e nunca ter o tom do sistema")
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
        // ---- editar a gravação real: linhas, cortar, inverter e guardar
        let editor = VideoEditorModel(url: url)
        await editor.load()
        let full = editor.duration
        let lanes = editor.timeline.tracks.map(\.rawValue).joined(separator: "+")
        editor.selection = TimeSpan(start: 1.0, end: 2.5)
        await editor.cut(join: true)
        let cutDur = editor.duration
        editor.selection = TimeSpan(start: 0.3, end: 1.3)
        await editor.reverseSelection()
        let reversed = editor.timeline.clips(.video).contains { $0.media != 0 }
        var exportedInfo = "sem exportação"
        if let out = try? await editor.exportEdited() {
            let a = AVURLAsset(url: out)
            let ed = (try? await a.load(.duration).seconds) ?? 0
            let na = (try? await a.loadTracks(withMediaType: .audio).count) ?? 0
            exportedInfo = "exportado \(String(format: "%.1f", ed)) s, \(na) faixa de áudio"
        }
        editor.tearDown()
        report.append("linhas \(lanes); corte de 1,5 s: \(String(format: "%.1f", full)) s → \(String(format: "%.1f", cutDur)) s; inverter \(reversed ? "ok" : "FALHOU"); \(exportedInfo)")
        report.append("ficheiro: \(url.lastPathComponent)")
        return report.joined(separator: " | ")
    }
}

/// Autoteste da edição de vídeo: um vídeo em que cada segundo tem uma cor, um tom no áudio do sistema (com o volume a subir
/// dentro do segundo) e outro tom no microfone. Verifica, no leitor e no ficheiro exportado, cortar juntando, deixando espaço
/// (com e sem vídeo), por linha, copiar, colar, inverter, exportar, desfazer, a memória da edição e os gestos do rato.
@MainActor
enum VideoEditSelfTest {
    static func sysFreq(_ sec: Int) -> Double { 400 + 100 * Double(sec) }
    static func micFreq(_ sec: Int) -> Double { 1000 + 100 * Double(sec) }
    static func blue(_ sec: Int) -> Int { 40 * sec }

    static func makeSource(at url: URL) async throws {
        let W = 320, H = 180
        let e = try RecordingEngine(url: url, width: W, height: H, system: true, microphone: true)
        var t = 5000.0
        e.now = { t }
        e.start(pump: false)
        var sent = 0.0, step = 0.0
        while step < 6.0 - 1e-9 {
            t = 5000.0 + step
            let sec = Int(step)
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, W, H, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
            CVPixelBufferLockBaseAddress(pb!, [])
            let base = CVPixelBufferGetBaseAddress(pb!)!.assumingMemoryBound(to: UInt8.self), bpr = CVPixelBufferGetBytesPerRow(pb!)
            for y in 0..<H { for x in 0..<W { let i = y * bpr + x * 4; base[i] = UInt8(blue(sec)); base[i + 1] = 90; base[i + 2] = 90; base[i + 3] = 255 } }
            CVPixelBufferUnlockBaseAddress(pb!, [])
            e.ingestVideo(pb!, hostPTS: t)
            while sent + 1024.0 / 48_000 <= step + 1.0 / 30 {
                let sc = min(Int(sent), 5), within = sent - Double(sc)
                var sys = VideoSelfTest.tone(sysFreq(sc), fromSec: sent, frames: 1024, amp: 0.15)
                for i in 0..<1024 { let g = Float(1 + 2.3 * min(1, within + Double(i) / 48_000)); sys[2 * i] *= g; sys[2 * i + 1] *= g }   // volume a subir: 0,15 → ≈0,5
                e.ingestAudio(.system, samples: sys, hostPTS: 5000.0 + sent)
                e.ingestAudio(.microphone, samples: VideoSelfTest.tone(micFreq(sc), fromSec: sent, frames: 1024, amp: 0.3), hostPTS: 5000.0 + sent)
                sent += 1024.0 / 48_000
            }
            e.pump(); step += 1.0 / 30
        }
        t = 5006.0
        try await e.finish()
    }

    struct Decoded { var blues: [(t: Double, b: Int)] = []; var system: [Float] = []; var mic: [Float] = []; var mixed: [Float] = []; var audioTracks = 0 }

    /// Lê a composição do editor (com os espaços a preto) e o áudio de cada linha.
    static func decode(_ model: VideoEditorModel) async -> Decoded {
        guard let (comp, _, vc) = try? await VideoComposer.build(timeline: model.timeline, tracks: model.trackMap, mediaLength: model.mediaLengths, enabled: model.enabled) else { return Decoded() }
        var d = await decodeAsset(comp, videoComposition: vc)
        // áudio por linha (as faixas da composição seguem a ordem das linhas)
        let lanes = model.timeline.tracks.filter { $0 != .video && !model.timeline.clips($0).isEmpty && model.enabled.contains($0) }
        let tracks = (try? await comp.loadTracks(withMediaType: .audio)) ?? []
        for (lane, track) in zip(lanes, tracks) {
            let pcm = await pcm(of: track, in: comp)
            if lane == .system { d.system = pcm } else { d.mic = pcm }
        }
        return d
    }

    static func pcm(of track: AVAssetTrack, in asset: AVAsset) async -> [Float] {
        var pcm: [Float] = []
        guard let reader = try? AVAssetReader(asset: asset) else { return pcm }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                                                                          AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2])
        reader.add(out); reader.startReading()
        while let sb = out.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            var len = 0; var ptr: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
            if let ptr { pcm += Array(UnsafeBufferPointer(start: UnsafeRawPointer(ptr).assumingMemoryBound(to: Float.self), count: len / 4)) }
        }
        return pcm
    }

    static func decodeAsset(_ asset: AVAsset, videoComposition: AVVideoComposition? = nil) async -> Decoded {
        var d = Decoded()
        if let vt = try? await asset.loadTracks(withMediaType: .video), !vt.isEmpty, let reader = try? AVAssetReader(asset: asset) {
            let out = AVAssetReaderVideoCompositionOutput(videoTracks: vt, videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            if let videoComposition { out.videoComposition = videoComposition }
            else { out.videoComposition = (try? await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)) }
            reader.add(out); reader.startReading()
            while let sb = out.copyNextSampleBuffer() {
                guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
                CVPixelBufferLockBaseAddress(pb, .readOnly)
                let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
                let i = (CVPixelBufferGetHeight(pb) / 2) * CVPixelBufferGetBytesPerRow(pb) + (CVPixelBufferGetWidth(pb) / 2) * 4
                d.blues.append((CMSampleBufferGetPresentationTimeStamp(sb).seconds, Int(base[i])))
                CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            }
        }
        let at = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        d.audioTracks = at.count
        if let a = at.first { d.mixed = await pcm(of: a, in: asset) }
        return d
    }

    static func g(_ pcm: [Float], _ a: Double, _ b: Double, _ f: Double) -> Double {
        let i0 = Int(a * 48_000), i1 = min(Int(b * 48_000), pcm.count / 2)
        guard i1 > i0 else { return 0 }
        var left: [Float] = []; left.reserveCapacity(i1 - i0)
        for i in i0..<i1 { left.append(pcm[2 * i]) }
        return VideoSelfTest.goertzel(left[...], f)
    }
    static func rms(_ pcm: [Float], _ a: Double, _ b: Double) -> Double {
        let i0 = Int(a * 48_000), i1 = min(Int(b * 48_000), pcm.count / 2)
        guard i1 > i0 else { return 0 }
        var s = 0.0; for i in i0..<i1 { s += Double(pcm[2 * i] * pcm[2 * i]) }
        return (s / Double(i1 - i0)).squareRoot()
    }
    static func blue(_ d: Decoded, near t: Double) -> Int { d.blues.min { abs($0.t - t) < abs($1.t - t) }?.b ?? -1 }

    static func run(dir: URL) async -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { fails.append(what) } }
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        CaptureStore.overrideFolder = dir.appendingPathComponent("biblioteca")
        let url = dir.appendingPathComponent("origem.mp4")
        do {
            try await makeSource(at: url)
            let model = VideoEditorModel(url: url)
            await model.load()
            check(model.timeline.tracks == [.video, .system, .microphone], "linhas: \(model.timeline.tracks)")
            check(abs(model.duration - 6) < 0.3 && model.mask == [.video, .system, .microphone], "duração \(model.duration), máscara \(model.mask)")
            let all: Set<EditTrack> = [.video, .system, .microphone]

            func select(_ a: Double, _ b: Double) { model.selection = TimeSpan(start: a, end: b) }

            // 1) cortar e juntar em todas as linhas: aos 2,5 s já se vê e ouve o segundo 4
            select(2, 4); await model.cut(join: true)
            check(abs(model.duration - 4) < 0.15, "cortar e juntar: duração \(model.duration)")
            var d = await decode(model)
            check(abs(blue(d, near: 1.5) - 40) < 25 && abs(blue(d, near: 2.5) - 160) < 25 && abs(blue(d, near: 3.5) - 200) < 25, "juntar: cores \(blue(d, near: 1.5)) \(blue(d, near: 2.5)) \(blue(d, near: 3.5))")
            check(g(d.system, 1.2, 1.8, sysFreq(1)) > 0.004 && g(d.system, 2.2, 2.8, sysFreq(4)) > 0.004 && g(d.system, 2.2, 2.8, sysFreq(1)) < 0.001, "juntar: tom do sistema")
            check(g(d.mic, 2.2, 2.8, micFreq(4)) > 0.004 && g(d.mic, 1.2, 1.8, micFreq(1)) > 0.004, "juntar: tom do microfone")
            await model.undo()
            check(abs(model.duration - 6) < 0.15 && !model.timeline.isEdited, "desfazer devia repor os 6 s")

            // 2) cortar deixando espaço em todas as linhas: preto e silêncio, e o resto fica onde estava
            select(2, 4); await model.cut(join: false)
            d = await decode(model)
            check(abs(model.duration - 6) < 0.15, "espaço: a duração devia manter-se (\(model.duration))")
            check(blue(d, near: 3.0) < 15, "espaço sem vídeo devia estar preto (azul \(blue(d, near: 3.0)))")
            check(abs(blue(d, near: 4.5) - 160) < 25, "depois do espaço devia estar o segundo 4 (azul \(blue(d, near: 4.5)))")
            check(rms(d.system, 2.2, 3.8) < 0.01 && rms(d.mic, 2.2, 3.8) < 0.01 && rms(d.system, 0.5, 1.5) > 0.05, "espaço sem som")
            await model.undo()

            // 3) cortar só o áudio deixando espaço: o vídeo continua (espaço «com vídeo»)
            model.mask = [.system, .microphone]
            select(2, 4); await model.cut(join: false)
            d = await decode(model)
            check(abs(blue(d, near: 2.5) - 80) < 25 && abs(blue(d, near: 3.5) - 120) < 25, "o vídeo devia continuar no espaço do áudio (azul \(blue(d, near: 2.5)) e \(blue(d, near: 3.5)))")
            check(rms(d.system, 2.2, 3.8) < 0.01 && rms(d.mic, 2.2, 3.8) < 0.01, "o áudio devia estar em silêncio no espaço")
            await model.undo()

            // 4) cortar só uma linha: o microfone continua quando o sistema é cortado
            model.mask = [.system]
            select(2, 4); await model.cut(join: false)
            d = await decode(model)
            check(rms(d.system, 2.2, 3.8) < 0.01 && g(d.mic, 2.2, 2.8, micFreq(2)) > 0.004, "cortar só o sistema: o microfone devia continuar")
            await model.undo()
            model.mask = all

            // 5) copiar e colar: inserindo empurra o resto; por cima substitui
            select(1, 2); model.copySelection()
            check(model.canPaste, "depois de copiar devia poder colar")
            model.seek(to: 4.0); select(0, 0.001); model.selection = nil
            await model.paste(insert: true)
            d = await decode(model)
            check(abs(model.duration - 7) < 0.15, "colar inserindo: duração \(model.duration)")
            check(abs(blue(d, near: 4.5) - 40) < 25 && abs(blue(d, near: 5.5) - 160) < 25, "colar inserindo: cores \(blue(d, near: 4.5)) \(blue(d, near: 5.5))")
            check(g(d.system, 4.2, 4.8, sysFreq(1)) > 0.004 && g(d.mic, 4.2, 4.8, micFreq(1)) > 0.004, "colar inserindo: o som copiado devia estar aos 4,5 s")
            await model.undo()
            model.seek(to: 4.0)
            await model.paste(insert: false)
            d = await decode(model)
            check(abs(model.duration - 6) < 0.15, "colar por cima: duração \(model.duration)")
            check(abs(blue(d, near: 4.5) - 40) < 25 && abs(blue(d, near: 5.5) - 200) < 25, "colar por cima: cores \(blue(d, near: 4.5)) \(blue(d, near: 5.5))")
            await model.undo()

            // 6) inverter 1–3 s em todas as linhas: aos 1,5 s vê-se o que estava aos 2,5 s e o volume desce
            select(1, 3); await model.reverseSelection()
            check(model.timeline.clips(.video).contains { $0.media != 0 }, "o trecho invertido devia ser uma média nova")
            d = await decode(model)
            check(abs(model.duration - 6) < 0.15, "inverter: duração \(model.duration)")
            for lane in model.timeline.lanes {
                for c in lane.clips where c.media != 0 {
                    let f = model.editFolder.appendingPathComponent("invertido-\(c.media)-\(lane.track.rawValue).mp4")
                    let a = AVURLAsset(url: f)
                    let vd = (try? await a.loadTracks(withMediaType: lane.track == .video ? .video : .audio).first?.load(.timeRange).duration.seconds) ?? 0
                    check(abs(vd - c.length) < 0.03, "o trecho invertido (\(lane.track.rawValue)) devia durar \(c.length) s e dura \(vd) s")
                }
            }
            check(abs(blue(d, near: 1.5) - 80) < 25 && abs(blue(d, near: 2.5) - 40) < 25, "inverter: cores \(blue(d, near: 1.5)) \(blue(d, near: 2.5)) (esperava 80 e 40)")
            check(abs(blue(d, near: 0.5) - 0) < 25 && abs(blue(d, near: 3.5) - 120) < 25, "inverter: o resto não devia mudar")
            check(g(d.system, 1.2, 1.8, sysFreq(2)) > 0.003 && g(d.mic, 1.2, 1.8, micFreq(2)) > 0.003 && g(d.mic, 2.2, 2.8, micFreq(1)) > 0.003, "inverter: tons")
            check(rms(d.system, 1.05, 1.45) > rms(d.system, 1.55, 1.95) * 1.3, "inverter: o volume devia descer ao longo do segundo (\(rms(d.system, 1.05, 1.45)) vs \(rms(d.system, 1.55, 1.95)))")

            // 7) a edição fica guardada: um segundo editor abre o mesmo vídeo já com o trecho invertido
            let again = VideoEditorModel(url: url)
            await again.load()
            check(again.timeline == model.timeline && again.timeline.isEdited, "a edição não ficou guardada")
            let d2 = await decode(again)
            check(abs(blue(d2, near: 1.5) - 80) < 25, "ao reabrir o trecho invertido devia manter-se (azul \(blue(d2, near: 1.5)))")
            again.tearDown()

            // 8) cortar e juntar depois de inverter, e guardar: um só áudio no ficheiro, com tudo misturado
            select(3, 5); await model.cut(join: true)
            let out = try await model.exportEdited()
            check(out.lastPathComponent == "origem_editado.mp4", "nome do exportado: \(out.lastPathComponent)")
            let ex = await decodeAsset(AVURLAsset(url: out))
            let dur = (try? await AVURLAsset(url: out).load(.duration).seconds) ?? 0
            check(abs(dur - 4) < 0.15, "exportado: duração \(dur) s, esperava ≈ 4")
            if let vtd = try? await AVURLAsset(url: out).loadTracks(withMediaType: .video).first?.load(.timeRange).duration.seconds {
                check(abs(vtd - 4) < 0.15, "exportado: o vídeo dura \(vtd) s, esperava ≈ 4 (o áudio dura \(dur) s)")
            }
            check(ex.audioTracks == 1, "o exportado devia ter um só áudio (tem \(ex.audioTracks))")
            check(abs(blue(ex, near: 1.5) - 80) < 25 && abs(blue(ex, near: 3.5) - 200) < 25, "exportado: cores \(blue(ex, near: 1.5)) \(blue(ex, near: 3.5))")
            check(g(ex.mixed, 3.2, 3.8, sysFreq(5)) > 0.003 && g(ex.mixed, 3.2, 3.8, micFreq(5)) > 0.003, "exportado: a mistura devia ter o sistema e o microfone")
            let out2 = try await model.exportEdited()
            check(out2.lastPathComponent == "origem_editado_2.mp4", "um segundo exportado não podia substituir o primeiro")
            await model.undo()
            await model.undo()
            check(!model.timeline.isEdited, "desfazer tudo devia repor o original")

            // 9) pré-visualização do ponto exato e setas
            select(1, 2); model.activeEdge = .end
            model.step(model.frameStep, moveEdge: true)
            check(model.selection.map { abs($0.end - (2 + model.frameStep)) < 1e-6 } ?? false, "seta devia mover a ponta ativa um quadro: \(String(describing: model.selection))")
            check(model.previewLabel?.contains(L("quadro")) == true && abs(model.playhead - (2 + model.frameStep)) < 0.02, "o leitor devia mostrar o ponto exato da ponta: \(model.previewLabel ?? "nil") em \(model.playhead)")
            model.activeEdge = .start
            model.step(-model.frameStep, moveEdge: true)
            check(model.selection.map { abs($0.start - (1 - model.frameStep)) < 1e-6 } ?? false, "seta devia mover a ponta do início")

            // 10) recusas: cortar tudo
            model.selection = TimeSpan(start: 0, end: model.duration)
            model.message = nil
            await model.cut(join: true)
            check(!model.timeline.isEdited && model.message != nil, "cortar tudo devia ser recusado com aviso")
            model.selection = nil
            model.tearDown()
        } catch { fails.append("exceção: \(error)") }
        fails += await gestures(dir: dir)
        try? FileManager.default.removeItem(at: dir)
        return fails
    }

    /// Gestos do rato e teclas na linha de tempo, com eventos reais entregues à vista.
    static func gestures(dir: URL) async -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { fails.append(what) } }
        let url = dir.appendingPathComponent("gestos.mp4")
        do { try await makeSource(at: url) } catch { return ["sem vídeo para os gestos: \(error)"] }
        let model = VideoEditorModel(url: url)
        await model.load()
        var actions: [TimelineNSView.Action] = []
        let view = TimelineNSView(frame: NSRect(x: 0, y: 0, width: 1000, height: TimelineNSView.idealHeight(lanes: 3)))
        view.model = model
        view.onAction = { actions.append($0) }
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.makeKeyAndOrderFront(nil)
        func ev(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat, clicks: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: view.frame.height - y), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        }
        func at(_ t: Double, row: EditTrack = .video) -> (CGFloat, CGFloat) { (view.x(t), view.rowRect(row).midY) }
        func drag(_ a: Double, _ b: Double, row: EditTrack = .video) {
            let (ax, y) = at(a, row: row), (bx, _) = at(b, row: row)
            view.mouseDown(with: ev(.leftMouseDown, x: ax, y: y)); view.mouseDragged(with: ev(.leftMouseDragged, x: (ax + bx) / 2, y: y))
            view.mouseDragged(with: ev(.leftMouseDragged, x: bx, y: y)); view.mouseUp(with: ev(.leftMouseUp, x: bx, y: y))
        }
        // marcar a arrastar numa linha de áudio; o leitor mostra o ponto exato da ponta que se move
        drag(1.0, 2.0, row: .system)
        check(model.selection.map { abs($0.start - 1) < 0.06 && abs($0.end - 2) < 0.06 } ?? false, "arrastar devia marcar 1–2 s: \(String(describing: model.selection))")
        check(model.previewLabel != nil && abs(model.playhead - 2.0) < 0.1 && model.activeEdge == .end, "ao arrastar o leitor devia mostrar o ponto exato do fim (\(model.previewLabel ?? "nil") em \(model.playhead))")
        // pega do fim para 3 s, pega do início para 0,5 s
        do { let (x1, y) = at(2.0), (x2, _) = at(3.0); view.mouseDown(with: ev(.leftMouseDown, x: x1, y: y)); view.mouseDragged(with: ev(.leftMouseDragged, x: (x1 + x2) / 2, y: y)); view.mouseDragged(with: ev(.leftMouseDragged, x: x2, y: y)); view.mouseUp(with: ev(.leftMouseUp, x: x2, y: y)) }
        check(model.selection.map { abs($0.start - 1) < 0.06 && abs($0.end - 3) < 0.06 } ?? false, "pega do fim: \(String(describing: model.selection))")
        do { let (x1, y) = at(1.0), (x2, _) = at(0.5); view.mouseDown(with: ev(.leftMouseDown, x: x1, y: y)); view.mouseDragged(with: ev(.leftMouseDragged, x: x2, y: y)); view.mouseUp(with: ev(.leftMouseUp, x: x2, y: y)) }
        check(model.selection.map { abs($0.start - 0.5) < 0.06 && abs($0.end - 3) < 0.06 } ?? false && model.activeEdge == .start, "pega do início: \(String(describing: model.selection))")
        // clique simples: vai para o ponto e limpa a marcação
        do { let (x, y) = at(5.0); view.mouseDown(with: ev(.leftMouseDown, x: x, y: y)); view.mouseUp(with: ev(.leftMouseUp, x: x, y: y)) }
        check(model.selection.map { $0.start <= 5.0 && $0.end >= 5.0 } ?? false && abs(model.playhead - 5.0) > 0.5, "clique devia marcar o clipe sem mexer na reprodução (\(model.playhead), \(String(describing: model.selection)))")
        // clicar em cima da linha vermelha vai para o ponto
        do { model.seek(to: 4.0); let px = view.x(model.playhead), y = view.rowRect(.video).midY; view.mouseDown(with: ev(.leftMouseDown, x: px, y: y)); view.mouseDragged(with: ev(.leftMouseDragged, x: view.x(4.8), y: y)); view.mouseUp(with: ev(.leftMouseUp, x: view.x(4.8), y: y)) }
        check(abs(model.playhead - 4.8) < 0.1, "arrastar a linha vermelha devia mover a reprodução (\(model.playhead))")
        // régua
        do { let x1 = view.x(1.0), x2 = view.x(3.5); view.mouseDown(with: ev(.leftMouseDown, x: x1, y: 8)); view.mouseDragged(with: ev(.leftMouseDragged, x: x2, y: 8)); view.mouseUp(with: ev(.leftMouseUp, x: x2, y: 8)) }
        check(abs(model.playhead - 3.5) < 0.1, "arrastar na régua devia ir para 3,5 s (\(model.playhead))")
        // cabeçalho: a caixa escolhe a linha
        view.mouseDown(with: ev(.leftMouseDown, x: 38, y: view.rowRect(.microphone).midY)); view.mouseUp(with: ev(.leftMouseUp, x: 38, y: view.rowRect(.microphone).midY))
        check(!model.mask.contains(.microphone) && model.mask.count == 2 && model.locked == [.microphone], "o cadeado devia proteger o microfone: \(model.mask)")
        view.mouseDown(with: ev(.leftMouseDown, x: 38, y: view.rowRect(.microphone).midY)); view.mouseUp(with: ev(.leftMouseUp, x: 38, y: view.rowRect(.microphone).midY))
        check(model.mask.count == 3, "clicar outra vez devia libertá-lo")
        // teclas: Delete corta e junta, ⇧Delete deixa espaço, Tab muda de ponta, setas movem a ponta
        func key(_ chars: String, shift: Bool = false) {
            view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 0)!)
        }
        key("\u{7F}"); key("\u{7F}", shift: true); key(" ")
        check(actions == [.cutJoin, .cutGap, .togglePlay], "teclas Delete, ⇧Delete e espaço: \(actions)")
        key("\u{1B}")
        drag(1.0, 2.0)
        key("\t")
        check(model.activeEdge == .start, "Tab devia mudar para a ponta do início")
        key(String(UnicodeScalar(NSRightArrowFunctionKey)!))
        check(model.selection.map { abs($0.start - (1 + model.frameStep)) < 0.06 } ?? false, "seta devia mover a ponta ativa: \(String(describing: model.selection))")
        key("\u{1B}")
        check(model.selection == nil && model.previewLabel == nil, "Esc devia limpar a marcação e a legenda")
        // espaço: cortar deixando espaço e depois clique duplo no espaço marca-o inteiro
        model.selection = TimeSpan(start: 2, end: 3)
        await model.cut(join: false)
        do { let (x, y) = at(2.5); view.mouseDown(with: ev(.leftMouseDown, x: x, y: y, clicks: 2)); view.mouseUp(with: ev(.leftMouseUp, x: x, y: y, clicks: 2)) }
        check(model.selection.map { abs($0.start - 2) < 0.05 && abs($0.end - 3) < 0.05 } ?? false, "clique duplo num espaço devia marcá-lo inteiro: \(String(describing: model.selection))")
        // ... e cortar e juntar essa seleção fecha o espaço
        await model.cut(join: true)
        check(abs(model.duration - 5) < 0.15 && model.timeline.gaps(.video).isEmpty, "cortar e juntar o espaço devia fechá-lo (duração \(model.duration))")
        // mover o trecho com o rato: marcar 0,5–1,5 s e arrastar para 3 s (por cima; fica um espaço onde estava)
        await model.undo(); await model.undo()
        model.selection = TimeSpan(start: 0.5, end: 1.5)
        do { let (x1, y) = at(1.0), (x2, _) = at(3.5); view.mouseDown(with: ev(.leftMouseDown, x: x1, y: y)); view.mouseDragged(with: ev(.leftMouseDragged, x: (x1 + x2) / 2, y: y)); view.mouseDragged(with: ev(.leftMouseDragged, x: x2, y: y)); view.mouseUp(with: ev(.leftMouseUp, x: x2, y: y)) }
        try? await Task.sleep(nanoseconds: 800_000_000)
        check(model.selection.map { abs($0.start - 3.0) < 0.1 && abs($0.length - 1.0) < 0.02 } ?? false, "mover devia levar o trecho para 3 s: \(String(describing: model.selection))")
        check(model.timeline.gaps(.video).contains { abs($0.start - 0.5) < 0.1 }, "mover devia deixar um espaço onde estava")
        // com o cadeado, a linha protegida não se mexe
        await model.undo()
        model.toggleLocked(.microphone)
        model.selection = TimeSpan(start: 0.5, end: 1.5)
        await model.moveSelection(to: 3.0, insert: false)
        check(model.timeline.gaps(.microphone).isEmpty && !model.timeline.gaps(.video).isEmpty, "a linha protegida não devia mover-se")
        await model.undo(); model.toggleLocked(.microphone)
        // suprimir uma linha tira-a da reprodução
        await model.toggleEnabled(.microphone)
        check(!model.enabled.contains(.microphone) && model.mask == [.video, .system], "suprimir o microfone: \(model.enabled)")
        let sup = await VideoEditSelfTest.decode(model)
        check(sup.mic.isEmpty && !sup.system.isEmpty, "a linha suprimida não devia tocar")
        await model.toggleEnabled(.microphone)
        // clique duplo num clipe marca-o inteiro
        model.selection = nil
        do { let (x, y) = at(0.2); view.mouseDown(with: ev(.leftMouseDown, x: x, y: y, clicks: 2)); view.mouseUp(with: ev(.leftMouseUp, x: x, y: y, clicks: 2)) }
        check(model.selection != nil, "clique duplo num clipe devia marcá-lo")
        // zoom
        model.zoom(by: 0.5)
        check(model.zoom == 0.5 && model.pixelsPerSecond < Double(view.trackWidth) / model.timeline.duration, "afastar devia reduzir os píxeis por segundo")
        model.zoom(by: 4)
        let z = model.zoom
        model.zoomFit()
        check(z == 2 && model.zoom == 1 && model.viewStart == 0, "zoom \(z) e ajuste")
        window.orderOut(nil)
        model.tearDown()
        return fails
    }
}

extension VideoEditSelfTest {
    /// Desenha a área de trabalho do vídeo (leitor, barra de edição e linha de tempo) com um corte feito e um trecho marcado.
    static func render(to path: String) async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("toth-render-video-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Toth_2026-10-26_20.15.00.mp4")
        try? await makeSource(at: url)
        let model = VideoEditorModel(url: url)
        await model.load()
        model.selection = TimeSpan(start: 1.0, end: 1.5); await model.cut(join: true)                 // juntar (todas as linhas)
        model.mask = [.system, .microphone]
        model.selection = TimeSpan(start: 2.6, end: 3.4); await model.cut(join: false)                 // espaço só no áudio: o vídeo continua
        model.mask = [.video, .system, .microphone]
        model.selection = TimeSpan(start: 3.9, end: 4.3); await model.cut(join: false)                 // espaço em tudo
        model.mask = [.video, .system]
        model.selection = TimeSpan(start: 0.4, end: 0.9); model.activeEdge = .end
        model.seek(to: 0.9); model.preview(0.9, label: L("Fim do trecho"))
        try? await Task.sleep(nanoseconds: 800_000_000)
        let host = NSHostingView(rootView: VideoWorkspace(model: model).environment(\.colorScheme, .light))
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 640)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        model.tearDown()
    }
}

extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var out: [T] = []
        for e in self { out.append(try await transform(e)) }
        return out
    }
}

extension VideoEditSelfTest {
    /// Diagnóstico (`--video-inspect <mp4>`): mostra as linhas, os clipes e a duração de cada faixa da composição.
    static func inspect(url: URL) async -> String {
        let model = VideoEditorModel(url: url)
        await model.load()
        var lines: [String] = ["duração da linha de tempo \(String(format: "%.3f", model.duration))"]
        for lane in model.timeline.lanes {
            lines.append("  \(lane.track.rawValue): " + lane.clips.map { "m\($0.media)[\(String(format: "%.3f", $0.src.start))–\(String(format: "%.3f", $0.src.end))]@\(String(format: "%.3f", $0.at))" }.joined(separator: " "))
        }
        if let (comp, _, vc) = try? await VideoComposer.build(timeline: model.timeline, tracks: model.trackMap, mediaLength: model.mediaLengths) {
            lines.append("composição: \(String(format: "%.3f", comp.duration.seconds)) s; renderização \(vc.map { "\($0.renderSize) frameDuration \(String(format: "%.4f", $0.frameDuration.seconds))" } ?? "sem")")
            for t in comp.tracks { lines.append("  faixa \(t.mediaType.rawValue): \(String(format: "%.3f", t.timeRange.start.seconds))–\(String(format: "%.3f", t.timeRange.end.seconds))") }
        }
        model.tearDown()
        return lines.joined(separator: "\n")
    }
}
