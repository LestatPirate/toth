// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import Foundation

/// Página sintética (determinística) para testar a captura por rolagem sem tocar no ecrã real.
/// Desenha "linhas de texto" de blocos aleatórios, caixas de cor e ruído, de forma a não haver zonas repetidas.
public struct ScrollTestPage: Sendable {
    public let width: Int
    public let height: Int
    public var rgba: [UInt8]

    public init(width: Int, height: Int, seed: UInt64 = 7) {
        self.width = width; self.height = height
        rgba = [UInt8](repeating: 245, count: width * height * 4)
        var rng = seed &* 6364136223846793005 &+ 1442695040888963407
        func next() -> Int { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Int(rng >> 33) }
        func fill(_ x0: Int, _ y0: Int, _ w: Int, _ h: Int, _ r: Int, _ g: Int, _ b: Int) {
            for y in max(0, y0)..<min(height, y0 + h) {
                for x in max(0, x0)..<min(width, x0 + w) {
                    let i = (y * width + x) * 4
                    rgba[i] = UInt8(r); rgba[i + 1] = UInt8(g); rgba[i + 2] = UInt8(b); rgba[i + 3] = 255
                }
            }
        }
        var y = 8
        while y < height - 20 {
            switch next() % 5 {
            case 0:   // caixa colorida
                let h = 30 + next() % 60
                fill(10 + next() % 40, y, 80 + next() % max(1, width - 160), h, 40 + next() % 200, 40 + next() % 200, 40 + next() % 200)
                y += h + 10
            default:  // linha de "texto": blocos de largura variável
                var x = 12
                let lineH = 10 + next() % 6
                while x < width - 30 {
                    let w = 6 + next() % 40
                    let g = 20 + next() % 120
                    fill(x, y, w, lineH, g, g, g + next() % 40)
                    x += w + 4 + next() % 10
                }
                y += lineH + 8 + next() % 10
            }
        }
    }

    /// Uma janela de `w × h` sobre a página, com o conteúdo desviado `(ox, oy)` e faixas fixas:
    /// cabeçalho, rodapé (cada um de cor/ruído próprios) e barra lateral esquerda.
    public func window(ox: Int, oy: Int, width w: Int, height h: Int, header: Int = 0, footer: Int = 0, sidebar: Int = 0) -> PixelFrame {
        var out = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                var r: UInt8 = 255, g: UInt8 = 255, b: UInt8 = 255
                if y < header {
                    r = UInt8(30 + (x * 7 + y * 13) % 90); g = 60; b = UInt8(120 + (x * 3) % 100)
                } else if y >= h - footer {
                    r = UInt8(90 + (x * 5 + y * 11) % 100); g = UInt8(40 + (x * 9) % 60); b = 80
                } else if x < sidebar {
                    r = UInt8(200 - (y * 3 + x) % 60); g = UInt8(210 - (x * 5) % 40); b = 230
                } else {
                    let px = x + ox, py = y - header + oy
                    if px >= 0, px < width, py >= 0, py < height {
                        let s = (py * width + px) * 4
                        r = rgba[s]; g = rgba[s + 1]; b = rgba[s + 2]
                    }
                }
                out[i] = r; out[i + 1] = g; out[i + 2] = b; out[i + 3] = 255
            }
        }
        return PixelFrame(width: w, height: h, rgba: out)
    }
}
