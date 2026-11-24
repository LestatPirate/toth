// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import Foundation

/// Preenchimento por vizinhança (ferramenta Reparo): a região escolhida é preenchida a partir dos píxeis que a rodeiam, por
/// difusão (cada píxel desconhecido tende para a média dos vizinhos, com a borda fixa), resolvida de grosso para fino para
/// convergir depressa. Só Foundation, sobre um buffer RGBA de 8 bits: testa-se sem imagens.
public enum Inpaint {
    /// Preenche `hole` (em píxeis do buffer, origem no canto superior esquerdo) a partir do que está à volta.
    /// `pixels`: RGBA intercalado, `width × height × 4`. A borda do buffer fora de `hole` é o que se conhece.
    /// `mask`: cobertura (`hole.w × hole.h`, 0…255) dentro do buraco; só os píxeis cobertos (> 127) são desconhecidos. `nil` = todos.
    public static func fill(_ pixels: inout [UInt8], width: Int, height: Int, hole: (x: Int, y: Int, w: Int, h: Int), mask: [UInt8]? = nil) {
        let x0 = max(0, hole.x), y0 = max(0, hole.y), x1 = min(width, hole.x + hole.w), y1 = min(height, hole.y + hole.h)
        guard x1 > x0, y1 > y0, width > 0, height > 0 else { return }
        func covered(_ x: Int, _ y: Int) -> Bool {
            guard let mask else { return true }
            let i = (y - hole.y) * hole.w + (x - hole.x)
            return i >= 0 && i < mask.count && mask[i] > 127
        }
        // trabalha em Float, por canal
        var img = [Float](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height * 4) { img[i] = Float(pixels[i]) }
        var known = [Bool](repeating: true, count: width * height)
        for y in y0..<y1 { for x in x0..<x1 where covered(x, y) { known[y * width + x] = false } }
        solve(&img, known: known, width: width, height: height)
        for y in y0..<y1 { for x in x0..<x1 where covered(x, y) { for c in 0..<4 { let i = (y * width + x) * 4 + c; pixels[i] = UInt8(max(0, min(255, img[i].rounded()))) } } }
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

    // MARK: Preenchimento por exemplos (PatchMatch)

    /// Quanta textura (rugosidade local) há na vizinhança conhecida do buraco: diferença média entre píxeis vizinhos, numa
    /// moldura à volta (0…255). Um fundo liso ou um gradiente dão quase zero (a difusão chega e fica mais limpa); ruído,
    /// padrões e riscas dão valores altos (vale a pena copiar pedaços).
    public static func surroundingTexture(_ pixels: [UInt8], width: Int, height: Int, hole: (x: Int, y: Int, w: Int, h: Int), ring: Int = 12) -> Double {
        let x0 = max(0, hole.x - ring), y0 = max(0, hole.y - ring), x1 = min(width - 1, hole.x + hole.w + ring), y1 = min(height - 1, hole.y + hole.h + ring)
        guard x1 > x0, y1 > y0 else { return 0 }
        func inHole(_ x: Int, _ y: Int) -> Bool { x >= hole.x && x < hole.x + hole.w && y >= hole.y && y < hole.y + hole.h }
        var sum = 0.0, n = 0.0
        for y in y0..<y1 { for x in x0..<x1 where !inHole(x, y) && !inHole(x + 1, y) && !inHole(x, y + 1) {
            let o = (y * width + x) * 4, r = o + 4, d = o + width * 4
            var e = 0
            for c in 0..<3 { e += abs(Int(pixels[o + c]) - Int(pixels[r + c])) + abs(Int(pixels[o + c]) - Int(pixels[d + c])) }
            sum += Double(e) / 6; n += 1
        } }
        return n > 0 ? sum / n : 0
    }

    /// Preenche `hole` copiando pedaços parecidos da vizinhança (PatchMatch com votação, de grosso para fino), como o
    /// «content-aware fill»: texturas, padrões e linhas continuam em vez de ficarem esborratados. Parte da difusão como
    /// estimativa inicial. Determinístico (gerador próprio). `mask`: como em `fill`.
    public static func fillExemplar(_ pixels: inout [UInt8], width: Int, height: Int, hole: (x: Int, y: Int, w: Int, h: Int), mask: [UInt8]? = nil) {
        let x0 = max(0, hole.x), y0 = max(0, hole.y), x1 = min(width, hole.x + hole.w), y1 = min(height, hole.y + hole.h)
        guard x1 > x0, y1 > y0, width >= 8, height >= 8 else { return }
        func covered(_ x: Int, _ y: Int) -> Bool {
            guard let mask else { return true }
            let i = (y - hole.y) * hole.w + (x - hole.x)
            return i >= 0 && i < mask.count && mask[i] > 127
        }
        var img = [Float](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height * 4) { img[i] = Float(pixels[i]) }
        var known = [Bool](repeating: true, count: width * height)
        for y in y0..<y1 { for x in x0..<x1 where covered(x, y) { known[y * width + x] = false } }
        // 1) estimativa inicial por difusão (dá a cor média certa; o PatchMatch põe-lhe a textura)
        solve(&img, known: known, width: width, height: height)
        // 2) pirâmide: até o buraco caber em ~24 px ou a imagem em 48
        var levels: [(img: [Float], known: [Bool], w: Int, h: Int)] = [(img, known, width, height)]
        while let top = levels.last, max(top.w, top.h) > 48, holeSize(top.known, top.w, top.h) > 24, levels.count < 4 {
            let (s2, k2, w2, h2) = downsample(top.img, known: top.known, width: top.w, height: top.h)
            levels.append((s2, k2, w2, h2))
        }
        var rng = UInt64(0x9E3779B97F4A7C15)
        var nnf: [Int32] = []   // por píxel desconhecido do nível: índice do centro de origem (ou −1)
        for li in stride(from: levels.count - 1, through: 0, by: -1) {
            var lvl = levels[li]
            if li < levels.count - 1 {
                // a solução do nível mais grosso entra como estimativa (só nos desconhecidos)
                let coarse = levels[li + 1]
                for y in 0..<lvl.h { for x in 0..<lvl.w where !lvl.known[y * lvl.w + x] {
                    let cx = min(coarse.w - 1, x / 2), cy = min(coarse.h - 1, y / 2)
                    for c in 0..<4 { lvl.img[(y * lvl.w + x) * 4 + c] = coarse.img[(cy * coarse.w + cx) * 4 + c] }
                } }
            }
            let rounds = li == levels.count - 1 ? 5 : (li == 0 ? 3 : 4)
            nnf = patchMatch(&lvl.img, known: lvl.known, width: lvl.w, height: lvl.h, rounds: rounds, seedNNF: li == levels.count - 1 ? nil : (nnf, levels[li + 1].w, levels[li + 1].h), rng: &rng)
            levels[li] = lvl
        }
        // (o nível mais fino já foi afinado com a estimativa dos grossos: guarda-se no nível 0)
        let fine = levels[0].img
        for y in y0..<y1 { for x in x0..<x1 where covered(x, y) { for c in 0..<4 { let i = (y * width + x) * 4 + c; pixels[i] = UInt8(max(0, min(255, fine[i].rounded()))) } } }
    }

    private static func holeSize(_ known: [Bool], _ w: Int, _ h: Int) -> Int {
        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h { for x in 0..<w where !known[y * w + x] { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) } }
        return maxX < minX ? 0 : max(maxX - minX + 1, maxY - minY + 1)
    }

    private static func rand(_ s: inout UInt64) -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }

    /// Um nível do PatchMatch: para cada píxel desconhecido procura o pedaço `P×P` conhecido mais parecido (propagação +
    /// procura aleatória), e os desconhecidos passam a ser a média dos pedaços que lhes calham (votação). Repete `rounds` vezes.
    /// Devolve o campo de correspondências (para semear o nível seguinte, mais fino).
    private static func patchMatch(_ img: inout [Float], known: [Bool], width w: Int, height h: Int, rounds: Int, seedNNF: ([Int32], Int, Int)?, rng: inout UInt64) -> [Int32] {
        let P = 7, half = 3
        // origens válidas: pedaços inteiramente dentro da imagem e sem píxeis desconhecidos
        var holeSum = [Int](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h { var row = 0; for x in 0..<w { row += known[y * w + x] ? 0 : 1; holeSum[(y + 1) * (w + 1) + (x + 1)] = holeSum[y * (w + 1) + (x + 1)] + row } }
        func holes(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Int { holeSum[y1 * (w + 1) + x1] - holeSum[y0 * (w + 1) + x1] - holeSum[y1 * (w + 1) + x0] + holeSum[y0 * (w + 1) + x0] }
        var validSrc = [Bool](repeating: false, count: w * h)
        var sources: [Int] = []
        for y in half..<(h - half) { for x in half..<(w - half) where holes(x - half, y - half, x + half + 1, y + half + 1) == 0 { validSrc[y * w + x] = true; sources.append(y * w + x) } }
        var targets: [Int] = []
        for i in 0..<(w * h) where !known[i] { targets.append(i) }
        guard !targets.isEmpty, !sources.isEmpty else { return [] }
        var nnf = [Int32](repeating: -1, count: w * h)
        var best = [Float](repeating: .greatestFiniteMagnitude, count: w * h)
        func dist(_ t: Int, _ s: Int, cutoff: Float) -> Float {
            let tx = t % w, ty = t / w, sx = s % w, sy = s / w
            var d: Float = 0
            for dy in -half...half {
                let ty2 = ty + dy, sy2 = sy + dy
                if ty2 < 0 || ty2 >= h { continue }
                for dx in -half...half {
                    let tx2 = tx + dx
                    if tx2 < 0 || tx2 >= w { continue }
                    let ti = (ty2 * w + tx2) * 4, si = (sy2 * w + sx + dx) * 4
                    for c in 0..<3 { let e = img[ti + c] - img[si + c]; d += e * e }
                }
                if d >= cutoff { return d }
            }
            return d
        }
        // semente: aleatória, ou herdada do nível grosso (coordenadas a dobrar)
        for t in targets {
            var s = -1
            // (um nível grosso sem pedaços de origem não devolve correspondências: a lista vem vazia e não serve de semente)
            if let (coarse, cw, ch) = seedNNF, cw > 0, ch > 0, coarse.count == cw * ch {
                let cx = min(cw - 1, (t % w) / 2), cy = min(ch - 1, (t / w) / 2)
                let cs = Int(coarse[cy * cw + cx])
                if cs >= 0 { let sx = min(w - half - 1, max(half, (cs % cw) * 2)), sy = min(h - half - 1, max(half, (cs / cw) * 2)); if validSrc[sy * w + sx] { s = sy * w + sx } }
            }
            if s < 0 { s = sources[Int(rand(&rng) % UInt64(sources.count))] }
            nnf[t] = Int32(s); best[t] = dist(t, s, cutoff: .greatestFiniteMagnitude)
        }
        let maxRadius = max(w, h)
        for round in 0..<rounds {
            // propagação + procura aleatória, alternando o sentido
            let order = round % 2 == 0 ? targets : targets.reversed()
            let step = round % 2 == 0 ? -1 : 1
            for t in order {
                let tx = t % w, ty = t / w
                func tryCandidate(_ s: Int) {
                    guard s >= 0, s < w * h, validSrc[s] else { return }
                    let d = dist(t, s, cutoff: best[t])
                    if d < best[t] { best[t] = d; nnf[t] = Int32(s) }
                }
                if tx - step >= 0 && tx - step < w { let n = t - step; if nnf[n] >= 0 { tryCandidate(Int(nnf[n]) + step) } }
                if ty - step >= 0 && ty - step < h { let n = t - step * w; if nnf[n] >= 0 { tryCandidate(Int(nnf[n]) + step * w) } }
                var radius = maxRadius
                let cur = Int(nnf[t]); let cx = cur % w, cy = cur / w
                while radius >= 1 {
                    let rx = Int(rand(&rng) % UInt64(2 * radius + 1)) - radius, ry = Int(rand(&rng) % UInt64(2 * radius + 1)) - radius
                    let sx = cx + rx, sy = cy + ry
                    if sx >= half, sx < w - half, sy >= half, sy < h - half { tryCandidate(sy * w + sx) }
                    radius /= 2
                }
            }
            // votação: cada desconhecido = o que os pedaços que o cobrem trazem, pesado pela qualidade do pedaço (os maus
            // quase não contam); na última ronda vence o melhor pedaço, para a textura ficar nítida em vez de uma média baça
            var acc = [Float](repeating: 0, count: w * h * 4), cnt = [Float](repeating: 0, count: w * h)
            var bestD = [Float](repeating: .greatestFiniteMagnitude, count: w * h)
            let meanD = max(1, targets.reduce(Float(0)) { $0 + min(best[$1], 1e9) } / Float(targets.count))
            let last = round == rounds - 1
            for t in targets {
                let s = Int(nnf[t]); guard s >= 0 else { continue }
                let tx = t % w, ty = t / w, sx = s % w, sy = s / w
                let wgt = last ? 1 : expf(-best[t] / (meanD * 0.5))
                for dy in -half...half { for dx in -half...half {
                    let px = tx + dx, py = ty + dy
                    guard px >= 0, px < w, py >= 0, py < h, !known[py * w + px] else { continue }
                    let pi = py * w + px, si = (sy + dy) * w + sx + dx
                    if last {
                        if best[t] < bestD[pi] { bestD[pi] = best[t]; for c in 0..<4 { acc[pi * 4 + c] = img[si * 4 + c] }; cnt[pi] = 1 }
                    } else {
                        for c in 0..<4 { acc[pi * 4 + c] += img[si * 4 + c] * wgt }
                        cnt[pi] += wgt
                    }
                } }
            }
            for t in targets where cnt[t] > 0 { for c in 0..<4 { img[t * 4 + c] = acc[t * 4 + c] / cnt[t] } }
            // as distâncias mudaram com a nova estimativa
            for t in targets where nnf[t] >= 0 { best[t] = dist(t, Int(nnf[t]), cutoff: .greatestFiniteMagnitude) }
        }
        return nnf
    }
}
