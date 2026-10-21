// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

// Captura por rolagem sobre uma página de texto verdadeira (CoreText, fundo branco, suavização), não só blocos sintéticos.
import Testing
import Foundation
import AppKit
@testable import CaptureCore

/// Página parecida com um navegador: fundo branco, texto fino com suavização, títulos, uma imagem, barra fixa.
func makeTextPage(width: Int, height: Int, scale: CGFloat = 2) -> PixelFrame {
    let w = Int(CGFloat(width) * scale), h = Int(CGFloat(height) * scale)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.scaleBy(x: scale, y: scale)
    let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = gc
    let words = "Lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore magna aliqua Ut enim ad minim veniam quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat".split(separator: " ")
    var y = CGFloat(height) - 40
    var n = 0
    while y > 40 {
        n += 1
        if n % 9 == 0 {
            // "imagem": gradiente
            // "fotografia": fundo com gradiente e manchas aleatórias (única, como uma imagem real)
            NSGradient(colors: [NSColor.systemTeal, NSColor.systemPurple])!.draw(in: NSRect(x: 40, y: y - 160, width: 500, height: 150), angle: CGFloat(n % 90))
            var sd = UInt64(n) &* 1103515245 &+ 12345
            for _ in 0..<60 {
                sd = sd &* 6364136223846793005 &+ 1442695040888963407
                let px = CGFloat(Int(sd >> 33) % 470), py = CGFloat(Int(sd >> 17) % 130), sz = CGFloat(6 + Int(sd >> 45) % 30)
                NSColor(hue: CGFloat(Int(sd >> 25) % 100) / 100, saturation: 0.7, brightness: 0.9, alpha: 1).setFill()
                NSRect(x: 40 + px, y: y - 160 + py, width: sz, height: sz).fill()
            }
            y -= 190
        } else if n % 5 == 0 {
            ("Título número \(n)" as NSString).draw(at: NSPoint(x: 40, y: y - 24), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 24), .foregroundColor: NSColor.black])
            y -= 50
        } else {
            // texto único (palavras pseudoaleatórias): uma página real não se repete
            var seed = UInt64(n) &* 2862933555777941757 &+ 3037000493
            func rnd(_ m: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) % m }
            let line = (0..<(9 + rnd(5))).map { _ in String((0..<(2 + rnd(8))).map { _ in Character(UnicodeScalar(UInt8(97 + rnd(26)))) }) }.joined(separator: " ")
            (line as NSString).draw(at: NSPoint(x: 40, y: y - 16), withAttributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor(white: 0.1, alpha: 1)])
            y -= 24
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    let data = Data(bytes: ctx.data!, count: w * h * 4)
    return PixelFrame(width: w, height: h, rgba: [UInt8](data))
}

func crop(_ p: PixelFrame, x: Int, y: Int, w: Int, h: Int) -> PixelFrame {
    var out = [UInt8](repeating: 0, count: w * h * 4)
    for yy in 0..<h { let s = ((y + yy) * p.width + x) * 4; out.replaceSubrange((yy * w * 4)..<((yy + 1) * w * 4), with: p.rgba[s..<(s + w * 4)]) }
    return PixelFrame(width: w, height: h, rgba: out)
}

/// Janela de `h` linhas sobre a página, com uma barra fixa de `bar` linhas no topo (logótipo + texto).
func windowWithBar(_ page: PixelFrame, y: Int, w: Int, h: Int, bar: Int) -> PixelFrame {
    var f = crop(page, x: 0, y: y, w: w, h: h)
    for yy in 0..<bar { for x in 0..<w {
        let i = (yy * w + x) * 4
        let on = (x / 40 + yy / 8) % 3 == 0 || (x > 60 && x < 300 && yy > 20 && yy < 40)
        f.rgba[i] = on ? 30 : 235; f.rgba[i + 1] = on ? 60 : 235; f.rgba[i + 2] = on ? 120 : 245
    } }
    return f
}

@Suite struct RealisticScrollTests {
    static let page = makeTextPage(width: 700, height: 2400)   // 1400 × 4800 píxeis do dispositivo

    func same(_ out: PixelFrame, at oy: Int, rows: Int, skipTop: Int = 0) -> Bool {
        let p = Self.page
        guard out.width == p.width else { return false }
        for y in stride(from: skipTop, to: rows, by: 1) {
            let a = y * out.width * 4, b = (oy + y) * p.width * 4
            if out.rgba[a..<(a + p.width * 4)] != p.rgba[b..<(b + p.width * 4)] { return false }
        }
        return true
    }

    @Test(arguments: [180, 450, 620]) func downAtDifferentSpeeds(step: Int) {
        var s = MosaicStitcher()
        var results: [MosaicStitcher.Result] = []
        var oy = 0
        while oy <= 3000 { results.append(s.add(crop(Self.page, x: 0, y: oy, w: 1400, h: 1000))); oy += step }
        oy -= step
        #expect(!results.contains(.failed), "passo \(step): \(results)")
        let out = s.result()!
        #expect(out.height == oy + 1000)
        #expect(same(out, at: 0, rows: out.height))
    }

    @Test func goesBackAndForthOnRealText() {
        var s = MosaicStitcher()
        var path: [Int] = []
        path += stride(from: 1500, through: 0, by: -260).map { $0 }
        path += stride(from: 0, through: 3400, by: 300).map { $0 }
        path += stride(from: 3400, through: 2000, by: -280).map { $0 }
        path += stride(from: 2000, through: 3800, by: 200).map { $0 }
        var failed = 0
        for y in path { if s.add(crop(Self.page, x: 0, y: y, w: 1400, h: 1000)) == .failed { failed += 1 } }
        #expect(failed == 0)
        let out = s.result()!
        #expect(out.height == 3800 + 1000)
        #expect(same(out, at: 0, rows: out.height))
    }

    @Test func stickyBarIsKeptOnceAtTop() {
        var s = MosaicStitcher()
        var oy = 0
        var failed = 0
        while oy <= 2400 { if s.add(windowWithBar(Self.page, y: oy, w: 1400, h: 1000, bar: 90)) == .failed { failed += 1 }; oy += 320 }
        #expect(failed == 0)
        let out = s.result()!
        let last = oy - 320
        #expect(out.height == last + 1000)
        // abaixo da barra, o conteúdo coincide com a página
        let p = Self.page
        var ok = true
        for y in stride(from: 130, to: out.height, by: 7) {
            let a = y * out.width * 4, b = (y) * p.width * 4
            if out.rgba[a..<(a + p.width * 4)] != p.rgba[b..<(b + p.width * 4)] { ok = false; break }
        }
        #expect(ok)
    }

    @Test func fastJumpIsReportedNotHidden() {
        var s = MosaicStitcher()
        _ = s.add(crop(Self.page, x: 0, y: 0, w: 1400, h: 1000))
        _ = s.add(crop(Self.page, x: 0, y: 300, w: 1400, h: 1000))
        // salta 2000 píxeis: sem sobreposição. Numa página quase toda branca isto NÃO pode passar por "nada mudou".
        #expect(s.add(crop(Self.page, x: 0, y: 2300, w: 1400, h: 1000)) == .failed)
    }
}

/// Janela sobre a página com deslocamento vertical fracionário (interpolação linear entre linhas), como quando
/// o navegador compõe camadas em posições de meio píxel. `noise`: variação aleatória de ±noise por canal.
func fractionalWindow(_ page: PixelFrame, y: Double, w: Int, h: Int, noise: Int = 0, seed: UInt64 = 1) -> PixelFrame {
    var out = [UInt8](repeating: 255, count: w * h * 4)
    var rng = seed &* 6364136223846793005 &+ 1442695040888963407
    let y0 = Int(y.rounded(.down)), frac = y - Double(y0)
    for yy in 0..<h {
        let ra = (y0 + yy) * page.width * 4, rb = (y0 + yy + 1) * page.width * 4
        for x in 0..<w {
            for c in 0..<3 {
                let a = Double(page.rgba[ra + x * 4 + c]), b = Double(page.rgba[rb + x * 4 + c])
                var v = a * (1 - frac) + b * frac
                if noise > 0 { rng = rng &* 6364136223846793005 &+ 1442695040888963407; v += Double(Int(rng >> 33) % (2 * noise + 1) - noise) }
                out[(yy * w + x) * 4 + c] = UInt8(max(0, min(255, v.rounded())))
            }
        }
    }
    return PixelFrame(width: w, height: h, rgba: out)
}

@Suite struct BrowserLikeScrollTests {
    static let page = makeTextPage(width: 700, height: 2400)

    /// Rolagem lenta, com deslocamentos de meio píxel e um pouco de ruído: tem de juntar tudo, sem falhas.
    @Test func slowScrollWithHalfPixelOffsets() {
        var s = MosaicStitcher()
        var results: [MosaicStitcher.Result] = []
        var y = 0.0
        var n = 0
        while y < 2800 {
            results.append(s.add(fractionalWindow(Self.page, y: y, w: 1400, h: 1000, noise: 2, seed: UInt64(n + 1))))
            y += 37.5; n += 1
        }
        let failed = results.filter { $0 == .failed }.count
        #expect(failed == 0, "falhou \(failed) de \(results.count): \(results.prefix(12))")
        #expect(s.accepted >= results.count - 2, "aceites \(s.accepted) de \(results.count)")
        let out = s.result()
        #expect((out?.height ?? 0) >= 3700, "altura \(out?.height ?? 0)")
    }

    /// Meio píxel sem ruído e passos maiores.
    @Test func halfPixelBigSteps() {
        var s = MosaicStitcher()
        var failed = 0
        var y = 0.5
        while y < 2800 { if s.add(fractionalWindow(Self.page, y: y, w: 1400, h: 1000)) == .failed { failed += 1 }; y += 143.5 }
        #expect(failed == 0)
    }
}

@Suite struct ResumeTests {
    static let page = makeTextPage(width: 700, height: 2400)

    /// Depois de falhar (salto sem sobreposição com a captura anterior), volta a juntar ao regressar a uma zona
    /// vista antes (uma âncora), mesmo sem sobreposição com a última captura aceite.
    @Test func resumesFromAnEarlierAnchor() {
        var s = MosaicStitcher()
        for y in stride(from: 0, through: 2400, by: 300) { _ = s.add(crop(Self.page, x: 0, y: y, w: 1400, h: 1000)) }
        let h = s.size.height
        // a última aceite está em 2400; esta captura (1700…) só se sobrepõe às âncoras antigas
        #expect(s.add(crop(Self.page, x: 0, y: 3700, w: 1400, h: 1000)) == .failed)   // salto: nada em comum
        let r = s.add(crop(Self.page, x: 0, y: 600, w: 1400, h: 1000))               // volta a uma zona vista
        if case .moved = r {} else { Issue.record("não retomou: \(r)") }
        #expect(s.size.height == h)                                                   // não acrescentou nada, já estava lá
        // e continua a juntar a partir daí até ao fim
        for y in stride(from: 900, through: 3000, by: 300) { _ = s.add(crop(Self.page, x: 0, y: y, w: 1400, h: 1000)) }
        #expect(s.size.height == 3000 + 1000)
    }
}
