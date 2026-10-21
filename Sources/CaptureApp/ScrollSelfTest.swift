// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit
import CaptureCore
import CoreVideo

/// Utilizador simulado: percorre uma página sintética e cada captura é a janela nessa posição.
@MainActor
final class SimulatedUserSource: FrameSource {
    let page: ScrollTestPage
    let w: Int, h: Int, header: Int, footer: Int, sidebar: Int
    private var path: [(Int, Int)]
    private(set) var consumed = 0
    var blink = false                  // um pequeno elemento pisca em cada captura (relógio, cursor)

    init(page: ScrollTestPage, path: [(Int, Int)], w: Int, h: Int, header: Int = 0, footer: Int = 0, sidebar: Int = 0) {
        self.page = page; self.path = path; self.w = w; self.h = h
        self.header = header; self.footer = footer; self.sidebar = sidebar
    }

    var finished: Bool { consumed >= path.count }

    func nextFrame() async throws -> PixelFrame? {
        let p = path[min(consumed, path.count - 1)]
        consumed += 1
        var f = page.window(ox: p.0, oy: p.1, width: w, height: h, header: header, footer: footer, sidebar: sidebar)
        if blink && consumed % 2 == 0 {
            for y in 6..<18 { for x in 6..<18 { let i = (y * w + x) * 4; f.rgba[i] = 0; f.rgba[i + 1] = 0; f.rgba[i + 2] = 0 } }
        }
        return f
    }
}

enum ScrollSelfTest {
    static func walk(from a: (Int, Int), to b: (Int, Int), step: Int) -> [(Int, Int)] {
        let dx = b.0 - a.0, dy = b.1 - a.1
        let n = max(1, Int((Double(max(abs(dx), abs(dy))) / Double(step)).rounded(.up)))
        return (0...n).map { (a.0 + dx * $0 / n, a.1 + dy * $0 / n) }
    }

    @MainActor
    static func run() async -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { fails.append(what) } }

        func record(_ src: SimulatedUserSource, cancelAfter: Int? = nil) async -> (ScrollRecorder.Outcome?, [ScrollStatus]) {
            let rec = ScrollRecorder(source: src)
            rec.pause = 0
            var statuses: [ScrollStatus] = []
            rec.onStatus = { statuses.append($0) }
            rec.control = {
                if let c = cancelAfter, src.consumed >= c { return .cancel }
                return src.finished ? .finish : .run
            }
            return (try? await rec.run(), statuses)
        }

        func equalsPage(_ f: PixelFrame, at: (Int, Int), size: (Int, Int), page: ScrollTestPage, page0: (Int, Int), skip: Range<Int> = 0..<0) -> Bool {
            for y in stride(from: 0, to: size.1, by: 3) {
                for x in stride(from: 0, to: size.0, by: 2) where !skip.contains(x) {
                    let a = ((at.1 + y) * f.width + at.0 + x) * 4, b = ((page0.1 + y) * page.width + page0.0 + x) * 4
                    if f.rgba[a] != page.rgba[b] || f.rgba[a + 1] != page.rgba[b + 1] || f.rgba[a + 2] != page.rgba[b + 2] { return false }
                }
            }
            return true
        }

        // 1) vertical: começa a meio, sobe até ao topo, desce até ao fim, volta a subir e a descer (passa outra vez
        //    pelas mesmas zonas); cabeçalho, rodapé e barra lateral fixos; um elemento pisca
        let tall = ScrollTestPage(width: 420, height: 3000, seed: 11)
        let h = 520, header = 50, footer = 40, sidebar = 60
        let bodyH = h - header - footer
        var path = walk(from: (0, 900), to: (0, 0), step: 140)
        path += walk(from: (0, 0), to: (0, 2000), step: 170)
        path += walk(from: (0, 2000), to: (0, 1100), step: 120)
        path += walk(from: (0, 1100), to: (0, 2400), step: 160)
        let src1 = SimulatedUserSource(page: tall, path: path, w: 420, h: h, header: header, footer: footer, sidebar: sidebar)
        src1.blink = true
        let (o1, s1) = await record(src1)
        if case let .image(f, frames)? = o1 {
            let body = 2400 + bodyH
            check(f.width == 420 && f.height == header + body + footer, "vertical: tamanho \(f.width)×\(f.height), esperado 420×\(header + body + footer)")
            if f.height == header + body + footer {
                check(equalsPage(f, at: (sidebar, header), size: (420 - sidebar, body), page: tall, page0: (sidebar, 0)), "vertical: o conteúdo não coincide com a página")
            }
            check(frames >= 20, "vertical: poucas capturas aceites (\(frames))")
        } else { fails.append("vertical: sem imagem") }
        check(s1.last.map { $0.health == .ok } ?? false, "vertical: estado final devia ser ok")

        // 2) horizontal, nos dois sentidos, começando a meio
        let wide = ScrollTestPage(width: 2600, height: 360, seed: 5)
        var p2 = walk(from: (800, 0), to: (0, 0), step: 120)
        p2 += walk(from: (0, 0), to: (2100, 0), step: 170)
        p2 += walk(from: (2100, 0), to: (1200, 0), step: 110)
        let (o2, _) = await record(SimulatedUserSource(page: wide, path: p2, w: 500, h: 360))
        if case let .image(f, _)? = o2 {
            check(f.width == 2100 + 500 && f.height == 360, "horizontal: tamanho \(f.width)×\(f.height), esperado \(2100 + 500)×360")
            if f.width == 2600 { check(equalsPage(f, at: (0, 0), size: (2600, 360), page: wide, page0: (0, 0)), "horizontal: o conteúdo não coincide") }
        } else { fails.append("horizontal: sem imagem") }

        // 3) troca de eixo: desce, vai para a direita, sobe
        let big = ScrollTestPage(width: 1400, height: 1800, seed: 33)
        var p3 = walk(from: (0, 0), to: (0, 700), step: 120)
        p3 += walk(from: (0, 700), to: (600, 700), step: 100)
        p3 += walk(from: (600, 700), to: (600, 200), step: 110)
        let (o3, _) = await record(SimulatedUserSource(page: big, path: p3, w: 500, h: 500))
        if case let .image(f, _)? = o3 {
            check(f.width == 1100 && f.height == 1200, "dois eixos: tamanho \(f.width)×\(f.height), esperado 1100×1200")
            if f.width == 1100 && f.height == 1200 {
                check(equalsPage(f, at: (0, 0), size: (500, 500), page: big, page0: (0, 0)), "dois eixos: início não coincide")
                check(equalsPage(f, at: (600, 700), size: (500, 500), page: big, page0: (600, 700)), "dois eixos: canto não coincide")
                check(equalsPage(f, at: (600, 200), size: (500, 500), page: big, page0: (600, 200)), "dois eixos: fim não coincide")
            }
        } else { fails.append("dois eixos: sem imagem") }

        // 4) rolar depressa demais: avisa, e ao voltar um pouco atrás retoma, sem perder o que já havia
        var p4 = walk(from: (0, 400), to: (0, 900), step: 120)
        p4 += [(0, 2200), (0, 2300), (0, 2400), (0, 2500)]                 // salto: sem sobreposição
        p4 += walk(from: (0, 900), to: (0, 1300), step: 120)               // volta à zona conhecida
        let (o4, s4) = await record(SimulatedUserSource(page: tall, path: p4, w: 420, h: 520))
        check(s4.contains { $0.health == .tooFast }, "devia avisar que rolou depressa demais")
        if case let .image(f, _)? = o4 {
            check(f.height == 1300 - 400 + 520, "depressa demais: altura \(f.height), esperada \(1300 - 400 + 520)")
            check(equalsPage(f, at: (0, 0), size: (420, min(f.height, 1420)), page: tall, page0: (0, 400)), "depressa demais: conteúdo não coincide")
        } else { fails.append("depressa demais: sem imagem") }

        // 5) concluir sem rolar dá a captura simples; cancelar descarta
        let (o5, _) = await record(SimulatedUserSource(page: tall, path: [(0, 100), (0, 100), (0, 100)], w: 420, h: 300))
        if case .single? = o5 {} else { fails.append("sem rolagem devia dar a captura simples") }
        let (o6, _) = await record(SimulatedUserSource(page: tall, path: walk(from: (0, 0), to: (0, 900), step: 100), w: 420, h: 400), cancelAfter: 4)
        if case .cancelled? = o6 {} else { fails.append("cancelar devia devolver cancelado") }

        // 5b) pausar e retomar: durante a pausa o utilizador anda para onde quiser; ao retomar numa zona que ainda
        //     se sobrepõe à última capturada, a imagem continua sem falhas
        var pp = walk(from: (0, 0), to: (0, 1200), step: 150)          // 9 capturas
        pp += [(0, 1350), (0, 1500)]                                      // em pausa: ignoradas
        pp += walk(from: (0, 1500), to: (0, 2300), step: 160)
        let srcP = SimulatedUserSource(page: tall, path: pp, w: 420, h: 520)
        let recP = ScrollRecorder(source: srcP)
        recP.pause = 0
        var sawPaused = false
        recP.onStatus = { if $0.paused { sawPaused = true } }
        recP.control = { (9..<11).contains(srcP.consumed) ? .pause : (srcP.finished ? .finish : .run) }
        if case let .image(f, _)? = try? await recP.run() {
            check(f.height == 2300 + 520, "pausa: altura \(f.height), esperada \(2300 + 520)")
            check(equalsPage(f, at: (0, 0), size: (420, min(f.height, 2820)), page: tall, page0: (0, 0)), "pausa: o conteúdo não coincide")
        } else { fails.append("pausa: sem imagem") }
        check(sawPaused, "o estado devia indicar a pausa")

        // 6) conversão imagem ↔ bytes não altera píxeis
        let frame = tall.window(ox: 0, oy: 100, width: 200, height: 150)
        if let img = FrameConversion.image(from: frame) { check(FrameConversion.frame(from: img) == frame, "conversão CGImage↔bytes alterou píxeis") }
        else { fails.append("sem CGImage") }
        // 7) formato do ScreenCaptureKit: BGRA com margem no fim de cada linha → RGBA certo
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 37, 11, kCVPixelFormatType_32BGRA, nil, &pb)   // 37 px: a largura da linha leva margem
        if let pb {
            CVPixelBufferLockBaseAddress(pb, [])
            let bpr = CVPixelBufferGetBytesPerRow(pb)
            if let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) {
                for y in 0..<11 { for x in 0..<37 { let i = y * bpr + x * 4; base[i] = UInt8(x * 3); base[i + 1] = UInt8(y * 5); base[i + 2] = UInt8(200 - x); base[i + 3] = 255 } }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            let f = ScreenRegionSource.frame(from: pb)
            var ok = f.width == 37 && f.height == 11
            for y in 0..<11 { for x in 0..<37 where ok {
                let i = (y * 37 + x) * 4
                if f.rgba[i] != UInt8(200 - x) || f.rgba[i + 1] != UInt8(y * 5) || f.rgba[i + 2] != UInt8(x * 3) || f.rgba[i + 3] != 255 { ok = false }
            } }
            check(ok, "conversão BGRA→RGBA (com margem de linha) errada")
        } else { fails.append("sem CVPixelBuffer") }
        return fails
    }
}

extension ScrollSelfTest {
    /// Mede quanto demora juntar uma captura de ecrã Retina (texto real, passos pequenos e grandes).
    @MainActor
    static func bench() -> String {
        func page() -> PixelFrame {
            let w = 2880, h = 6000
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: 2, y: 2)
            let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = gc
            let words = "Lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore".split(separator: " ")
            var y = CGFloat(h) / 2 - 30, n = 0
            while y > 30 {
                n += 1
                let line = (0..<16).map { words[(n * 5 + $0 * 7 + n / 3) % words.count] }.joined(separator: " ") + " \(n * 37 % 991)"
                (line as NSString).draw(at: NSPoint(x: 60, y: y - 16), withAttributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor(white: 0.12, alpha: 1)])
                y -= 24
            }
            NSGraphicsContext.restoreGraphicsState()
            return PixelFrame(width: w, height: h, rgba: [UInt8](Data(bytes: ctx.data!, count: w * h * 4)))
        }
        func crop(_ p: PixelFrame, y: Int, h: Int) -> PixelFrame {
            PixelFrame(width: p.width, height: h, rgba: Array(p.rgba[(y * p.width * 4)..<((y + h) * p.width * 4)]))
        }
        let p = page()
        var out: [String] = []
        for step in [40, 200, 700] {
            var s = MosaicStitcher()
            var times: [Double] = []
            var results: [String] = []
            var y = 0
            while y + 1800 <= p.height && times.count < 8 {
                let f = crop(p, y: y, h: 1800)
                let t0 = Date()
                let r = s.add(f)
                times.append(Date().timeIntervalSince(t0) * 1000)
                results.append("\(r)"); y += step
            }
            let moved = results.filter { $0.hasPrefix("moved") }.count
            out.append("passo \(step) px: \(moved)/\(times.count - 1) juntas, mediana \(Int(times.dropFirst().sorted()[times.count / 2])) ms")
        }
        return out.joined(separator: " | ")
    }
}

/// Teste ao vivo (flag `--scroll-live`): corre o fluxo real da captura com rolagem sobre uma região do ecrã, com uma
/// rolagem automática só para o teste (num uso normal quem rola é o utilizador).
@MainActor
enum ScrollLiveTest {
    static func run(rect: CGRect, out: String, steps: Int, delta: Int, interval: TimeInterval) async -> String {
        guard let screen = NSScreen.main else { return "sem ecrã" }
        do {
            // 1) o instantâneo congelado e a área recortada: é a primeira imagem
            let snap = try await ScreenCapturer.snapshot(of: screen)
            let k = CGFloat(snap.width) / screen.frame.width
            let px = CGRect(x: rect.minX * k, y: rect.minY * k, width: rect.width * k, height: rect.height * k).integral
            guard let first = snap.cropping(to: px) else { return "recorte falhou" }
            let points = CGRect(x: px.minX / k, y: px.minY / k, width: px.width / k, height: px.height / k)

            // 2) barra e moldura, como na sessão
            let hud = ScrollHUD(near: points, on: screen)
            let frame = RegionFrameWindow(rect: points, on: screen)
            frame.orderFrontRegardless(); hud.orderFrontRegardless()
            defer { hud.orderOut(nil); frame.orderOut(nil) }
            let source = try await ScreenRegionSource(screen: screen, rect: points, pixelSize: (first.width, first.height))
            let recorder = ScrollRecorder(source: source)
            recorder.firstFrame = FrameConversion.frame(from: first, in: source.colorSpace)
            var control = ScrollControl.run
            recorder.control = { control }
            recorder.onStatus = { hud.show($0) }

            // 3) rolagem de teste: eventos de roda sobre o centro da região
            let center = CGPoint(x: screen.frame.minX + points.midX,
                                 y: (NSScreen.screens.first?.frame.height ?? screen.frame.height) - (screen.frame.maxY - points.minY) + points.height / 2)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 700_000_000)
                CGWarpMouseCursorPosition(center)
                for _ in 0..<steps {
                    let parts = 8
                    for _ in 0..<parts {
                        if let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(-delta / parts), wheel2: 0, wheel3: 0) {
                            e.location = center; e.post(tap: .cghidEventTap)
                        }
                        try? await Task.sleep(nanoseconds: 16_000_000)
                    }
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                }
                try? await Task.sleep(nanoseconds: 800_000_000)
                control = .finish
            }
            let outcome = try await recorder.run()
            switch outcome {
            case let .image(f, frames):
                if let img = FrameConversion.image(from: f, space: source.colorSpace), let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: out))
                }
                return "OK \(frames) capturas, \(f.width)x\(f.height) (região \(first.width)x\(first.height))"
            case let .single(f, moved, failed):
                if let img = FrameConversion.image(from: f, space: source.colorSpace), let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: out))
                }
                return "SÓ A CAPTURA SIMPLES: juntas \(moved), sem alinhar \(failed), \(f.width)x\(f.height)"
            case .cancelled:
                return "cancelado"
            }
        } catch { return "erro: \(error)" }
    }
}

/// Teste de ponta a ponta (flag `--scroll-e2e`): editor do Toth aberto, outra app (o navegador) à frente; escolhe a área
/// no seletor real, «Rolagem», e rola de teste. Durante a captura verifica que a janela de topo sobre a área é sempre
/// a do navegador (nunca o Toth).
@MainActor
enum ScrollE2ETest {
    static func run(rect: CGRect, owner: String, out: String, steps: Int, delta: Int) async -> String {
        guard let screen = NSScreen.main else { return "sem ecrã" }
        MainWindow.show()                                              // o editor do Toth aberto (como no uso real)
        try? await Task.sleep(nanoseconds: 800_000_000)
        let activate = Process()
        activate.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        activate.arguments = ["-e", "tell application \"\(owner)\" to activate"]
        try? activate.run(); activate.waitUntilExit()                  // o navegador passa à frente do editor
        try? await Task.sleep(nanoseconds: 1_200_000_000)

        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let center = CGPoint(x: screen.frame.minX + rect.midX, y: primaryHeight - (screen.frame.maxY - rect.minY) + rect.height / 2)
        func topOwnerAtCenter() -> String {
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
                guard let b = w[kCGWindowBounds as String] as? [String: Double] else { continue }
                let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
                if r.contains(center) { return (w[kCGWindowOwnerName as String] as? String) ?? "?" }
            }
            return "nenhuma"
        }
        var owners: [String] = ["antes: " + topOwnerAtCenter()]

        // seletor real, com o instantâneo real
        guard let snap = try? await ScreenCapturer.snapshot(of: screen) else { return "sem instantâneo (permissão?)" }
        let selector = RegionSelector()
        var finished = "sem resultado"
        selector.onScroll = { scr, r, first in
            Task { @MainActor in
                let watcher = Task { @MainActor in          // de 0,3 em 0,3 s, quem está por cima da área
                    while !Task.isCancelled { owners.append(topOwnerAtCenter()); try? await Task.sleep(nanoseconds: 300_000_000) }
                }
                Task { @MainActor in                         // rolagem de teste
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    CGWarpMouseCursorPosition(center)
                    for _ in 0..<steps {
                        for _ in 0..<8 {
                            if let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(-delta / 8), wheel2: 0, wheel3: 0) { e.location = center; e.post(tap: .cghidEventTap) }
                            try? await Task.sleep(nanoseconds: 16_000_000)
                        }
                        try? await Task.sleep(nanoseconds: 350_000_000)
                    }
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    ScrollCaptureSession.debugFinish()
                }
                let image = await ScrollCaptureSession.capture(screen: scr, rect: r, first: first)
                watcher.cancel()
                if let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: out))
                    finished = "imagem \(image.width)x\(image.height)"
                } else { finished = "sem imagem" }
            }
        }
        selector.begin(snapshots: [(screen, snap)]) { _ in }
        selector.debugPreselect(rect)
        try? await Task.sleep(nanoseconds: 500_000_000)
        owners.append("seletor aberto: editor visível = \(MainWindow.isVisible)")
        selector.debugScroll()
        for _ in 0..<120 { if finished != "sem resultado" { break }; try? await Task.sleep(nanoseconds: 500_000_000) }
        let during = owners.dropFirst(2)
        let bad = during.filter { $0 != owner }
        return "\(finished); janela de topo sobre a área: \(owners[0]); durante \(during.count) verificações, \(bad.count) com outra janela\(bad.isEmpty ? "" : " (" + Set(bad).joined(separator: ", ") + ")")"
    }
}
