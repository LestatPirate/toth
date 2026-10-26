// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import Foundation

/// De onde vem o áudio de uma gravação de vídeo.
public enum AudioSource: CaseIterable, Sendable { case system, microphone }

/// Mistura o áudio do sistema e do microfone numa só faixa estéreo a 48 kHz, em blocos de tempo fixo.
///
/// Cada fonte entrega amostras com a sua posição na linha do tempo da gravação (em frames de 48 kHz, já sem as pausas);
/// o misturador alinha-as por essa posição, por isso uma fonte que chega atrasada ou com falhas não desalinha a outra.
/// Qualquer fonte pode ser ligada ou desligada em qualquer momento: uma fonte desligada não conta (nem se espera por ela).
/// Só Foundation, sem dependências do sistema: testa-se sem áudio real.
public struct AudioMixer {
    public static let sampleRate = 48_000
    public static let channels = 2

    public let chunkFrames: Int
    /// Quanto uma fonte ligada pode atrasar-se antes de se emitir o bloco sem ela (em frames).
    public let maxLatencyFrames: Int

    private struct Track {
        var enabled: Bool
        var start: Int64 = 0          // posição (em frames) da 1.ª amostra de `data`
        var data: [Float] = []        // estéreo intercalado
        var filledUntil: Int64 = 0    // fim (exclusivo, em frames) do que já se recebeu
    }
    private var tracks: [AudioSource: Track]
    private var emitted: Int64 = 0    // frames já emitidos
    private var clock: Int64 = 0      // "agora" na linha do tempo (por exemplo, pelo vídeo)

    public init(chunkFrames: Int = 960, maxLatencyFrames: Int = 14_400, system: Bool = true, microphone: Bool = false) {
        self.chunkFrames = chunkFrames
        self.maxLatencyFrames = maxLatencyFrames
        tracks = [.system: Track(enabled: system), .microphone: Track(enabled: microphone)]
    }

    public func isEnabled(_ s: AudioSource) -> Bool { tracks[s]!.enabled }

    /// Liga ou desliga uma fonte. Ao desligar, o que ainda não foi misturado dessa fonte é descartado (fica silêncio);
    /// ao ligar, só entra áudio a partir daí.
    public mutating func setEnabled(_ s: AudioSource, _ on: Bool) {
        var t = tracks[s]!
        guard t.enabled != on else { return }
        t.enabled = on
        t.data = []; t.start = max(emitted, clock); t.filledUntil = t.start
        tracks[s] = t
    }

    /// Recebe amostras estéreo intercaladas, cuja primeira amostra está na posição `startFrame`.
    public mutating func push(_ s: AudioSource, samples: [Float], startFrame: Int64) {
        guard var t = tracks[s], t.enabled, !samples.isEmpty else { return }
        let frames = Int64(samples.count / Self.channels)
        var from = startFrame
        var body = samples[...]
        if from < t.filledUntil {                                   // sobreposição: descarta o que já se tinha
            let skip = Int(min(t.filledUntil - from, frames))
            body = body.dropFirst(skip * Self.channels); from += Int64(skip)
        }
        if body.isEmpty { return }
        if from < emitted {                                         // tarde demais: esse trecho já saiu
            let skip = Int(min(emitted - from, Int64(body.count / Self.channels)))
            body = body.dropFirst(skip * Self.channels); from += Int64(skip)
            if body.isEmpty { t.filledUntil = max(t.filledUntil, from); tracks[s] = t; return }
        }
        if t.data.isEmpty { t.start = from; t.filledUntil = from }
        if from > t.filledUntil {                                   // falha: preenche com silêncio
            t.data.append(contentsOf: [Float](repeating: 0, count: Int(from - t.filledUntil) * Self.channels))
        }
        t.data.append(contentsOf: body)
        t.filledUntil = from + Int64(body.count / Self.channels)
        tracks[s] = t
    }

    /// Diz onde vai a linha do tempo (por exemplo, o instante do último fotograma de vídeo): sem fontes ligadas,
    /// emite-se silêncio até aí.
    public mutating func advance(toFrame f: Int64) { clock = max(clock, f) }

    /// Blocos prontos a escrever. Com `flush`, emite também o que falta até ao fim (gravação terminada).
    public mutating func pop(flush: Bool = false) -> [(frame: Int64, samples: [Float])] {
        var out: [(frame: Int64, samples: [Float])] = []
        while true {
            let end = emitted + Int64(chunkFrames)
            let enabled = tracks.values.filter(\.enabled)
            let newest = max(clock, tracks.values.map(\.filledUntil).max() ?? 0)
            let ready: Bool
            if flush && newest > emitted { ready = true }                                  // fim: esvazia
            else if enabled.isEmpty { ready = clock >= end }                               // nada ligado: silêncio até ao relógio
            else if enabled.allSatisfy({ $0.filledUntil >= end }) { ready = true }         // todas as fontes ligadas já chegaram
            else { ready = newest - end >= Int64(maxLatencyFrames) }                       // uma fonte atrasou-se demais: segue sem ela
            guard ready else { break }
            var chunk = [Float](repeating: 0, count: chunkFrames * Self.channels)
            for (src, t) in tracks where t.enabled && !t.data.isEmpty {
                let off = Int(emitted - t.start)
                for i in 0..<chunk.count {
                    let j = off * Self.channels + i
                    if j >= 0 && j < t.data.count { chunk[i] += t.data[j] }
                }
                _ = src
            }
            for i in 0..<chunk.count { chunk[i] = max(-1, min(1, chunk[i])) }
            out.append((emitted, chunk))
            emitted = end
            for s in AudioSource.allCases {                          // liberta o que já foi usado
                guard var t = tracks[s], !t.data.isEmpty else { continue }
                let drop = Int(min(emitted - t.start, Int64(t.data.count / Self.channels)))
                if drop > 0 { t.data.removeFirst(drop * Self.channels); t.start += Int64(drop) }
                tracks[s] = t
            }
        }
        return out
    }

    /// Frames já emitidos (a posição da linha do tempo até onde o áudio está escrito).
    public var emittedFrames: Int64 { emitted }
}
