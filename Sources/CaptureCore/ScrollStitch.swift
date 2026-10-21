// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import Foundation

// Junção de capturas sucessivas de uma região que vai rolando (captura por rolagem).
// Só Foundation: trabalha sobre bytes RGBA, sem depender de nenhuma API gráfica.
//
// O utilizador rola à vontade (para qualquer lado, voltando atrás se quiser) e a app vai recebendo capturas da região.
// Entre duas capturas seguidas mede-se quanto o conteúdo andou, num eixo de cada vez (procurando o deslocamento em que
// as linhas ou colunas coincidem), e cada captura é "carimbada" numa tela que cresce para todos os lados; só se
// preenchem os píxeis ainda vazios, por isso passar outra vez pela mesma zona não estraga nada. Faixas fixas
// (cabeçalho, rodapé, barras) são detetadas por não mudarem e voltam a juntar-se uma só vez, nas pontas.

/// Imagem RGBA de 8 bits (4 bytes por píxel, linha a linha, origem no canto superior esquerdo).
public struct PixelFrame: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public var rgba: [UInt8]

    public init(width: Int, height: Int, rgba: [UInt8]) {
        precondition(rgba.count == width * height * 4, "tamanho de bytes inválido")
        self.width = width; self.height = height; self.rgba = rgba
    }

    public init(width: Int, height: Int) {
        self.init(width: width, height: height, rgba: [UInt8](repeating: 0, count: width * height * 4))
    }

    /// Troca linhas por colunas (x↔y).
    public func transposed() -> PixelFrame {
        var out = [UInt8](repeating: 0, count: rgba.count)
        let w = width, h = height
        rgba.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    for x in 0..<w {
                        let s = (y * w + x) * 4, d = (x * h + y) * 4
                        dst[d] = src[s]; dst[d + 1] = src[s + 1]; dst[d + 2] = src[s + 2]; dst[d + 3] = src[s + 3]
                    }
                }
            }
        }
        return PixelFrame(width: h, height: w, rgba: out)
    }

    /// Inverte a ordem das linhas (de cima para baixo).
    public func flippedVertically() -> PixelFrame {
        var out = [UInt8](repeating: 0, count: rgba.count)
        let stride = width * 4
        for y in 0..<height {
            let s = y * stride, d = (height - 1 - y) * stride
            out.replaceSubrange(d..<d + stride, with: rgba[s..<s + stride])
        }
        return PixelFrame(width: width, height: height, rgba: out)
    }

    /// `true` se as duas imagens são praticamente iguais (amostra uma grelha de píxeis; tolera ruído mínimo).
    public func isApproximatelyEqual(to other: PixelFrame, tolerance: Int = 4) -> Bool {
        guard width == other.width, height == other.height else { return false }
        let sx = max(1, width / 64), sy = max(1, height / 64)
        var total = 0, same = 0
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let i = (y * width + x) * 4
                total += 1
                if abs(Int(rgba[i]) - Int(other.rgba[i])) <= tolerance,
                   abs(Int(rgba[i + 1]) - Int(other.rgba[i + 1])) <= tolerance,
                   abs(Int(rgba[i + 2]) - Int(other.rgba[i + 2])) <= tolerance { same += 1 }
                x += sx
            }
            y += sy
        }
        return total > 0 && Double(same) / Double(total) >= 0.999
    }
}

/// Plano de cinzentos (para comparar mais depressa).
struct GrayPlane {
    let width: Int
    let height: Int
    var px: [UInt8]

    init(_ f: PixelFrame) {
        width = f.width; height = f.height
        var g = [UInt8](repeating: 0, count: f.width * f.height)
        f.rgba.withUnsafeBufferPointer { s in
            for i in 0..<g.count {
                let j = i * 4
                g[i] = UInt8((Int(s[j]) * 77 + Int(s[j + 1]) * 150 + Int(s[j + 2]) * 29) >> 8)
            }
        }
        px = g
    }

    private init(width: Int, height: Int, px: [UInt8]) { self.width = width; self.height = height; self.px = px }

    /// Reduz por `f` em cada eixo (média de cada bloco): apaga diferenças de meio píxel e ruído.
    func downsampled(_ f: Int) -> GrayPlane {
        guard f > 1 else { return self }
        let nw = width / f, nh = height / f
        var out = [UInt8](repeating: 0, count: nw * nh)
        let area = f * f
        px.withUnsafeBufferPointer { s in
            for y in 0..<nh {
                for x in 0..<nw {
                    var sum = 0
                    for dy in 0..<f { let row = (y * f + dy) * width + x * f; for dx in 0..<f { sum += Int(s[row + dx]) } }
                    out[y * nw + x] = UInt8(sum / area)
                }
            }
        }
        return GrayPlane(width: nw, height: nh, px: out)
    }

    /// Troca linhas por colunas.
    func transposed() -> GrayPlane {
        var out = [UInt8](repeating: 0, count: px.count)
        for y in 0..<height { for x in 0..<width { out[x * height + y] = px[y * width + x] } }
        return GrayPlane(width: height, height: width, px: out)
    }
}

/// Cinzentos em tamanho real e reduzidos (para a procura grosseira).
struct GrayPyramid {
    let full: GrayPlane
    let coarse: GrayPlane
    let factor: Int

    init(_ full: GrayPlane) {
        self.full = full
        factor = full.height >= 600 && full.width >= 600 ? 4 : (full.height >= 200 && full.width >= 200 ? 2 : 1)
        coarse = full.downsampled(factor)
    }

    private init(full: GrayPlane, coarse: GrayPlane, factor: Int) { self.full = full; self.coarse = coarse; self.factor = factor }

    func transposed() -> GrayPyramid { GrayPyramid(full: full.transposed(), coarse: coarse.transposed(), factor: factor) }
}

enum ScrollMatcher {
    static let tolerance = 12          // diferença de cinzento aceite como "igual" ao comparar deslocamentos
    static let fixedTolerance = 6      // idem, ao detetar faixas fixas (d = 0)

    struct Analysis {
        var unchanged: Bool
        var sameFraction: Double       // fração de píxeis amostrados iguais sem deslocamento
        var fixedTop: Int              // faixas iguais sem deslocamento (para carimbar com prioridade baixa)
        var fixedBottom: Int
        var matchTop: Int              // idem, sem as linhas uniformes (para procurar o deslocamento: linhas em branco não contam)
        var matchBottom: Int
        var columns: [Int]             // colunas usadas para comparar (sem as fixas), amostradas
        var dense: [Int]               // todas as colunas equivalentes (para o refinamento)
    }

    static func sampleColumns(_ w: Int, count: Int = 96) -> [Int] {
        let s = max(1, w / count)
        return Array(stride(from: s / 2, to: w, by: s))
    }

    /// Compara as duas imagens sem deslocamento: diz se são iguais e quais as faixas que não mudam.
    static func analyze(_ a: GrayPlane, _ b: GrayPlane) -> Analysis {
        let w = a.width, h = a.height
        let xs = sampleColumns(w)
        var rowSame = [Bool](repeating: false, count: h)
        var sameCount = 0, total = 0
        for y in 0..<h {
            var s = 0
            for x in xs {
                let i = y * w + x
                if abs(Int(a.px[i]) - Int(b.px[i])) <= fixedTolerance { s += 1 }
            }
            sameCount += s; total += xs.count
            rowSame[y] = Double(s) >= 0.96 * Double(xs.count)   // tolera um elemento a piscar (relógio, cursor) dentro da faixa
        }
        let sameFraction = total > 0 ? Double(sameCount) / Double(total) : 1
        let unchanged = sameFraction >= 0.998

        let cap = Int(Double(h) * 0.3)
        var top = 0
        while top < cap && rowSame[top] { top += 1 }
        var bottom = 0
        while bottom < cap && rowSame[h - 1 - bottom] { bottom += 1 }

        // Para procurar o deslocamento só contam as faixas com conteúdo: margens em branco iguais nas duas imagens
        // não são "cabeçalho", e se contassem encolhiam a zona de procura.
        func uniform(_ y: Int) -> Bool {
            var lo = 255, hi = 0
            for x in xs { let v = Int(b.px[y * w + x]); if v < lo { lo = v }; if v > hi { hi = v } }
            return hi - lo <= 20
        }
        var matchTop = top, matchBottom = bottom
        while matchTop > 0 && uniform(matchTop - 1) { matchTop -= 1 }
        while matchBottom > 0 && uniform(h - matchBottom) { matchBottom -= 1 }

        // colunas que não mudam em (quase) nenhuma linha: barras laterais fixas
        var usable: [Int] = []
        let ystep = max(1, (h - top - bottom) / 120)
        for x in xs {
            var s = 0, n = 0
            var y = top
            while y < h - bottom {
                let i = y * w + x
                if abs(Int(a.px[i]) - Int(b.px[i])) <= fixedTolerance { s += 1 }
                n += 1; y += ystep
            }
            if n == 0 || Double(s) / Double(n) < 0.98 { usable.append(x) }
        }
        if usable.count < 8 { usable = xs }
        // todas as colunas cuja amostra mais próxima não é fixa
        let stride = max(1, w / 96)
        let ok = Set(usable)
        var dense: [Int] = []
        for x in 0..<w {
            let k = min(xs.count - 1, x / stride)
            if ok.contains(xs[k]) { dense.append(x) }
        }
        return Analysis(unchanged: unchanged, sameFraction: sameFraction, fixedTop: top, fixedBottom: bottom, matchTop: matchTop, matchBottom: matchBottom, columns: usable, dense: dense)
    }


    struct Estimate { var shift: Int; var error: Double; var baseline: Double }

    /// Deslocamento (com sinal) de `next` em relação a `prev` ao longo das linhas: `shift > 0` = o conteúdo subiu
    /// `shift` píxeis (`next[y] ≈ prev[y + shift]`); `< 0` = desceu.
    ///
    /// Em vez de exigir que as linhas coincidam quase na perfeição (um navegador desenha o conteúdo rolado com
    /// meios píxeis e ruído, e isso nunca coincide), mede-se o erro médio de cada deslocamento: primeiro nas imagens
    /// reduzidas (a média apaga o meio píxel), depois refina-se ao píxel. Só aceita se o melhor deslocamento for
    /// claramente melhor do que o típico (sem isso, não há alinhamento fiável).
    /// `hint`: último deslocamento com sinal; desempata conteúdo repetido pela continuidade do movimento.
    static func estimate(prev: GrayPyramid, next: GrayPyramid, top: Int, bottom: Int, columns: [Int], dense: [Int], hint: Int?) -> Estimate? {
        let f = next.factor
        let cw = next.coarse.width, ch = next.coarse.height
        let cTop = (top + f - 1) / f, cEnd = ch - (bottom + f - 1) / f
        let region = cEnd - cTop
        guard region >= 12, !columns.isEmpty else { return nil }

        var cc = Array(Set(columns.map { min(cw - 1, $0 / f) })).sorted()
        if cc.count > 80 { let k = (cc.count + 79) / 80; cc = cc.enumerated().filter { $0.offset % k == 0 }.map(\.element) }

        // Linhas que informam sobre a posição vertical: têm contraste e mudam em relação às vizinhas. (Uma linha
        // dentro de um gradiente horizontal liso tem contraste mas é igual à de cima e à de baixo: alinha com tudo.)
        func informativeRows(_ p: GrayPlane, lo: Int, hi: Int, threshold: Int, cols: [Int], cap: Int, step: Int) -> [Int] {
            var rows: [Int] = [], contrastOnly: [Int] = []
            for y in lo..<hi {
                var mn = 255, mx = 0, vert = 0
                let y2 = y + step < p.height ? y + step : y - step
                for x in cols {
                    let v = Int(p.px[y * p.width + x])
                    if v < mn { mn = v }; if v > mx { mx = v }
                    if y2 >= 0 { vert += abs(v - Int(p.px[y2 * p.width + x])) }
                }
                if mx - mn > threshold {
                    contrastOnly.append(y)
                    if Double(vert) / Double(max(1, cols.count)) >= 0.5 { rows.append(y) }
                }
            }
            // Zona quase toda lisa (caixas de cor, fundos): sem linhas que variem na vertical, valem as de contraste.
            if rows.count < 12 { rows = contrastOnly }
            if rows.count > cap { let k = (rows.count + cap - 1) / cap; rows = rows.enumerated().filter { $0.offset % k == 0 }.map(\.element) }
            return rows
        }

        let minOverlap = max(8, region / 10)
        let maxD = region - minOverlap
        guard maxD >= 1 else { return nil }

        // erros por deslocamento: `errs[i]` para shift = +(i+1) e `errsNeg[i]` para shift = -(i+1)
        func errors(ref: GrayPlane, other: GrayPlane) -> [Double] {
            // ref[y] ≈ other[y + d]
            let rows = informativeRows(ref, lo: cTop, hi: cEnd, threshold: 12, cols: cc, cap: 160, step: 1)
            var out = [Double](repeating: .infinity, count: maxD)
            guard rows.count >= 6 else { return out }
            ref.px.withUnsafeBufferPointer { rp in
                other.px.withUnsafeBufferPointer { op in
                    for d in 1...maxD {
                        var sum = 0, n = 0
                        for y in rows {
                            if y + d >= cEnd { break }
                            let ri = y * cw, oi = (y + d) * cw
                            for x in cc { sum += abs(Int(rp[ri + x]) - Int(op[oi + x])) }
                            n += cc.count
                        }
                        if n >= 6 * cc.count { out[d - 1] = Double(sum) / Double(n) }
                    }
                }
            }
            return out
        }
        let pos = errors(ref: next.coarse, other: prev.coarse)     // next[y] ≈ prev[y + d]  ⇒ shift +d
        let neg = errors(ref: prev.coarse, other: next.coarse)     // prev[y] ≈ next[y + d]  ⇒ shift −d
        var all: [(shift: Int, err: Double)] = []
        for i in 0..<maxD { if pos[i].isFinite { all.append((i + 1, pos[i])) }; if neg[i].isFinite { all.append((-(i + 1), neg[i])) } }
        guard all.count >= 8, let minErr = all.map(\.err).min() else { return nil }
        let sorted = all.map(\.err).sorted()
        let baseline = sorted[sorted.count / 2]
        // Só vale se o melhor for claramente melhor do que o típico e, em absoluto, baixo.
        // (Sem limite absoluto: com um deslocamento ímpar e redução por 2, o contorno nítido fica meio píxel desalinhado
        // e o erro grosseiro sobe mesmo com alinhamento perfeito; o tamanho real é verificado a seguir.)
        guard minErr <= 0.45 * baseline else { return nil }

        // Entre os quase tão bons como o melhor (conteúdo repetido), o mais próximo do último deslocamento.
        let ref = hint ?? 0
        let near = all.filter { $0.err <= minErr * 1.25 + 0.5 }
        let c = near.min { abs($0.shift * f - ref) < abs($1.shift * f - ref) }!.shift

        // Refinamento ao píxel, em tamanho real, com todas as colunas.
        let fw = next.full.width, fh = next.full.height
        let fTop = top, fEnd = fh - bottom
        var dcols = dense
        if dcols.count > 700 { let k = (dcols.count + 699) / 700; dcols = dcols.enumerated().filter { $0.offset % k == 0 }.map(\.element) }
        let refPlane = c > 0 ? next.full : prev.full
        let othPlane = c > 0 ? prev.full : next.full
        let frows = informativeRows(refPlane, lo: fTop, hi: fEnd, threshold: 20, cols: Array(columns), cap: 300, step: 3)
        // O refinamento compara todas as linhas da sobreposição (as de contorno sozinhas deixam passar um desvio de 2 px
        // em arte plana); as "informativas" servem só para decidir se há por onde alinhar.
        let allRows = Array(stride(from: fTop, to: fEnd, by: 2))
        guard frows.count >= 6, !dcols.isEmpty else { return nil }
        func fullError(_ fs: Int) -> Double? {
            let d = abs(fs)
            guard d >= 1, d < fEnd - fTop - 16 else { return nil }
            let (r, o) = fs > 0 ? (next.full, prev.full) : (prev.full, next.full)
            var sum = 0, n = 0
            r.px.withUnsafeBufferPointer { rp in
                o.px.withUnsafeBufferPointer { op in
                    for y in allRows {
                        if y + d >= fEnd { break }
                        let ri = y * fw, oi = (y + d) * fw
                        for x in dcols { sum += abs(Int(rp[ri + x]) - Int(op[oi + x])) }
                        n += dcols.count
                    }
                }
            }
            return n >= 6 * dcols.count ? Double(sum) / Double(n) : nil
        }
        var bestShift = c * f, bestErr = Double.infinity
        for fs in (c * f - f)...(c * f + f) where fs != 0 && (fs > 0) == (c > 0) {
            if let e = fullError(fs), e < bestErr { bestErr = e; bestShift = fs }
        }
        guard bestErr.isFinite, bestErr <= 25 else { return nil }
        // Contra falsos alinhamentos (texto parecido com texto): o melhor tem de ser muito melhor do que
        // deslocamentos errados nas proximidades.
        var wrong: [Double] = []
        for delta in [-97, -41, 37, 83, 151] { if let e = fullError(bestShift + delta) { wrong.append(e) } }
        if wrong.count >= 3 {
            let w = wrong.reduce(0, +) / Double(wrong.count)
            // Medido: alinhamentos verdadeiros (mesmo com meios píxeis e ruído) dão ~0,1; texto contra texto sem nada em comum, ~0,4.
            guard bestErr <= 0.28 * w else { return nil }
        }
        // Um alinhamento verdadeiro concorda em (quase) todas as linhas da sobreposição; um falso pode concordar só
        // nas zonas lisas (um gradiente alinha com qualquer deslocamento) e falhar nas linhas de texto.
        func agreement(_ fs: Int) -> (good: Int, active: Int) {
            let d = abs(fs)
            let (r, o) = fs > 0 ? (next.full, prev.full) : (prev.full, next.full)
            let cols = stride(from: 0, to: dcols.count, by: 4).map { dcols[$0] }
            var good = 0, active = 0
            var y = fTop
            while y + d < fEnd {
                var sum = 0, lo = 255, hi = 0, lo2 = 255, hi2 = 0
                for x in cols {
                    let a = Int(r.px[y * fw + x]), b = Int(o.px[(y + d) * fw + x])
                    sum += abs(a - b)
                    lo = min(lo, a); hi = max(hi, a); lo2 = min(lo2, b); hi2 = max(hi2, b)
                }
                if hi - lo > 20 || hi2 - lo2 > 20 {
                    active += 1
                    if Double(sum) / Double(max(1, cols.count)) <= 14 { good += 1 }
                }
                y += 3
            }
            return (good, active)
        }
        let ag = agreement(bestShift)
        guard ag.active >= 8, Double(ag.good) >= 0.75 * Double(ag.active) else { return nil }
        return Estimate(shift: bestShift, error: bestErr, baseline: baseline)
    }
}

/// Tela que cresce para todos os lados. O alfa de cada píxel é a prioridade de quem o escreveu: 0 = vazio,
/// 1 = veio de uma faixa que parece fixa (cabeçalho, rodapé…), 255 = conteúdo normal. Só se escreve por cima de prioridade menor.
struct MosaicCanvas {
    private(set) var x0 = 0, y0 = 0, width = 0, height = 0       // retângulo alocado
    private(set) var data: [UInt8] = []
    /// Retângulo com píxeis carimbados (x0, y0, x1, y1), em coordenadas da tela.
    private(set) var used: (x0: Int, y0: Int, x1: Int, y1: Int)?

    static let maxPixels = 150_000_000       // ~600 MB
    static let maxSide = 30_000

    var isEmpty: Bool { used == nil }

    /// Garante espaço para `[rx0, rx1) × [ry0, ry1)`; devolve `false` se passaria dos limites.
    mutating func ensure(_ rx0: Int, _ ry0: Int, _ rx1: Int, _ ry1: Int) -> Bool {
        if width > 0, rx0 >= x0, ry0 >= y0, rx1 <= x0 + width, ry1 <= y0 + height { return true }
        var nx0 = rx0, ny0 = ry0, nx1 = rx1, ny1 = ry1
        if width > 0 {
            let slackX = max(width / 4, 64), slackY = max(height / 4, 256)
            nx0 = rx0 < x0 ? rx0 - slackX : x0; ny0 = ry0 < y0 ? ry0 - slackY : y0
            nx1 = rx1 > x0 + width ? rx1 + slackX : x0 + width; ny1 = ry1 > y0 + height ? ry1 + slackY : y0 + height
        }
        let nw = nx1 - nx0, nh = ny1 - ny0
        guard nw <= Self.maxSide, nh <= Self.maxSide, nw * nh <= Self.maxPixels else {
            // Sem folga ainda cabe?
            let w2 = max(x0 + width, rx1) - min(x0, rx0), h2 = max(y0 + height, ry1) - min(y0, ry0)
            guard width > 0, w2 <= Self.maxSide, h2 <= Self.maxSide, w2 * h2 <= Self.maxPixels else { return false }
            return regrow(min(x0, rx0), min(y0, ry0), max(x0 + width, rx1), max(y0 + height, ry1))
        }
        return regrow(nx0, ny0, nx1, ny1)
    }

    private mutating func regrow(_ nx0: Int, _ ny0: Int, _ nx1: Int, _ ny1: Int) -> Bool {
        let nw = nx1 - nx0, nh = ny1 - ny0
        var out = [UInt8](repeating: 0, count: nw * nh * 4)
        if width > 0 {
            let rowBytes = width * 4
            for y in 0..<height {
                let d = ((y + y0 - ny0) * nw + (x0 - nx0)) * 4
                out.replaceSubrange(d..<d + rowBytes, with: data[(y * width * 4)..<(y * width * 4 + rowBytes)])
            }
        }
        data = out; x0 = nx0; y0 = ny0; width = nw; height = nh
        return true
    }

    /// Carimba `frame`, colocada com o canto superior esquerdo em `(px, py)`. As faixas (`top`, `bottom`, `left`, `right`:
    /// as que parecem fixas) entram com prioridade baixa: o conteúdo de qualquer outra captura passa por cima delas.
    /// Assim, um cabeçalho ou rodapé verdadeiro fica nas pontas (mais nada cobre essas linhas) e uma faixa mal detetada
    /// não estraga nada.
    mutating func stamp(_ frame: PixelFrame, at px: Int, _ py: Int, top: Int, bottom: Int, left: Int, right: Int) {
        let w = frame.width, h = frame.height
        guard w > 0, h > 0 else { return }
        frame.rgba.withUnsafeBufferPointer { src in
            data.withUnsafeMutableBufferPointer { dst in
                for fy in 0..<h {
                    let rowBand = fy < top || fy >= h - bottom
                    var s = fy * w * 4
                    var d = (((py + fy) - y0) * width + (px - x0)) * 4
                    for fx in 0..<w {
                        let prio: UInt8 = (rowBand || fx < left || fx >= w - right) ? 1 : 255
                        if dst[d + 3] < prio {
                            dst[d] = src[s]; dst[d + 1] = src[s + 1]; dst[d + 2] = src[s + 2]; dst[d + 3] = prio
                        }
                        s += 4; d += 4
                    }
                }
            }
        }
        let r = (x0: px, y0: py, x1: px + w, y1: py + h)
        if let u = used { used = (min(u.x0, r.x0), min(u.y0, r.y0), max(u.x1, r.x1), max(u.y1, r.y1)) } else { used = r }
    }

    /// Cópia de `[rx0, rx1) × [ry0, ry1)` (píxeis vazios com `fill`).
    func crop(_ rx0: Int, _ ry0: Int, _ rx1: Int, _ ry1: Int, into out: inout [UInt8], outWidth: Int, at ox: Int, _ oy: Int) {
        for y in ry0..<ry1 {
            for x in rx0..<rx1 {
                let cx = x - x0, cy = y - y0
                guard cx >= 0, cy >= 0, cx < width, cy < height else { continue }
                let s = (cy * width + cx) * 4
                if data[s + 3] == 0 { continue }
                let d = ((oy + y - ry0) * outWidth + (ox + x - rx0)) * 4
                out[d] = data[s]; out[d + 1] = data[s + 1]; out[d + 2] = data[s + 2]; out[d + 3] = 255
            }
        }
    }
}

/// Junta capturas sucessivas, vindas de uma rolagem feita pelo utilizador (qualquer eixo, qualquer sentido,
/// com idas e voltas), numa única imagem.
public struct MosaicStitcher {
    public enum Result: Equatable {
        case first
        case unchanged               // nada de relevante mudou (ou só mudou algo pequeno, sem rolagem)
        case moved(dx: Int, dy: Int) // a captura entrou na imagem, deslocada (dx, dy) da anterior
        case failed                  // não foi possível alinhar com nenhuma captura recente
        case limit                   // a imagem atingiu o tamanho máximo
    }

    /// Captura já aceite, guardada (só em cinzentos) para se poder retomar a partir dela.
    private struct Anchor { var pyramid: GrayPyramid; var pos: (x: Int, y: Int) }

    private var prev: PixelFrame?
    private var prevPyramid: GrayPyramid?
    private var prevPyramidT: GrayPyramid?
    private var anchors: [Anchor] = []
    private var pos = (x: 0, y: 0)
    private var canvas = MosaicCanvas()
    private var lastAxisVertical = true
    private var lastShift: [Bool: Int] = [:]
    private static let maxAnchors = 6

    // Faixas fixas (cabeçalho, rodapé, barras), bloqueadas na primeira rolagem em cada eixo.
    private var lockedV = false, lockedH = false
    private var top = 0, bottom = 0, left = 0, right = 0
    private var matchTopV = 0, matchBottomV = 0, matchLeft = 0, matchRight = 0

    /// Quantas capturas entraram na imagem.
    public private(set) var accepted = 0

    public init() {}

    /// Tamanho atual da imagem final.
    public var size: (width: Int, height: Int) {
        guard let p = prev else { return (0, 0) }
        guard let u = canvas.used else { return (p.width, p.height) }
        return (u.x1 - u.x0, u.y1 - u.y0)
    }

    private struct Found { var vertical: Bool; var shift: Int; var analysis: ScrollMatcher.Analysis; var ref: Anchor? }

    /// Procura o deslocamento de `pyr` em relação a `ref` (a captura anterior ou uma âncora).
    private mutating func align(_ pyr: GrayPyramid, against ref: GrayPyramid, refT: GrayPyramid?, useLastAxisFirst: Bool) -> (Found, GrayPyramid?)? {
        let a = ScrollMatcher.analyze(ref.full, pyr.full)
        // Igual à referência (típico de uma âncora: o utilizador voltou exatamente ao mesmo sítio): deslocamento 0.
        if a.unchanged { return (Found(vertical: lastAxisVertical, shift: 0, analysis: a, ref: nil), nil) }
        var pyrT: GrayPyramid?
        for vertical in [lastAxisVertical, !lastAxisVertical] {
            var A = ref, B = pyr, an = a
            if !vertical {
                pyrT = pyrT ?? pyr.transposed()
                A = refT ?? ref.transposed(); B = pyrT!
                an = ScrollMatcher.analyze(A.full, B.full)
            }
            let t = vertical ? (lockedV ? matchTopV : an.matchTop) : (lockedH ? matchLeft : an.matchTop)
            let b = vertical ? (lockedV ? matchBottomV : an.matchBottom) : (lockedH ? matchRight : an.matchBottom)
            if let e = ScrollMatcher.estimate(prev: A, next: B, top: t, bottom: b, columns: an.columns, dense: an.dense, hint: lastShift[vertical]) {
                return (Found(vertical: vertical, shift: e.shift, analysis: an, ref: nil), pyrT)
            }
        }
        return nil
    }

    public mutating func add(_ frame: PixelFrame) -> Result {
        guard let p = prev, let pp = prevPyramid else {
            let pyr = GrayPyramid(GrayPlane(frame))
            prev = frame; prevPyramid = pyr
            anchors = [Anchor(pyramid: pyr, pos: pos)]
            return .first
        }
        guard frame.width == p.width, frame.height == p.height else { return .failed }
        let pyr = GrayPyramid(GrayPlane(frame))
        let a = ScrollMatcher.analyze(pp.full, pyr.full)
        if a.unchanged { return .unchanged }

        // 1) contra a captura anterior (os dois eixos); 2) contra as âncoras, da mais recente para a mais antiga
        //    (é o que permite retomar depois de uma pausa, de rolar depressa demais ou de voltar atrás).
        var result: (found: Found, refPos: (x: Int, y: Int), pyrT: GrayPyramid?)?
        if prevPyramidT == nil && !lastAxisVertical { prevPyramidT = pp.transposed() }
        if let (f, t) = align(pyr, against: pp, refT: prevPyramidT, useLastAxisFirst: true) { result = (f, pos, t) }
        if result == nil {
            for anchor in anchors.reversed() {
                if let (f, t) = align(pyr, against: anchor.pyramid, refT: nil, useLastAxisFirst: true) { result = (f, anchor.pos, t); break }
            }
        }
        guard let r = result else {
            // Sem alinhamento: se quase tudo está igual, foi só uma mudança pequena (cursor, relógio, vídeo).
            // (0,99: uma página quase toda branca tem sempre muitos píxeis iguais, mesmo depois de rolar muito.)
            return a.sameFraction >= 0.99 ? .unchanged : .failed
        }
        let f = r.found

        // Bloqueia as faixas fixas deste eixo na primeira vez (com um deslocamento real).
        if f.shift == 0 {
        } else if f.vertical && !lockedV {
            lockedV = true; top = f.analysis.fixedTop; bottom = f.analysis.fixedBottom
            matchTopV = f.analysis.matchTop; matchBottomV = f.analysis.matchBottom
        } else if !f.vertical && !lockedH {
            lockedH = true; left = f.analysis.fixedTop; right = f.analysis.fixedBottom   // (as "linhas" do plano transposto são colunas)
            matchLeft = f.analysis.matchTop; matchRight = f.analysis.matchBottom
        }

        let newPos = f.vertical ? (x: r.refPos.x, y: r.refPos.y + f.shift) : (x: r.refPos.x + f.shift, y: r.refPos.y)
        // Primeira rolagem: a captura inicial só agora entra na tela (já sem as faixas fixas).
        if canvas.isEmpty {
            guard stamp(p, at: pos) else { return .limit }
        }
        guard stamp(frame, at: newPos) else { return .limit }

        let dx = newPos.x - pos.x, dy = newPos.y - pos.y
        lastAxisVertical = f.vertical
        lastShift[f.vertical] = f.vertical ? dy : dx
        pos = newPos
        prev = frame; prevPyramid = pyr
        prevPyramidT = f.vertical ? nil : (r.pyrT ?? pyr.transposed())
        accepted += 1
        // âncora nova quando já andou o suficiente desde a última
        let extent = f.vertical ? frame.height : frame.width
        if let lastAnchor = anchors.last {
            let dist = f.vertical ? abs(pos.y - lastAnchor.pos.y) : abs(pos.x - lastAnchor.pos.x)
            let other = f.vertical ? abs(pos.x - lastAnchor.pos.x) : abs(pos.y - lastAnchor.pos.y)
            if dist >= extent / 4 || other >= extent / 4 {
                anchors.append(Anchor(pyramid: pyr, pos: pos))
                if anchors.count > Self.maxAnchors { anchors.removeFirst() }
            }
        }
        return .moved(dx: dx, dy: dy)
    }

    private mutating func stamp(_ f: PixelFrame, at p: (x: Int, y: Int)) -> Bool {
        guard canvas.ensure(p.x, p.y, p.x + f.width, p.y + f.height) else { return false }
        canvas.stamp(f, at: p.x, p.y, top: top, bottom: bottom, left: left, right: right)
        return true
    }

    /// A imagem final. Sem rolagem, a única captura. Zonas sem nada (cantos de um percurso em "L") ficam com a cor de fundo.
    public func result() -> PixelFrame? {
        guard let p = prev else { return nil }
        guard let u = canvas.used else { return p }
        let w = u.x1 - u.x0, h = u.y1 - u.y0
        guard w > 0, h > 0 else { return p }
        var probe = [UInt8](repeating: 0, count: 4)
        canvas.crop(u.x0, u.y0, u.x0 + 1, u.y0 + 1, into: &probe, outWidth: 1, at: 0, 0)
        let fill: [UInt8] = probe[3] > 0 ? probe : [255, 255, 255, 255]
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for i in stride(from: 0, to: out.count, by: 4) { out[i] = fill[0]; out[i + 1] = fill[1]; out[i + 2] = fill[2]; out[i + 3] = 255 }
        canvas.crop(u.x0, u.y0, u.x1, u.y1, into: &out, outWidth: w, at: 0, 0)
        return PixelFrame(width: w, height: h, rgba: out)
    }
}
