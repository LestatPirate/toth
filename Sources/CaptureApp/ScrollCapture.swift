// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit
import CaptureCore
import CoreMedia
import CoreVideo
import ScreenCaptureKit

// Captura com rolagem feita pelo utilizador.
//
// Depois de escolher a área e carregar em «Rolagem», o Toth passa a capturar a região continuamente enquanto o
// utilizador rola a janela como quiser: para qualquer lado, devagar ou depressa, voltando atrás e passando outra
// vez pela mesma zona. O Toth não envia nenhuma rolagem nem mexe na janela (por isso não precisa de permissão de
// Acessibilidade). A imagem final só é criada quando o utilizador carrega em «Concluir».

/// Fonte de capturas da região. A real usa o ecrã; os testes usam uma página sintética.
@MainActor
protocol FrameSource: AnyObject {
    /// A próxima imagem nova da região, ou `nil` se nada mudou entretanto (o ecrã parado não gera imagens).
    func nextFrame() async throws -> PixelFrame?
    func finish() async
}

extension FrameSource { func finish() async {} }

/// Quem manda parar: «Concluir» cria a imagem com o que já foi capturado; «Cancelar» descarta tudo.
enum ScrollControl { case run, pause, finish, cancel }

/// Estado mostrado ao utilizador durante a captura.
struct ScrollStatus: Equatable {
    enum Health { case ok, tooFast, limit }
    var width = 0
    var height = 0
    var frames = 0
    var failures = 0       // tentativas seguidas sem conseguir alinhar
    var paused = false
    var health = Health.ok
}

/// Faz o trabalho pesado (comparar e juntar) fora da thread principal, para a barra continuar a responder.
actor MosaicWorker {
    private var stitcher = MosaicStitcher()

    func add(_ f: PixelFrame) -> (result: MosaicStitcher.Result, width: Int, height: Int, accepted: Int) {
        let r = stitcher.add(f)
        let s = stitcher.size
        return (r, s.width, s.height, stitcher.accepted)
    }

    func result() -> (image: PixelFrame?, accepted: Int) { (stitcher.result(), stitcher.accepted) }
}

@MainActor
final class ScrollRecorder {
    enum Outcome {
        case image(PixelFrame, frames: Int)
        case single(PixelFrame, moved: Int, failed: Int)   // nada se juntou: fica a captura simples (e porquê)
        case cancelled
    }

    var control: () -> ScrollControl = { .run }
    /// A primeira imagem da captura: a do instante exato em que o utilizador carregou em «Rolagem».
    var firstFrame: PixelFrame?
    var onStatus: (ScrollStatus) -> Void = { _ in }
    /// Pausa entre capturas (a própria captura demora o seu tempo).
    var pause: TimeInterval = 0.03

    private let source: FrameSource
    init(source: FrameSource) { self.source = source }

    func run() async throws -> Outcome {
        let worker = MosaicWorker()
        var status = ScrollStatus()
        var failures = 0
        var moved = 0, failedTotal = 0, unchanged = 0, idle = 0
        var last: PixelFrame?
        var work: TimeInterval = 0
        if let first = firstFrame {
            last = first
            let r = await worker.add(first)
            status.width = r.width; status.height = r.height; status.frames = r.accepted
            onStatus(status)
        }
        loop: while true {
            switch control() {
            case .cancel: await source.finish(); return .cancelled
            case .finish: break loop
            case .pause:
                // Em pausa: as imagens continuam a chegar mas são ignoradas. Ao retomar, a primeira imagem
                // alinha com a última aceite ou com uma das anteriores, esteja o utilizador onde estiver.
                if !status.paused { status.paused = true; onStatus(status) }
                _ = try await source.nextFrame()
                try? await Task.sleep(nanoseconds: 30_000_000)
                continue
            case .run:
                if status.paused { status.paused = false; onStatus(status) }
            }
            guard let frame = try await source.nextFrame() else { idle += 1; continue }
            last = frame
            let t0 = Date()
            let r = await worker.add(frame)
            work += Date().timeIntervalSince(t0)
            switch r.result {
            case .moved:
                moved += 1; failures = 0; status.health = .ok
            case .failed:
                failedTotal += 1; failures += 1
                if failures >= 3 { status.health = .tooFast }   // rolou depressa demais ou o conteúdo mudou: voltar um pouco atrás retoma
            case .limit:
                status.health = .limit
                status.width = r.width; status.height = r.height; status.frames = r.accepted
                onStatus(status)
                break loop                                      // a imagem atingiu o tamanho máximo: termina com o que há
            case .unchanged:
                unchanged += 1
            case .first:
                break
            }
            status.failures = failures
            status.width = r.width; status.height = r.height; status.frames = r.accepted
            onStatus(status)
            if pause > 0 { try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000)) }
        }
        await source.finish()
        let done = await worker.result()
        let n = moved + failedTotal + unchanged
        NSLog("Toth rolagem: %d juntas, %d sem alinhar, %d iguais, %d vezes sem imagem nova; %.0f ms por imagem; resultado %dx%d",
              moved, failedTotal, unchanged, idle, n > 0 ? work / Double(n) * 1000 : 0, done.image?.width ?? 0, done.image?.height ?? 0)
        guard let image = done.image else { return last.map { .single($0, moved: moved, failed: failedTotal) } ?? .cancelled }
        return done.accepted < 2 ? .single(image, moved: moved, failed: failedTotal) : .image(image, frames: done.accepted)
    }
}

// MARK: - Conversões entre imagens do sistema e bytes

enum FrameConversion {
    static func frame(from image: CGImage, in space: CGColorSpace? = nil) -> PixelFrame {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let space = space ?? rgbSpace(of: image)
        bytes.withUnsafeMutableBytes { raw in
            if let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.setBlendMode(.copy)
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        return PixelFrame(width: w, height: h, rgba: bytes)
    }

    static func image(from frame: PixelFrame, space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(frame.rgba) as CFData) else { return nil }
        return CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: frame.width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Mantém o espaço de cor do ecrã (o ecrã do Mac costuma ser Display P3), para a cor não mudar.
    static func rgbSpace(of image: CGImage) -> CGColorSpace {
        if let s = image.colorSpace, s.model == .rgb { return s }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }
}

// MARK: - Região do ecrã real

/// Recebe as imagens do ScreenCaptureKit (noutra fila) e guarda só a mais recente.
private final class StreamFrameBox: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var seq = 0
    private var error: Error?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        // só imagens completas (o ScreenCaptureKit também envia avisos de "nada mudou", "parado", etc.)
        guard let atts = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = atts.first?[.status] as? Int, raw == SCFrameStatus.complete.rawValue,
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock(); latest = pb; seq += 1; lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); self.error = error; lock.unlock()
    }

    func take(after last: Int) -> (seq: Int, buffer: CVPixelBuffer)? {
        lock.lock(); defer { lock.unlock() }
        guard seq > last, let b = latest else { return nil }
        return (seq, b)
    }

    var failure: Error? { lock.lock(); defer { lock.unlock() }; return error }
}

/// Captura contínua da região (30 imagens por segundo), para não perder sobreposição entre imagens quando o
/// utilizador rola depressa. (Uma captura de cada vez, em ciclo, demora cerca de 0,2 s num ecrã Retina.)
@MainActor
final class ScreenRegionSource: FrameSource {
    private let stream: SCStream
    private let box = StreamFrameBox()
    private var lastSeq = 0
    let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!

    /// `rect` em pontos, relativo ao canto superior esquerdo do ecrã `screen`. As janelas do próprio Toth ficam de fora.
    init(screen: NSScreen, rect: CGRect, pixelSize: (width: Int, height: Int)) async throws {
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == id }) else { throw ScreenCapturer.Failure.displayNotFound }
        let own = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingWindows: own)
        let c = SCStreamConfiguration()
        c.sourceRect = rect
        c.width = pixelSize.width
        c.height = pixelSize.height
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.colorSpaceName = CGColorSpace.displayP3
        c.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        c.queueDepth = 5
        c.showsCursor = false
        c.capturesAudio = false
        stream = SCStream(filter: filter, configuration: c, delegate: box)
        try stream.addStreamOutput(box, type: .screen, sampleHandlerQueue: DispatchQueue(label: "io.github.lestatpirate.toth.scroll-frames"))
        try await stream.startCapture()
    }

    func nextFrame() async throws -> PixelFrame? {
        for _ in 0..<8 {                                  // ~0,16 s à espera de uma imagem nova
            if let f = box.take(after: lastSeq) { lastSeq = f.seq; return Self.frame(from: f.buffer) }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if let e = box.failure { throw e }
        return nil
    }

    func finish() async { try? await stream.stopCapture() }

    /// BGRA do sistema → RGBA.
    static func frame(from pb: CVPixelBuffer) -> PixelFrame {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        var out = [UInt8](repeating: 255, count: w * h * 4)
        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else { return PixelFrame(width: w, height: h, rgba: out) }
        out.withUnsafeMutableBufferPointer { dst in
            for y in 0..<h {
                let s = base + y * bpr
                var d = y * w * 4
                for x in 0..<w {
                    dst[d] = s[x * 4 + 2]; dst[d + 1] = s[x * 4 + 1]; dst[d + 2] = s[x * 4]; dst[d + 3] = 255
                    d += 4
                }
            }
        }
        return PixelFrame(width: w, height: h, rgba: out)
    }
}

// MARK: - Barra flutuante e moldura

/// Painel pequeno, sempre à frente, com o estado e os botões «Concluir» e «Cancelar». Nunca fica "ativo":
/// a janela que o utilizador está a rolar mantém o foco.
@MainActor
final class ScrollHUD: NSPanel {
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?
    var onPause: (() -> Void)?
    private let headline = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let pauseButton = NSButton(title: L("Pausar"), target: nil, action: nil)
    private let finishButton = NSButton(title: L("Concluir"), target: nil, action: nil)
    private let cancelButton = NSButton(title: L("Cancelar"), target: nil, action: nil)

    init(near rect: CGRect, on screen: NSScreen) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 690, height: 64), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        hidesOnDeactivate = false
        let box = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 690, height: 64))
        box.material = .hudWindow; box.state = .active; box.wantsLayer = true
        box.layer?.cornerRadius = 12; box.layer?.masksToBounds = true
        headline.font = .systemFont(ofSize: 12.5, weight: .semibold); headline.textColor = .labelColor
        headline.frame = NSRect(x: 14, y: 36, width: 380, height: 18)
        detail.font = .systemFont(ofSize: 11); detail.textColor = .secondaryLabelColor
        detail.frame = NSRect(x: 14, y: 12, width: 380, height: 16)
        pauseButton.target = self; pauseButton.action = #selector(pauseClicked)
        pauseButton.bezelStyle = .rounded; pauseButton.frame = NSRect(x: 402, y: 18, width: 92, height: 28)
        finishButton.target = self; finishButton.action = #selector(finishClicked)
        finishButton.bezelStyle = .rounded; finishButton.keyEquivalent = "\r"; finishButton.frame = NSRect(x: 498, y: 18, width: 92, height: 28)
        cancelButton.target = self; cancelButton.action = #selector(cancelClicked)
        cancelButton.bezelStyle = .rounded; cancelButton.frame = NSRect(x: 594, y: 18, width: 86, height: 28)
        [headline, detail, pauseButton, finishButton, cancelButton].forEach { box.addSubview($0) }
        contentView = box
        place(near: rect, on: screen)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Fora da região, para não a tapar: por cima; se não couber, por baixo; senão dentro, no topo.
    /// `rect` é relativo ao canto superior esquerdo de `screen`.
    private func place(near rect: CGRect, on screen: NSScreen) {
        let f = screen.frame
        let w = frame.width, h = frame.height
        let x = min(max(f.minX + 8, f.minX + rect.midX - w / 2), f.maxX - w - 8)
        let topEdge = f.maxY - rect.minY, bottomEdge = f.maxY - rect.maxY    // em coordenadas do Cocoa
        var y = topEdge + 12
        if y + h > f.maxY - 4 { y = bottomEdge - h - 12 }
        if y < f.minY + 4 { y = f.maxY - h - 40 }
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    func show(_ s: ScrollStatus) {
        pauseButton.title = s.paused ? L("Retomar") : L("Pausar")
        if s.paused {
            headline.stringValue = s.frames < 2 ? L("Em pausa") : L("Em pausa · %d × %d px · %d capturas", s.width, s.height, s.frames)
            detail.stringValue = L("Clique em Retomar e continue a rolar a partir de uma zona já capturada.")
            detail.textColor = .systemBlue
            return
        }
        if s.frames < 2 {
            headline.stringValue = L("Role a janela como quiser")
            if s.health == .tooFast {
                detail.stringValue = L("Não consegui alinhar as imagens: role mais devagar ou volte atrás.")
                detail.textColor = .systemOrange
            } else {
                detail.stringValue = L("Para qualquer lado; pode voltar atrás. Depois clique em Concluir.")
                detail.textColor = .secondaryLabelColor
            }
            return
        }
        headline.stringValue = L("%d × %d px · %d capturas", s.width, s.height, s.frames)
        switch s.health {
        case .ok:
            detail.stringValue = L("Continue a rolar; clique em Concluir para criar a imagem.")
            detail.textColor = .secondaryLabelColor
        case .tooFast:
            detail.stringValue = L("Rolou depressa demais: volte um pouco atrás para retomar.")
            detail.textColor = .systemOrange
        case .limit:
            detail.stringValue = L("Tamanho máximo atingido.")
            detail.textColor = .systemOrange
        }
    }

    /// Para testes visuais: desenha a barra (nos três estados) e grava um PNG.
    static func renderForTests(to path: String) {
        guard let screen = NSScreen.main else { return }
        let states = [ScrollStatus(), ScrollStatus(width: 1440, height: 12480, frames: 38, health: .ok),
                      ScrollStatus(width: 1440, height: 12480, frames: 38, health: .tooFast),
                      ScrollStatus(width: 1440, height: 12480, frames: 38, paused: true)]
        let sheet = NSImage(size: NSSize(width: 690, height: 64 * 4 + 20))
        sheet.lockFocus()
        NSColor.windowBackgroundColor.setFill(); NSRect(x: 0, y: 0, width: 690, height: 64 * 4 + 20).fill()
        for (i, st) in states.enumerated() {
            let hud = ScrollHUD(near: CGRect(x: 100, y: 300, width: 400, height: 300), on: screen)
            hud.show(st)
            guard let v = hud.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: rep)
            NSImage(size: v.bounds.size).addRepresentation(rep)
            let img = NSImage(size: v.bounds.size); img.addRepresentation(rep)
            img.draw(at: NSPoint(x: 0, y: CGFloat(3 - i) * 70 + 8), from: .zero, operation: .sourceOver, fraction: 1)
        }
        sheet.unlockFocus()
        if let tiff = sheet.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

    @objc private func pauseClicked() { onPause?() }
    @objc private func finishClicked() { onFinish?() }
    @objc private func cancelClicked() { onCancel?() }
}

/// Moldura azul à volta da região (não apanha cliques; as janelas do Toth não entram na captura).
@MainActor
final class RegionFrameWindow: NSWindow {
    init(rect: CGRect, on screen: NSScreen) {
        let f = screen.frame
        let r = NSRect(x: f.minX + rect.minX - 3, y: f.maxY - rect.maxY - 3, width: rect.width + 6, height: rect.height + 6)
        super.init(contentRect: r, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        ignoresMouseEvents = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        contentView = FrameBorderView(frame: NSRect(origin: .zero, size: r.size))
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class FrameBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemBlue.setStroke()
        let p = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        p.lineWidth = 3; p.stroke()
    }
}

// MARK: - Sessão (interface)

@MainActor
enum ScrollCaptureSession {
    private static var running = false
    private static var control = ScrollControl.run
    /// Para testes: como se se clicasse em «Concluir».
    static func debugFinish() { control = .finish }

    /// Captura com rolagem a região `rect` (pontos, relativos ao canto superior esquerdo de `screen`).
    /// Devolve a imagem comprida, ou `nil` se foi cancelada. `first` é a imagem exata dessa área no instante em que
    /// o utilizador carregou em «Rolagem» (a captura começa aí). Não se traz nenhuma app para a frente nem se muda
    /// de Espaço: o utilizador rola a janela que já está no ecrã.
    static func capture(screen: NSScreen, rect: CGRect, first: CGImage) async -> CGImage? {
        guard !running else { return nil }
        running = true
        defer { running = false }

        let hud = ScrollHUD(near: rect, on: screen)
        let frame = RegionFrameWindow(rect: rect, on: screen)
        control = .run
        hud.onFinish = { control = .finish }
        hud.onCancel = { control = .cancel }
        hud.onPause = { control = control == .pause ? .run : .pause }
        defer { hud.orderOut(nil); frame.orderOut(nil) }

        var useFirst = true            // ao tentar de novo, a imagem de partida já não vale: o ecrã mudou
        while true {
            control = .run
            hud.show(ScrollStatus())
            frame.orderFrontRegardless()
            hud.orderFrontRegardless()

            do {
                let source = try await ScreenRegionSource(screen: screen, rect: rect, pixelSize: (first.width, first.height))
                let recorder = ScrollRecorder(source: source)
                if useFirst { recorder.firstFrame = FrameConversion.frame(from: first, in: source.colorSpace) }
                useFirst = false
                recorder.control = { control }
                recorder.onStatus = { hud.show($0) }
                switch try await recorder.run() {
                case .cancelled:
                    return nil
                case let .image(f, _):
                    return FrameConversion.image(from: f, space: source.colorSpace)
                case let .single(f, _, failed):
                    hud.orderOut(nil); frame.orderOut(nil)
                    let alert = NSAlert()
                    alert.messageText = L("Não foi possível juntar as capturas")
                    alert.informativeText = failed > 0
                        ? L("A janela rolou, mas as imagens não alinharam (rolou depressa demais, ou o conteúdo mudou enquanto rolava). Pode tentar de novo, rolando mais devagar, ou guardar só a captura simples.")
                        : L("Não detetei nenhuma rolagem na área escolhida. Confirme que rola dentro da área marcada a azul. Pode tentar de novo ou guardar só a captura simples.")
                    alert.addButton(withTitle: L("Tentar de novo"))
                    alert.addButton(withTitle: L("Guardar captura simples"))
                    alert.addButton(withTitle: L("Cancelar"))
                    switch alert.runModal() {
                    case .alertFirstButtonReturn: continue                    // recomeça na mesma área
                    case .alertSecondButtonReturn: return FrameConversion.image(from: f, space: source.colorSpace)
                    default: return nil
                    }
                }
            } catch {
                hud.orderOut(nil); frame.orderOut(nil)
                NSAlert(error: error).runModal()
                return nil
            }
        }
    }
}
