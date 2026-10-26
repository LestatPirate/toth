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

/// As linhas de uma gravação: o vídeo, o áudio do sistema e o microfone. (Um vídeo antigo, com um só áudio, só tem
/// `video` e `system`, que aí é o «Áudio».)
public enum EditTrack: String, Codable, CaseIterable, Sendable { case video, system, microphone }

/// Um trecho de uma média (o vídeo original, ou um ficheiro gerado, por exemplo invertido) posto na linha de tempo.
public struct Clip: Codable, Equatable, Sendable {
    /// 0 = o ficheiro original; os outros são ficheiros gerados (trechos invertidos).
    public var media: Int
    public var src: TimeSpan          // que parte da média
    public var at: Double             // onde começa na linha de tempo
    public init(media: Int, src: TimeSpan, at: Double) { self.media = media; self.src = src; self.at = at }
    public var length: Double { src.length }
    public var end: Double { at + length }
}

/// Trecho copiado: o que havia em cada linha num intervalo (com as posições relativas ao início) e o comprimento total,
/// espaços incluídos.
public struct EditPiece: Equatable, Sendable {
    public var length: Double
    public var lanes: [EditTrack: [Clip]]
    public init(length: Double, lanes: [EditTrack: [Clip]]) { self.length = length; self.lanes = lanes }
    public var isEmpty: Bool { lanes.values.allSatisfy(\.isEmpty) }
}

/// A edição de um vídeo: para cada linha, os clipes (ordenados, sem sobreposição) e os espaços entre eles.
/// Cortar pode **juntar** (o que vem depois recua e toca seguido) ou **deixar espaço** (o resto fica onde está; no vídeo o
/// espaço é preto, no áudio é silêncio). Cada operação aplica-se às linhas escolhidas: cortar só o áudio deixa o vídeo a
/// correr (espaço «com vídeo»); cortar o vídeo também deixa um espaço «sem vídeo». Só Foundation: testa-se sem vídeo.
public struct EditTimeline: Codable, Equatable, Sendable {
    public struct Lane: Codable, Equatable, Sendable { public var track: EditTrack; public var clips: [Clip] }

    public let sourceDuration: Double
    public private(set) var lanes: [Lane]

    public static let minCut = 0.05
    public static let minKept = 0.1

    /// Cada linha começa com um só clipe: o original inteiro, em `0`.
    public init(sourceDuration: Double, tracks: [EditTrack]) {
        self.sourceDuration = max(0, sourceDuration)
        lanes = tracks.map { Lane(track: $0, clips: [Clip(media: 0, src: TimeSpan(start: 0, end: max(0, sourceDuration)), at: 0)]) }
    }

    public var tracks: [EditTrack] { lanes.map(\.track) }
    public func clips(_ t: EditTrack) -> [Clip] { lanes.first { $0.track == t }?.clips ?? [] }

    /// Comprimento da linha de tempo: onde acaba o último clipe de qualquer linha.
    public var duration: Double { lanes.flatMap(\.clips).map(\.end).max() ?? 0 }

    /// Alguma linha foi editada (já não é um só clipe original inteiro em 0)?
    public var isEdited: Bool {
        lanes.contains { l in !(l.clips.count == 1 && l.clips[0].media == 0 && l.clips[0].at == 0 && abs(l.clips[0].src.start) < 1e-9 && abs(l.clips[0].src.end - sourceDuration) < 1e-6) }
    }

    private func laneIndex(_ t: EditTrack) -> Int? { lanes.firstIndex { $0.track == t } }

    // MARK: Consultas

    /// O clipe da linha `t` que cobre o instante `time`, se houver.
    public func clip(at time: Double, in t: EditTrack) -> Clip? { clips(t).first { time >= $0.at - 1e-9 && time < $0.end - 1e-9 } }

    /// Os espaços (sem clipe) de uma linha, dentro de `0…duration`.
    public func gaps(_ t: EditTrack) -> [TimeSpan] {
        var out: [TimeSpan] = []
        var cursor = 0.0
        for c in clips(t) { if c.at > cursor + 1e-9 { out.append(TimeSpan(start: cursor, end: c.at)) }; cursor = max(cursor, c.end) }
        if duration > cursor + 1e-9 { out.append(TimeSpan(start: cursor, end: duration)) }
        return out
    }

    /// Quanto conteúdo (soma dos clipes) tem a linha.
    public func contentLength(_ t: EditTrack) -> Double { clips(t).reduce(0) { $0 + $1.length } }

    // MARK: Cortar

    /// Retira o intervalo `range` das linhas `tracks`. Com `ripple`, o que vem depois recua (junta-se); sem, fica um espaço.
    /// Devolve `false` se o corte for curto demais, ficar fora, ou deixasse tudo vazio.
    @discardableResult
    public mutating func remove(_ range: TimeSpan, tracks: Set<EditTrack>, ripple: Bool) -> Bool {
        let s = max(0, min(range.start, range.end)), e = min(duration, max(range.start, range.end))
        guard e - s >= Self.minCut else { return false }
        var next = lanes
        for i in next.indices where tracks.contains(next[i].track) {
            next[i].clips = Self.removing(s, e, from: next[i].clips, ripple: ripple)
        }
        let trial = EditTimeline(raw: sourceDuration, lanes: next)
        guard trial.lanes.contains(where: { $0.clips.reduce(0) { $0 + $1.length } >= Self.minKept }) else { return false }
        lanes = next
        return true
    }

    private init(raw sourceDuration: Double, lanes: [Lane]) { self.sourceDuration = sourceDuration; self.lanes = lanes }

    private static func removing(_ s: Double, _ e: Double, from clips: [Clip], ripple: Bool) -> [Clip] {
        let len = e - s
        var out: [Clip] = []
        for c in clips {
            if c.end <= s + 1e-9 { out.append(c); continue }
            if c.at >= e - 1e-9 { var m = c; if ripple { m.at -= len }; out.append(m); continue }
            if c.at < s - 1e-9 {                                   // parte da esquerda
                out.append(Clip(media: c.media, src: TimeSpan(start: c.src.start, end: c.src.start + (s - c.at)), at: c.at))
            }
            if c.end > e + 1e-9 {                                  // parte da direita
                out.append(Clip(media: c.media, src: TimeSpan(start: c.src.start + (e - c.at), end: c.src.end), at: ripple ? s : e))
            }
        }
        return out.sorted { $0.at < $1.at }
    }

    // MARK: Copiar e colar

    /// O que há em `range` nas linhas `tracks`, com posições relativas ao início do intervalo.
    public func extract(_ range: TimeSpan, tracks: Set<EditTrack>) -> EditPiece {
        let s = max(0, min(range.start, range.end)), e = min(duration, max(range.start, range.end))
        var lanes: [EditTrack: [Clip]] = [:]
        for l in self.lanes where tracks.contains(l.track) {
            var out: [Clip] = []
            for c in l.clips where c.end > s + 1e-9 && c.at < e - 1e-9 {
                let a = max(c.at, s), b = min(c.end, e)
                out.append(Clip(media: c.media, src: TimeSpan(start: c.src.start + (a - c.at), end: c.src.start + (b - c.at)), at: a - s))
            }
            lanes[l.track] = out
        }
        return EditPiece(length: max(0, e - s), lanes: lanes)
    }

    /// Cola `piece` no instante `t` (nas linhas que ele traz). Com `ripple`, o que está a partir de `t` avança para dar lugar
    /// (um clipe cortado ao meio é dividido); sem, o trecho substitui o que lá estiver.
    public mutating func insert(_ piece: EditPiece, at t: Double, ripple: Bool) {
        let t = ripple ? max(0, min(t, duration)) : max(0, t)          // por cima pode passar do fim (a linha de tempo cresce)
        for i in lanes.indices {
            guard let new = piece.lanes[lanes[i].track] else { continue }
            var clips = lanes[i].clips
            if ripple {
                var out: [Clip] = []
                for c in clips {
                    if c.end <= t + 1e-9 { out.append(c) }
                    else if c.at >= t - 1e-9 { var m = c; m.at += piece.length; out.append(m) }
                    else {                                           // divide em t
                        out.append(Clip(media: c.media, src: TimeSpan(start: c.src.start, end: c.src.start + (t - c.at)), at: c.at))
                        out.append(Clip(media: c.media, src: TimeSpan(start: c.src.start + (t - c.at), end: c.src.end), at: t + piece.length))
                    }
                }
                clips = out
            } else {
                clips = Self.removing(t, t + piece.length, from: clips, ripple: false)
            }
            clips += new.map { Clip(media: $0.media, src: $0.src, at: $0.at + t) }
            lanes[i].clips = clips.sorted { $0.at < $1.at }
        }
    }

    // MARK: Mover

    /// Muda de sítio o conteúdo de `range` (nas linhas `tracks`) para que comece em `newStart`.
    /// Sem `ripple` (levantar e pousar): onde estava fica um espaço e no destino substitui o que lá estiver.
    /// Com `ripple` (inserir): onde estava fecha-se e no destino o resto avança para lhe dar lugar; `newStart` conta-se na
    /// linha de tempo de antes (se for depois do fim do trecho, o ponto recua o comprimento dele, porque o espaço fechou).
    /// Devolve o novo início, ou `nil` se não houve nada a mover.
    @discardableResult
    public mutating func move(_ range: TimeSpan, tracks: Set<EditTrack>, to newStart: Double, ripple: Bool) -> Double? {
        let s = max(0, min(range.start, range.end)), e = min(duration, max(range.start, range.end))
        guard e - s >= Self.minCut else { return nil }
        let target = max(0, newStart)
        if abs(target - s) < 1e-6 { return s }
        let piece = extract(TimeSpan(start: s, end: e), tracks: tracks)
        guard !piece.isEmpty else { return nil }
        guard remove(TimeSpan(start: s, end: e), tracks: tracks, ripple: ripple) else { return nil }
        let at = ripple ? (target > e ? target - (e - s) : target) : target
        insert(piece, at: at, ripple: ripple)
        return at
    }

    // MARK: Inverter

    /// Posição de cada clipe depois de inverter um intervalo de comprimento `length`: o que estava no fim passa ao início.
    public static func mirroredAt(_ clip: Clip, length: Double) -> Double { length - (clip.at + clip.length) }

    /// Põe `pieces` (já invertidos, com posições relativas) no intervalo `range`, em vez do que lá estava.
    public mutating func replace(_ range: TimeSpan, tracks: Set<EditTrack>, with pieces: [EditTrack: [Clip]]) {
        let s = max(0, min(range.start, range.end)), e = min(duration, max(range.start, range.end))
        for i in lanes.indices where tracks.contains(lanes[i].track) {
            var clips = Self.removing(s, e, from: lanes[i].clips, ripple: false)
            clips += (pieces[lanes[i].track] ?? []).map { Clip(media: $0.media, src: $0.src, at: $0.at + s) }
            lanes[i].clips = clips.sorted { $0.at < $1.at }
        }
    }

    /// As linhas ficam todas com o mesmo comprimento? (Informação para a interface.)
    public var isBalanced: Bool { let d = duration; return lanes.allSatisfy { ($0.clips.map(\.end).max() ?? 0) >= d - 1e-6 } }
}
