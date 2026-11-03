// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AVFoundation
import AppKit
import CaptureCore
import CoreVideo

/// Uma anotação sobre o vídeo, com início e fim (em tempo da linha de tempo). O desenho em si é uma `Annotation` normal
/// do editor de imagem (seta, texto, carimbo, pixelização…), guardada no pacote `anotacoes.capture` da edição.
/// `endOffset`: se existir, a anotação desloca-se em linha reta até esse deslocamento no fim (para seguir uma zona).
struct VideoOverlay: Codable, Equatable {
    var id: UUID
    var start: Double
    var end: Double
    var endOffset: Point?
    func contains(_ t: Double) -> Bool { t >= start - 1e-6 && t < end }
    var length: Double { end - start }
}

/// O que o compositor precisa para desenhar as anotações num instante: o documento (as anotações e as imagens coladas) e os
/// tempos. É partilhado entre a interface (que o atualiza) e o compositor (que o lê noutra fila), por isso tem um trinco.
final class OverlayProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var doc: CaptureDocument?
    private var overlays: [VideoOverlay] = []
    private var assets: AssetStore?

    func update(doc: CaptureDocument?, overlays: [VideoOverlay], assets: AssetStore?) {
        lock.lock(); defer { lock.unlock() }
        self.doc = doc; self.overlays = overlays; self.assets = assets
    }

    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return overlays.isEmpty || doc == nil }

    /// O documento só com as anotações ativas em `t` (já deslocadas, se seguem uma zona), e as imagens coladas.
    func snapshot(at t: Double) -> (CaptureDocument, AssetStore?)? {
        lock.lock(); defer { lock.unlock() }
        guard var d = doc else { return nil }
        let active = Dictionary(uniqueKeysWithValues: overlays.filter { $0.contains(t) }.map { ($0.id, $0) })
        for a in d.annotations {
            guard let o = active[a.id] else { d.remove(id: a.id); continue }
            if let off = o.endOffset, o.length > 1e-6 {
                let k = max(0, min(1, (t - o.start) / o.length))
                var m = a; m.shape = a.shape.translated(dx: off.x * k, dy: off.y * k); d.update(m)
            }
        }
        return d.annotations.isEmpty ? nil : (d, assets)
    }

    /// Desenha as anotações ativas em `t` por cima de `frame` (já com o tamanho da saída), num contexto com o eixo y para baixo.
    func draw(over frame: CGImage, at t: Double, in ctx: CGContext) {
        guard let (d, assets) = snapshot(at: t) else { return }
        var doc = d
        doc.canvasWidth = Double(frame.width); doc.canvasHeight = Double(frame.height)
        doc.workArea = nil; doc.imageFrame = nil
        Renderer.draw(doc, base: frame, in: ctx, assets: assets)
    }
}

/// Instrução de composição que, além das camadas de vídeo (transformadas como o `VideoComposer` as deixou), leva o fornecedor
/// das anotações.
final class OverlayInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening: Bool
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let layers: [AVVideoCompositionLayerInstruction]
    let provider: OverlayProvider

    init(_ base: AVVideoCompositionInstruction, provider: OverlayProvider) {
        timeRange = base.timeRange
        containsTweening = base.containsTweening
        layers = base.layerInstructions
        requiredSourceTrackIDs = base.layerInstructions.map { NSNumber(value: $0.trackID) }
        self.provider = provider
    }
}

/// Compositor próprio: desenha as camadas de vídeo (com as suas transformações) e, por cima, as anotações ativas no instante.
/// Usado na reprodução e ao guardar, por isso o ficheiro final leva as anotações.
final class OverlayCompositor: NSObject, AVVideoCompositing {
    var sourcePixelBufferAttributes: [String: any Sendable]? { [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]] }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]] }
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    enum Failure: Error { case noBuffer }

    func startRequest(_ req: AVAsynchronousVideoCompositionRequest) {
        guard let inst = req.videoCompositionInstruction as? OverlayInstruction, let out = req.renderContext.newPixelBuffer() else { req.finish(with: Failure.noBuffer); return }
        let size = req.renderContext.size
        CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(out, []) }
        guard let base = CVPixelBufferGetBaseAddress(out),
              let ctx = CGContext(data: base, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(out),
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { req.finish(with: Failure.noBuffer); return }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(origin: .zero, size: size))
        // camadas de vídeo: a transformação da composição tem a origem no canto superior esquerdo
        for layer in inst.layers {
            guard let pb = req.sourceFrame(byTrackID: layer.trackID), let img = Self.image(from: pb) else { continue }
            var start = CGAffineTransform.identity, end = CGAffineTransform.identity, range = CMTimeRange()
            if !layer.getTransformRamp(for: req.compositionTime, start: &start, end: &end, timeRange: &range) { start = .identity }
            ctx.saveGState()
            ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1)   // eixo y para baixo
            ctx.concatenate(start)
            ctx.translateBy(x: 0, y: CGFloat(img.height)); ctx.scaleBy(x: 1, y: -1)   // a imagem desenha-se direita
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            ctx.restoreGState()
        }
        if !inst.provider.isEmpty, let frame = ctx.makeImage() {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1)
            inst.provider.draw(over: frame, at: req.compositionTime.seconds, in: ctx)
            ctx.restoreGState()
        }
        req.finish(withComposedVideoFrame: out)
    }

    /// Cópia do fotograma como CGImage (BGRA).
    static func image(from pb: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb),
              let ctx = CGContext(data: base, width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb), bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        return ctx.makeImage()
    }

    /// A composição de vídeo com este compositor e as instruções embrulhadas com o fornecedor das anotações.
    static func wrap(_ vc: AVVideoComposition, provider: OverlayProvider) -> AVMutableVideoComposition {
        let m = vc.mutableCopy() as! AVMutableVideoComposition
        m.customVideoCompositorClass = OverlayCompositor.self
        m.instructions = m.instructions.map { inst in
            guard let i = inst as? AVVideoCompositionInstruction else { return inst }
            return OverlayInstruction(i, provider: provider)
        }
        return m
    }
}
