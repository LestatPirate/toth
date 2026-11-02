// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import Foundation

/// Preenchimento por vizinhança (ferramenta Reparo): a região escolhida é preenchida a partir dos píxeis que a rodeiam, por
/// difusão (cada píxel desconhecido tende para a média dos vizinhos, com a borda fixa), resolvida de grosso para fino para
/// convergir depressa. Só Foundation, sobre um buffer RGBA de 8 bits: testa-se sem imagens.
public enum Inpaint {
    /// Preenche `hole` (em píxeis do buffer, origem no canto superior esquerdo) a partir do que está à volta.
    /// `pixels`: RGBA intercalado, `width × height × 4`. A borda do buffer fora de `hole` é o que se conhece.
    public static func fill(_ pixels: inout [UInt8], width: Int, height: Int, hole: (x: Int, y: Int, w: Int, h: Int)) {
        let x0 = max(0, hole.x), y0 = max(0, hole.y), x1 = min(width, hole.x + hole.w), y1 = min(height, hole.y + hole.h)
        guard x1 > x0, y1 > y0, width > 0, height > 0 else { return }
        // trabalha em Float, por canal
        var img = [Float](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height * 4) { img[i] = Float(pixels[i]) }
        var known = [Bool](repeating: true, count: width * height)
        for y in y0..<y1 { for x in x0..<x1 { known[y * width + x] = false } }
        solve(&img, known: known, width: width, height: height)
        for y in y0..<y1 { for x in x0..<x1 { for c in 0..<4 { let i = (y * width + x) * 4 + c; pixels[i] = UInt8(max(0, min(255, img[i].rounded()))) } } }
    }

    /// Resolve por níveis: reduz a metade até caber em ~32 px, resolve lá (muitas iterações baratas), amplia a solução como
    /// ponto de partida do nível seguinte e afina com menos iterações.
    static func solve(_ img: inout [Float], known: [Bool], width: Int, height: Int) {
        if max(width, height) > 32, width >= 4, height >= 4 {
            let (small, smallKnown, w2, h2) = downsample(img, known: known, width: width, height: height)
            var s = small
            solve(&s, known: smallKnown, width: w2, height: h2)
            // ampliação bilinear da solução para os píxeis desconhecidos
            for y in 0..<height { for x in 0..<width where !known[y * width + x] {
                let fx = (Float(x) + 0.5) / Float(width) * Float(w2) - 0.5, fy = (Float(y) + 0.5) / Float(height) * Float(h2) - 0.5
                let ix = max(0, min(w2 - 1, Int(fx.rounded(.down)))), iy = max(0, min(h2 - 1, Int(fy.rounded(.down))))
                let jx = min(w2 - 1, ix + 1), jy = min(h2 - 1, iy + 1)
                let tx = max(0, min(1, fx - Float(ix))), ty = max(0, min(1, fy - Float(iy)))
                for c in 0..<4 {
                    let a = s[(iy * w2 + ix) * 4 + c], b = s[(iy * w2 + jx) * 4 + c], d = s[(jy * w2 + ix) * 4 + c], e = s[(jy * w2 + jx) * 4 + c]
                    img[(y * width + x) * 4 + c] = (a * (1 - tx) + b * tx) * (1 - ty) + (d * (1 - tx) + e * tx) * ty
                }
            } }
            relax(&img, known: known, width: width, height: height, iterations: 24)
        } else {
            // nível mais grosso: começa pela média da borda conhecida e itera até estabilizar
            var sum = [Float](repeating: 0, count: 4), n: Float = 0
            for i in 0..<(width * height) where known[i] { for c in 0..<4 { sum[c] += img[i * 4 + c] }; n += 1 }
            if n > 0 { for i in 0..<(width * height) where !known[i] { for c in 0..<4 { img[i * 4 + c] = sum[c] / n } } }
            relax(&img, known: known, width: width, height: height, iterations: 400)
        }
    }

    /// Iterações de Gauss-Seidel: cada píxel desconhecido passa a ser a média dos 4 vizinhos.
    static func relax(_ img: inout [Float], known: [Bool], width: Int, height: Int, iterations: Int) {
        var unknown: [Int] = []
        for i in 0..<(width * height) where !known[i] { unknown.append(i) }
        guard !unknown.isEmpty else { return }
        for it in 0..<iterations {
            // alterna a ordem para a solução não se inclinar para um lado
            let order = it % 2 == 0 ? unknown : unknown.reversed()
            for i in order {
                let x = i % width, y = i / width
                var sum = [Float](repeating: 0, count: 4), k: Float = 0
                if x > 0 { for c in 0..<4 { sum[c] += img[(i - 1) * 4 + c] }; k += 1 }
                if x < width - 1 { for c in 0..<4 { sum[c] += img[(i + 1) * 4 + c] }; k += 1 }
                if y > 0 { for c in 0..<4 { sum[c] += img[(i - width) * 4 + c] }; k += 1 }
                if y < height - 1 { for c in 0..<4 { sum[c] += img[(i + width) * 4 + c] }; k += 1 }
                if k > 0 { for c in 0..<4 { img[i * 4 + c] = sum[c] / k } }
            }
        }
    }

    /// Metade do tamanho: cada píxel é a média dos conhecidos do bloco 2×2 (desconhecido só se todos o forem).
    static func downsample(_ img: [Float], known: [Bool], width: Int, height: Int) -> ([Float], [Bool], Int, Int) {
        let w2 = max(1, width / 2), h2 = max(1, height / 2)
        var out = [Float](repeating: 0, count: w2 * h2 * 4)
        var k2 = [Bool](repeating: false, count: w2 * h2)
        for y in 0..<h2 { for x in 0..<w2 {
            var sum = [Float](repeating: 0, count: 4), n: Float = 0, any = [Float](repeating: 0, count: 4), m: Float = 0
            for dy in 0..<2 { for dx in 0..<2 {
                let sx = min(width - 1, x * 2 + dx), sy = min(height - 1, y * 2 + dy), i = sy * width + sx
                for c in 0..<4 { any[c] += img[i * 4 + c] }; m += 1
                if known[i] { for c in 0..<4 { sum[c] += img[i * 4 + c] }; n += 1 }
            } }
            let o = y * w2 + x
            k2[o] = n > 0
            for c in 0..<4 { out[o * 4 + c] = n > 0 ? sum[c] / n : any[c] / m }
        } }
        return (out, k2, w2, h2)
    }
}
