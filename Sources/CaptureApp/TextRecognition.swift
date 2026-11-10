// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit
import Vision
import CaptureCore

/// Uma linha de texto reconhecida na imagem (ferramenta «Texto da imagem»).
struct TextBlock: Identifiable, Equatable {
    let id: UUID
    /// O texto lido.
    var text: String
    /// Caixa das letras, em coordenadas do documento (y para baixo).
    var rect: Rect
    var confidence: Double
    /// Largura (documento) e número de letras de cada palavra, para distinguir letra monoespaçada.
    var words: [(width: Double, chars: Int)]

    static func == (a: TextBlock, b: TextBlock) -> Bool { a.id == b.id && a.text == b.text && a.rect == b.rect }
}

/// O estilo que se adivinha do texto na imagem, para a caixa de texto editável ficar parecida.
struct GuessedTextStyle: Equatable {
    var fontSize: Double
    var colorHex: String
    var bold: Bool
    var serif: Bool
    var monospaced: Bool
    /// Nome da fonte do sistema mais parecida (`nil` = fonte do sistema, sem serifa).
    var fontName: String? {
        if monospaced { return ["Menlo", "Courier New"].first { NSFont(name: $0, size: 12) != nil } }
        if serif { return ["Times New Roman", "Georgia", "Times"].first { NSFont(name: $0, size: 12) != nil } }
        return nil
    }
}

/// Reconhecimento de texto com o Vision do macOS: local, sem rede. Português e inglês.
enum TextRecognizer {
    /// Reconhece as linhas de texto de `image`. `origin`: onde o canto superior esquerdo da imagem está no documento.
    nonisolated static func recognize(_ image: CGImage, origin: Point) throws -> [TextBlock] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["pt-PT", "en-US"]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let w = Double(image.width), h = Double(image.height)
        func toDoc(_ b: CGRect) -> Rect {   // Vision: normalizado, origem em baixo à esquerda
            Rect(x: origin.x + b.minX * w, y: origin.y + (1 - b.maxY) * h, width: b.width * w, height: b.height * h)
        }
        var out: [TextBlock] = []
        for o in request.results ?? [] {
            guard let best = o.topCandidates(1).first, !best.string.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            // (o Vision dá caixas por palavra, não por letra)
            var words: [(width: Double, chars: Int)] = []
            let s = best.string
            var i = s.startIndex
            while i < s.endIndex {
                if s[i].isWhitespace { i = s.index(after: i); continue }
                var j = i
                while j < s.endIndex, !s[j].isWhitespace { j = s.index(after: j) }
                if let box = try? best.boundingBox(for: i..<j) { words.append((toDoc(box.boundingBox).width, s.distance(from: i, to: j))) }
                i = j
            }
            out.append(TextBlock(id: UUID(), text: s, rect: toDoc(o.boundingBox), confidence: Double(best.confidence), words: words))
        }
        // ordem de leitura: de cima para baixo, da esquerda para a direita
        return out.sorted { a, b in
            let ay = a.rect.minY + a.rect.height / 2, by = b.rect.minY + b.rect.height / 2
            let sameLine = abs(ay - by) <= min(a.rect.height, b.rect.height) * 0.6
            return sameLine ? a.rect.minX < b.rect.minX : ay < by
        }
    }

    // MARK: Estilo

    /// Adivinha tamanho, cor, peso, serifa e monoespaçamento a partir dos píxeis do bloco.
    /// `pixels`: RGBA da imagem renderizada (`width × height`), com o canto superior esquerdo em `origin` (documento).
    nonisolated static func guessStyle(for block: TextBlock, pixels: [UInt8], width: Int, height: Int, origin: Point) -> GuessedTextStyle {
        let r = block.rect
        let x0 = max(0, Int((r.minX - origin.x).rounded(.down))), y0 = max(0, Int((r.minY - origin.y).rounded(.down)))
        let x1 = min(width, Int((r.maxX - origin.x).rounded(.up))), y1 = min(height, Int((r.maxY - origin.y).rounded(.up)))
        let bw = x1 - x0, bh = y1 - y0
        var color = "#000000", bold = false, serif = false, mono = false
        if bw > 2, bh > 2 {
            func px(_ x: Int, _ y: Int) -> (Int, Int, Int) { let o = (y * width + x) * 4; return (Int(pixels[o]), Int(pixels[o + 1]), Int(pixels[o + 2])) }
            // fundo: a cor mais comum na moldura à volta (1 px fora do bloco, ou a borda do bloco)
            var hist: [Int: (Int, (Int, Int, Int))] = [:]
            let fx0 = max(0, x0 - 1), fy0 = max(0, y0 - 1), fx1 = min(width - 1, x1), fy1 = min(height - 1, y1)
            for x in fx0...fx1 { for y in [fy0, fy1] { let c = px(x, y); let k = (c.0 >> 4) << 8 | (c.1 >> 4) << 4 | (c.2 >> 4); hist[k, default: (0, c)].0 += 1 } }
            for y in fy0...fy1 { for x in [fx0, fx1] { let c = px(x, y); let k = (c.0 >> 4) << 8 | (c.1 >> 4) << 4 | (c.2 >> 4); hist[k, default: (0, c)].0 += 1 } }
            let bg = hist.values.max { $0.0 < $1.0 }?.1 ?? (255, 255, 255)
            func dist(_ c: (Int, Int, Int)) -> Int { max(abs(c.0 - bg.0), abs(c.1 - bg.1), abs(c.2 - bg.2)) }
            // tinta: o que mais se afasta do fundo
            var maxD = 0
            for y in y0..<y1 { for x in x0..<x1 { maxD = max(maxD, dist(px(x, y))) } }
            let inkT = max(40, maxD * 55 / 100), coreT = max(60, maxD * 80 / 100)
            var ink = [Bool](repeating: false, count: bw * bh)
            var sr = 0, sg = 0, sb = 0, n = 0
            for y in y0..<y1 { for x in x0..<x1 {
                let c = px(x, y), d = dist(c)
                if d >= inkT { ink[(y - y0) * bw + (x - x0)] = true }
                if d >= coreT { sr += c.0; sg += c.1; sb += c.2; n += 1 }
            } }
            if n > 0 { color = String(format: "#%02X%02X%02X", sr / n, sg / n, sb / n) }
            // traço: mediana dos comprimentos das sequências horizontais de tinta
            var runs: [Int] = []
            for y in 0..<bh { var run = 0; for x in 0..<bw { if ink[y * bw + x] { run += 1 } else if run > 0 { runs.append(run); run = 0 } }; if run > 0 { runs.append(run) } }
            runs.sort()
            let stroke = runs.isEmpty ? 0.0 : Double(runs[runs.count / 2])
            // altura das maiúsculas ≈ altura do bloco sem os descendentes
            let hasDesc = block.text.contains { "gjpqyçQ,;".contains($0) }
            let capH = Double(bh) * (hasDesc ? 0.75 : 1.0)
            bold = capH > 0 && stroke / capH > 0.155
            // serifa: a fila da base tem muito mais tinta do que as filas do meio (os «pés» das letras)
            var rowInk = [Int](repeating: 0, count: bh)
            for y in 0..<bh { for x in 0..<bw where ink[y * bw + x] { rowInk[y] += 1 } }
            let baseEnd = hasDesc ? Int(Double(bh) * 0.78) : bh
            let baseStart = max(0, baseEnd - max(2, bh / 6))
            if baseEnd > baseStart, bh >= 10 {
                let base = rowInk[baseStart..<baseEnd].max() ?? 0
                let mid = Array(rowInk[(bh / 3)..<max(bh / 3 + 1, baseStart)]).sorted()
                let midMedian = mid.isEmpty ? 0 : mid[mid.count / 2]
                serif = midMedian > 0 && Double(base) / Double(midMedian) > 1.9 && !bold
            }
            // monoespaçada: os centros das letras (sequências de colunas com tinta) caem numa grelha de avanço fixo
            var centers: [Double] = []
            var start = -1
            for x in 0...bw {
                var any = false
                if x < bw { for y in 0..<bh where ink[y * bw + x] { any = true; break } }
                if any && start < 0 { start = x }
                if !any && start >= 0 { centers.append(Double(start + x - 1) / 2); start = -1 }
            }
            if centers.count >= 6 {
                let diffs = zip(centers.dropFirst(), centers).map { $0 - $1 }.sorted()
                let med = diffs[diffs.count / 2]
                let single = diffs.filter { $0 > med * 0.7 && $0 < med * 1.3 }
                let advance = single.reduce(0, +) / Double(max(1, single.count))
                if advance >= 4 {
                    let onGrid = centers.filter { let k = ($0 - centers[0]) / advance; return abs(k - k.rounded()) <= 0.2 }.count
                    mono = Double(onGrid) / Double(centers.count) >= 0.9
                }
            }
        }
        var guess = GuessedTextStyle(fontSize: 20, colorHex: color, bold: bold, serif: serif, monospaced: mono)
        guess.fontSize = fontSize(for: block, guess: guess)
        return guess
    }

    /// Tamanho da letra: pela largura (o texto escrito com a fonte adivinhada deve ocupar a largura do bloco) e pela
    /// altura (altura das maiúsculas, mais os descendentes se os houver), com a largura a mandar mais.
    nonisolated static func fontSize(for block: TextBlock, guess: GuessedTextStyle) -> Double {
        var fmt = TextFormat(); fmt.fontName = guess.fontName; fmt.bold = guess.bold
        let f100 = RichText.font(fmt, size: 100)
        let w100 = (block.text as NSString).size(withAttributes: [.font: f100]).width
        let byWidth = w100 > 0 ? block.rect.width / Double(w100) * 100 : 20
        let hasDesc = block.text.contains { "gjpqyçQ,;".contains($0) }
        let hasTall = block.text.contains { $0.isUppercase || $0.isNumber || "bdfhklt".contains($0) }
        let top = Double(hasTall ? f100.capHeight : f100.xHeight) / 100, bottom = hasDesc ? Double(-f100.descender) / 100 * 0.8 : 0
        let byHeight = (top + bottom) > 0 ? block.rect.height / (top + bottom) : byWidth
        // as caixas do Vision têm uma pequena margem à volta das letras (~10 %): descontada aqui
        let size = (byWidth * 0.65 + byHeight * 0.35) * 0.88
        return max(6, min(400, (size * 2).rounded() / 2))
    }
}
