// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit
import AVFoundation
import CaptureCore

/// Barra flutuante da gravação de vídeo, só com ícones: gravar · pausar/retomar · parar (concluir) · áudio do sistema ·
/// microfone · cancelar. Nunca fica ativa: a janela que se grava mantém o foco. (Não aparece na gravação: as janelas do
/// próprio Toth ficam de fora.)
@MainActor
final class VideoHUD: NSPanel {
    enum Phase { case ready, recording, paused }

    var onRecord: (() -> Void)?
    var onPauseResume: (() -> Void)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    var onToggleSystem: (() -> Void)?
    var onToggleMic: (() -> Void)?

    private let bar = IconBar()
    private var recordButton: IconButton!
    private var pauseButton: IconButton!
    private var stopButton: IconButton!
    private var systemButton: IconButton!
    private var micButton: IconButton!
    private var cancelButton: IconButton!
    private let timeLabel = IconBar.label("00:00", width: 56)
    private(set) var phase = Phase.ready
    private var systemOn = true, micOn = false

    init(near rect: CGRect, on screen: NSScreen) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 48), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false; hasShadow = true; backgroundColor = .clear; isOpaque = false; hidesOnDeactivate = false

        recordButton = IconButton(symbol: "record.circle.fill", tooltip: L("Gravar"), tint: .systemRed, size: 38, target: self, action: #selector(recordClicked))
        pauseButton = IconButton(symbol: "pause.fill", tooltip: L("Pausar"), target: self, action: #selector(pauseClicked))
        stopButton = IconButton(symbol: "stop.fill", tooltip: L("Parar e abrir o vídeo no editor"), target: self, action: #selector(stopClicked))
        systemButton = IconButton(symbol: "speaker.wave.2.fill", tooltip: L("Áudio do sistema: ligado"), target: self, action: #selector(systemClicked))
        micButton = IconButton(symbol: "mic.slash.fill", tooltip: L("Microfone: desligado"), target: self, action: #selector(micClicked))
        cancelButton = IconButton(symbol: "xmark", tooltip: L("Cancelar"), target: self, action: #selector(cancelClicked))
        contentView = bar
        rebuild()
        place(near: rect, on: screen)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func setPhase(_ p: Phase) {
        phase = p
        pauseButton.setSymbol(p == .paused ? "play.fill" : "pause.fill")
        pauseButton.toolTip = p == .paused ? L("Retomar") : L("Pausar")
        timeLabel.textColor = p == .paused ? .systemOrange : .labelColor
        rebuild()
    }

    func setElapsed(_ seconds: Double) {
        let s = Int(seconds)
        timeLabel.stringValue = s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    func setAudio(system: Bool, microphone: Bool) {
        systemOn = system; micOn = microphone
        systemButton.setSymbol(system ? "speaker.wave.2.fill" : "speaker.slash.fill")
        systemButton.tint = system ? nil : .secondaryLabelColor
        systemButton.toolTip = system ? L("Áudio do sistema: ligado") : L("Áudio do sistema: desligado")
        micButton.setSymbol(microphone ? "mic.fill" : "mic.slash.fill")
        micButton.tint = microphone ? nil : .secondaryLabelColor
        micButton.toolTip = microphone ? L("Microfone: ligado") : L("Microfone: desligado")
    }

    private func rebuild() {
        switch phase {
        case .ready: bar.setItems([recordButton, IconBar.separator(), systemButton, micButton, IconBar.separator(), cancelButton])
        case .recording, .paused: bar.setItems([timeLabel, pauseButton, stopButton, IconBar.separator(), systemButton, micButton, IconBar.separator(), cancelButton])
        }
        setContentSize(bar.frame.size)
    }

    /// Fora da região, para não a tapar: por cima; se não couber, por baixo; senão dentro, no topo.
    private func place(near rect: CGRect, on screen: NSScreen) {
        let f = screen.frame
        let w = frame.width, h = frame.height
        let x = min(max(f.minX + 8, f.minX + rect.midX - w / 2), f.maxX - w - 8)
        let topEdge = f.maxY - rect.minY, bottomEdge = f.maxY - rect.maxY
        var y = topEdge + 12
        if y + h > f.maxY - 4 { y = bottomEdge - h - 12 }
        if y < f.minY + 4 { y = f.maxY - h - 40 }
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    @objc private func recordClicked() { onRecord?() }
    @objc private func pauseClicked() { onPauseResume?() }
    @objc private func stopClicked() { onStop?() }
    @objc private func cancelClicked() { onCancel?() }
    @objc private func systemClicked() { onToggleSystem?() }
    @objc private func micClicked() { onToggleMic?() }

    /// Para testes visuais: a barra nos três estados.
    static func renderForTests(to path: String) {
        guard let screen = NSScreen.main else { return }
        var images: [NSImage] = []
        for (phase, sys, mic) in [(Phase.ready, true, false), (.recording, true, true), (.paused, false, true)] {
            let hud = VideoHUD(near: CGRect(x: 100, y: 300, width: 400, height: 300), on: screen)
            hud.setAudio(system: sys, microphone: mic); hud.setPhase(phase); hud.setElapsed(754)
            guard let v = hud.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: rep)
            let img = NSImage(size: v.bounds.size); img.addRepresentation(rep); images.append(img)
        }
        let w = (images.map { $0.size.width }.max() ?? 0) + 20, h = images.reduce(0) { $0 + $1.size.height + 12 } + 8
        let sheet = NSImage(size: NSSize(width: w, height: h))
        sheet.lockFocus()
        NSColor.windowBackgroundColor.setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
        var y = h
        for img in images { y -= img.size.height + 12; img.draw(at: NSPoint(x: 10, y: y + 2), from: .zero, operation: .sourceOver, fraction: 1) }
        sheet.unlockFocus()
        if let tiff = sheet.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}

/// Uma gravação de vídeo, da escolha da área até ao ficheiro MP4 guardado.
@MainActor
final class VideoCaptureSession {
    enum State { case ready, recording, paused, finishing }

    private let screen: NSScreen
    private let rect: CGRect
    private let hud: VideoHUD
    private let frame: RegionFrameWindow
    private(set) var state = State.ready
    private var engine: RecordingEngine?
    private var source: ScreenRecordingSource?
    private var tempURL: URL?
    private var clock: Timer?
    private var done: CheckedContinuation<URL?, Never>?

    private var systemOn = (UserDefaults.standard.object(forKey: "videoSystemAudio") as? Bool) ?? true
    private var micOn = (UserDefaults.standard.object(forKey: "videoMicrophone") as? Bool) ?? false

    init(screen: NSScreen, rect: CGRect) {
        self.screen = screen; self.rect = rect
        hud = VideoHUD(near: rect, on: screen)
        frame = RegionFrameWindow(rect: rect, on: screen, color: .systemRed)
        hud.onRecord = { [weak self] in Task { await self?.record() } }
        hud.onPauseResume = { [weak self] in self?.pauseResume() }
        hud.onStop = { [weak self] in Task { await self?.stop() } }
        hud.onCancel = { [weak self] in Task { await self?.cancel() } }
        hud.onToggleSystem = { [weak self] in self?.toggleSystem() }
        hud.onToggleMic = { [weak self] in Task { await self?.toggleMic() } }
    }

    /// Mostra a barra e espera pelo fim. Devolve o ficheiro guardado (na pasta das capturas) ou `nil` se foi cancelada.
    func run() async -> URL? {
        frame.orderFrontRegardless(); hud.orderFrontRegardless()
        if micOn && !MicrophonePermission.isGranted { micOn = false }   // só se liga sozinho quando já há permissão
        hud.setAudio(system: systemOn, microphone: micOn)
        hud.setPhase(.ready)
        let url = await withCheckedContinuation { (c: CheckedContinuation<URL?, Never>) in done = c }
        clock?.invalidate(); clock = nil
        hud.orderOut(nil); frame.orderOut(nil)
        return url
    }

    private func finish(_ url: URL?) {
        guard let c = done else { return }
        done = nil
        c.resume(returning: url)
    }

    // MARK: Ações

    func record() async {
        guard state == .ready else { return }
        if micOn, !(await MicrophonePermission.request()) { micOn = false; hud.setAudio(system: systemOn, microphone: false); micDenied() }
        let size = ScreenRecordingSource.videoSize(for: rect, scale: screen.backingScaleFactor)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("Toth-gravacao-\(UUID().uuidString).mp4")
        do {
            let e = try RecordingEngine(url: tmp, width: size.width, height: size.height, system: systemOn, microphone: micOn)
            let src = ScreenRecordingSource(engine: e)
            src.onStop = { [weak self] error in
                Task { @MainActor in
                    guard let self, self.state == .recording || self.state == .paused else { return }
                    _ = error
                    await self.stop()      // a captura parou sozinha: guarda o que há
                }
            }
            e.start()
            try await src.start(screen: screen, rect: rect, microphone: micOn)
            engine = e; source = src; tempURL = tmp
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        state = .recording
        hud.setPhase(.recording)
        clock = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in if let self, let e = self.engine { self.hud.setElapsed(e.elapsed()) } }
        }
    }

    func pauseResume() {
        guard let e = engine else { return }
        if state == .recording { e.pause(); state = .paused; hud.setPhase(.paused) }
        else if state == .paused { e.resume(); state = .recording; hud.setPhase(.recording) }
    }

    func stop() async {
        guard state == .recording || state == .paused, let e = engine else { return }
        state = .finishing
        clock?.invalidate()
        await source?.stop()
        do {
            try await e.finish()
            guard let tmp = tempURL else { return finish(nil) }
            finish(try Self.moveToLibrary(tmp))
        } catch {
            NSAlert(error: error).runModal()
            finish(nil)
        }
    }

    func cancel() async {
        if state == .recording || state == .paused {
            state = .finishing
            await source?.stop()
            try? await engine?.finish(discard: true)
        }
        finish(nil)
    }

    func toggleSystem() {
        systemOn.toggle()
        UserDefaults.standard.set(systemOn, forKey: "videoSystemAudio")
        engine?.setEnabled(.system, systemOn)
        hud.setAudio(system: systemOn, microphone: micOn)
    }

    func toggleMic() async {
        if micOn { micOn = false }
        else if await MicrophonePermission.request() { micOn = true }
        else { micDenied(); return }
        UserDefaults.standard.set(micOn, forKey: "videoMicrophone")
        engine?.setEnabled(.microphone, micOn)
        if micOn, state == .recording || state == .paused { await source?.enableMicrophone() }
        hud.setAudio(system: systemOn, microphone: micOn)
    }

    private func micDenied() {
        let a = NSAlert()
        a.messageText = L("Sem permissão para o microfone")
        a.informativeText = L("Para gravar a sua voz, ative o Toth em Definições do Sistema → Privacidade e Segurança → Microfone. O vídeo continua a gravar sem microfone.")
        a.addButton(withTitle: L("Abrir Definições")); a.addButton(withTitle: L("Fechar"))
        if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(MicrophonePermission.settingsURL) }
    }

    /// Move o ficheiro temporário para a pasta das capturas, com um nome único (`Toth_aaaa-mm-dd_hh.mm.ss.mp4`).
    static func moveToLibrary(_ tmp: URL) throws -> URL {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd_HH.mm.ss"
        let stamp = fmt.string(from: Date())
        var url = CaptureStore.folder.appendingPathComponent("Toth_\(stamp).mp4")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = CaptureStore.folder.appendingPathComponent("Toth_\(stamp)_\(n).mp4"); n += 1 }
        try FileManager.default.moveItem(at: tmp, to: url)
        return url
    }

    /// Ponto de entrada: grava a região `rect` (pontos, canto superior esquerdo de `screen`).
    static func record(screen: NSScreen, rect: CGRect) async -> URL? {
        await VideoCaptureSession(screen: screen, rect: rect).run()
    }
}
