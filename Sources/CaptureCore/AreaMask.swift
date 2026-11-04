// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import Foundation

/// Uma seleção de área: um retângulo do documento e, dentro dele, a cobertura de cada píxel (0…255). Retângulo e elipse
/// são máscaras cheias/arredondadas; a varinha dá a máscara dos píxeis parecidos. Só Foundation: testa-se sem imagens.
public struct AreaMask: Equatable, Sendable {
    public var x: Int, y: Int, width: Int, height: Int
    /// `width × height` valores (0 = fora, 255 = dentro), por filas, de cima para baixo.
    public var alpha: [UInt8]

    public init(x: Int, y: Int, width: Int, height: Int, alpha: [UInt8]) {
        self.x = x; self.y = y; self.width = width; self.height = height; self.alpha = alpha
    }
    public var rect: Rect { Rect(x: Double(x), y: Double(y), width: Double(width), height: Double(height)) }
    public var isEmpty: Bool { width <= 0 || height <= 0 || !alpha.contains { $0 > 0 } }
    public func value(atX px: Int, y py: Int) -> UInt8 {
        let i = px - x, j = py - y
        guard i >= 0, j >= 0, i < width, j < height else { return 0 }
        return alpha[j * width + i]
    }
    public func contains(_ p: Point) -> Bool { value(atX: Int(p.x.rounded(.down)), y: Int(p.y.rounded(.down))) > 127 }
    /// Quantos píxeis estão dentro (mais de metade cobertos).
    public var count: Int { alpha.reduce(0) { $0 + ($1 > 127 ? 1 : 0) } }

    // MARK: Formas

    /// Retângulo (píxeis inteiros, arredondado para fora).
    public static func rect(_ r: Rect) -> AreaMask {
        let x0 = Int(r.minX.rounded(.down)), y0 = Int(r.minY.rounded(.down)), x1 = Int(r.maxX.rounded(.up)), y1 = Int(r.maxY.rounded(.up))
        let w = max(0, x1 - x0), h = max(0, y1 - y0)
        return AreaMask(x: x0, y: y0, width: w, height: h, alpha: [UInt8](repeating: 255, count: w * h))
    }

    /// Elipse inscrita em `r`, com a borda suavizada (cobertura aproximada por 4×4 amostras por píxel).
    public static func ellipse(_ r: Rect) -> AreaMask {
        var m = rect(r)
        guard m.width > 0, m.height > 0 else { return m }
        let cx = r.minX + r.width / 2, cy = r.minY + r.height / 2, a = max(0.5, r.width / 2), b = max(0.5, r.height / 2)
        for j in 0..<m.height { for i in 0..<m.width {
            var inside = 0
            for sy in 0..<4 { for sx in 0..<4 {
                let px = Double(m.x + i) + (Double(sx) + 0.5) / 4, py = Double(m.y + j) + (Double(sy) + 0.5) / 4
                let dx = (px - cx) / a, dy = (py - cy) / b
                if dx * dx + dy * dy <= 1 { inside += 1 }
            } }
            m.alpha[j * m.width + i] = UInt8(inside * 255 / 16)
        } }
        return m
    }

    /// Varinha: os píxeis de cor parecida com a do ponto (`tolerance` 0…255 na maior diferença entre canais), contíguos
    /// (4 vizinhos) ou em toda a imagem. `pixels`: RGBA intercalado de `width × height`, origem no canto superior esquerdo.
    public static func wand(pixels: [UInt8], width: Int, height: Int, at p: Point, tolerance: Int, contiguous: Bool) -> AreaMask? {
        let sx = Int(p.x.rounded(.down)), sy = Int(p.y.rounded(.down))
        guard sx >= 0, sy >= 0, sx < width, sy < height, pixels.count >= width * height * 4 else { return nil }
        let o = (sy * width + sx) * 4
        let r0 = Int(pixels[o]), g0 = Int(pixels[o + 1]), b0 = Int(pixels[o + 2]), a0 = Int(pixels[o + 3])
        let tol = max(0, min(255, tolerance))
        func similar(_ i: Int) -> Bool {
            let q = i * 4
            return abs(Int(pixels[q]) - r0) <= tol && abs(Int(pixels[q + 1]) - g0) <= tol && abs(Int(pixels[q + 2]) - b0) <= tol && abs(Int(pixels[q + 3]) - a0) <= tol
        }
        var hit = [Bool](repeating: false, count: width * height)
        if contiguous {
            var stack = [sy * width + sx]
            hit[sy * width + sx] = true
            while let i = stack.popLast() {
                let x = i % width, y = i / width
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < width && ny < height {
                    let n = ny * width + nx
                    if !hit[n] && similar(n) { hit[n] = true; stack.append(n) }
                }
            }
        } else {
            for i in 0..<(width * height) where similar(i) { hit[i] = true }
        }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for i in 0..<(width * height) where hit[i] { let x = i % width, y = i / width; minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
        guard maxX >= minX, maxY >= minY else { return nil }
        let w = maxX - minX + 1, h = maxY - minY + 1
        var alpha = [UInt8](repeating: 0, count: w * h)
        for y in minY...maxY { for x in minX...maxX where hit[y * width + x] { alpha[(y - minY) * w + (x - minX)] = 255 } }
        return AreaMask(x: minX, y: minY, width: w, height: h, alpha: alpha)
    }

    // MARK: Combinar (⇧ junta, ⌥ tira)

    public enum Combine: Sendable { case replace, add, subtract }

    public func combined(with other: AreaMask, _ op: Combine) -> AreaMask {
        switch op {
        case .replace: return other
        case .add:
            let x0 = min(x, other.x), y0 = min(y, other.y), x1 = max(x + width, other.x + other.width), y1 = max(y + height, other.y + other.height)
            var out = AreaMask(x: x0, y: y0, width: x1 - x0, height: y1 - y0, alpha: [UInt8](repeating: 0, count: (x1 - x0) * (y1 - y0)))
            for j in 0..<out.height { for i in 0..<out.width {
                out.alpha[j * out.width + i] = max(value(atX: x0 + i, y: y0 + j), other.value(atX: x0 + i, y: y0 + j))
            } }
            return out
        case .subtract:
            var out = self
            for j in 0..<height { for i in 0..<width {
                let v = Int(alpha[j * width + i]) - Int(other.value(atX: x + i, y: y + j))
                out.alpha[j * width + i] = UInt8(max(0, v))
            } }
            return out.trimmed()
        }
    }

    /// Tira as filas e colunas vazias à volta.
    public func trimmed() -> AreaMask {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for j in 0..<height { for i in 0..<width where alpha[j * width + i] > 0 { minX = min(minX, i); maxX = max(maxX, i); minY = min(minY, j); maxY = max(maxY, j) } }
        guard maxX >= minX, maxY >= minY else { return AreaMask(x: x, y: y, width: 0, height: 0, alpha: []) }
        let w = maxX - minX + 1, h = maxY - minY + 1
        var out = [UInt8](repeating: 0, count: w * h)
        for j in 0..<h { for i in 0..<w { out[j * w + i] = alpha[(j + minY) * width + (i + minX)] } }
        return AreaMask(x: x + minX, y: y + minY, width: w, height: h, alpha: out)
    }

    /// `true` se a máscara é um retângulo cheio (não precisa de ficheiro de máscara).
    public var isFullRect: Bool { !alpha.contains { $0 != 255 } }
}
