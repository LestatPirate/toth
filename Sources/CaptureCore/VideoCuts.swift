// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import Foundation

/// Intervalo de tempo em segundos.
public struct TimeSpan: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = end }
    public var length: Double { end - start }
    public func contains(_ t: Double) -> Bool { t >= start && t < end }
}

/// Os trechos que o utilizador retirou de um vídeo (edição não destrutiva: o ficheiro original não muda).
/// O que sobra toca seguido, sem pausa. Os cortes ficam ordenados, sem sobreposição e sem trechos colados
/// (dois cortes que se tocam fundem-se). Só Foundation: testa-se sem vídeo.
public struct VideoCuts: Codable, Equatable, Sendable {
    public let duration: Double
    public private(set) var cuts: [TimeSpan]

    /// Cortes mais curtos do que isto não valem a pena (menos de um fotograma).
    public static let minCut = 0.05
    /// Tem de sobrar sempre pelo menos isto do vídeo.
    public static let minKept = 0.1

    public init(duration: Double, cuts: [TimeSpan] = []) {
        self.duration = max(0, duration)
        self.cuts = []
        for c in cuts { _ = cut(c) }
    }

    /// Retira o trecho `span` (limitado ao vídeo). Devolve `false` se for demasiado curto, ficar fora do vídeo,
    /// ou se deixasse o vídeo sem nada.
    @discardableResult
    public mutating func cut(_ span: TimeSpan) -> Bool {
        let s = max(0, min(span.start, span.end)), e = min(duration, max(span.start, span.end))
        guard e - s >= Self.minCut else { return false }
        var merged = TimeSpan(start: s, end: e)
        var rest: [TimeSpan] = []
        for c in cuts {
            if c.end < merged.start - 1e-9 || c.start > merged.end + 1e-9 { rest.append(c) }
            else { merged = TimeSpan(start: min(c.start, merged.start), end: max(c.end, merged.end)) }
        }
        rest.append(merged)
        rest.sort { $0.start < $1.start }
        let removed = rest.reduce(0) { $0 + $1.length }
        guard duration - removed >= Self.minKept else { return false }
        cuts = rest
        return true
    }

    /// Volta a pôr o corte número `index`.
    public mutating func restore(at index: Int) { if cuts.indices.contains(index) { cuts.remove(at: index) } }
    public mutating func restoreAll() { cuts = [] }

    public var hasCuts: Bool { !cuts.isEmpty }

    /// Os trechos que ficam, por ordem.
    public var kept: [TimeSpan] {
        var out: [TimeSpan] = []
        var t = 0.0
        for c in cuts { if c.start > t + 1e-9 { out.append(TimeSpan(start: t, end: c.start)) }; t = c.end }
        if duration > t + 1e-9 { out.append(TimeSpan(start: t, end: duration)) }
        return out
    }

    public var keptDuration: Double { kept.reduce(0) { $0 + $1.length } }

    /// O instante `t` (do vídeo original) está num trecho retirado?
    public func isCut(_ t: Double) -> Bool { cuts.contains { $0.contains(t) } }

    /// Tempo no vídeo editado (sem os cortes) que corresponde ao instante `t` do original.
    /// Dentro de um corte devolve o ponto onde o corte esteve.
    public func editedTime(forSource t: Double) -> Double {
        var removed = 0.0
        for c in cuts {
            if t >= c.end { removed += c.length }
            else if t > c.start { return c.start - removed }
            else { break }
        }
        return max(0, min(t - removed, keptDuration))
    }

    /// Instante do vídeo original que corresponde ao tempo `e` do vídeo editado.
    public func sourceTime(forEdited e: Double) -> Double {
        var t = max(0, e)
        for c in cuts { if t >= c.start - 1e-9 { t += c.length } else { break } }
        return min(t, duration)
    }

    /// Se `t` cai num corte, o fim desse corte (onde a reprodução continua); senão o próprio `t`.
    public func skipCut(_ t: Double) -> Double { cuts.first { $0.contains(t) }?.end ?? t }

    /// O corte (índice) que contém `t`, se houver.
    public func cutIndex(at t: Double) -> Int? { cuts.firstIndex { $0.contains(t) } }
}
