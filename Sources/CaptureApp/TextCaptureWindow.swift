// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit
import CaptureCore

/// «Texto» na captura: o texto reconhecido na área escolhida, já copiado, numa janela pequena onde se pode corrigir,
/// juntar numa só linha e copiar de novo. Nada vai para a biblioteca nem para o editor.
@MainActor
final class TextCaptureWindow: NSObject, NSTextViewDelegate {
    static var current: TextCaptureWindow?

    /// Junta as linhas reconhecidas: uma por linha, ou tudo numa só (espaços simples) com `singleLine`.
    nonisolated static func join(_ lines: [String], singleLine: Bool) -> String {
        let clean = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return singleLine ? clean.joined(separator: " ").split(separator: " ").joined(separator: " ") : clean.joined(separator: "\n")
    }

    /// Reconhece o texto de `image` (em segundo plano) e mostra a janela. Sem texto, avisa.
    static func show(_ image: CGImage) {
        Task.detached(priority: .userInitiated) {
            let lines = ((try? TextRecognizer.recognize(image, origin: Point(x: 0, y: 0))) ?? []).map(\.text)
            RunLoop.main.perform { MainActor.assumeIsolated { present(lines: lines, image: image) } }
        }
    }

    static func present(lines: [String], image: CGImage?) {
        current?.window.close()
        let w = TextCaptureWindow(lines: lines, image: image)
        current = w
        w.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        w.copyText()
    }

    let window: NSPanel
    private let lines: [String]
    private let textView = NSTextView()
    private let singleLine = NSButton(checkboxWithTitle: L("Só uma linha"), target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private let preview = NSImageView()
    private var edited = false

    private init(lines: [String], image: CGImage?) {
        self.lines = lines
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 360), styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        super.init()
        window.title = L("Texto da captura")
        window.isFloatingPanel = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.center()
        let content = NSView(frame: window.contentView!.bounds); content.autoresizingMask = [.width, .height]
        window.contentView = content

        if let image {
            preview.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            preview.imageScaling = .scaleProportionallyDown
            preview.frame = NSRect(x: 12, y: content.bounds.height - 84, width: content.bounds.width - 24, height: 72)
            preview.autoresizingMask = [.width, .minYMargin]
            preview.wantsLayer = true; preview.layer?.cornerRadius = 6; preview.layer?.borderWidth = 1; preview.layer?.borderColor = NSColor.separatorColor.cgColor
            content.addSubview(preview)
        }
        let scroll = NSScrollView(frame: NSRect(x: 12, y: 52, width: content.bounds.width - 24, height: content.bounds.height - 52 - 96))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        textView.isRichText = false; textView.font = NSFont.systemFont(ofSize: 13); textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.minSize = NSSize(width: 0, height: 0); textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false; textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        scroll.documentView = textView
        content.addSubview(scroll)

        singleLine.target = self; singleLine.action = #selector(toggleSingleLine)
        singleLine.frame = NSRect(x: 12, y: 16, width: 140, height: 22); singleLine.autoresizingMask = [.maxXMargin, .maxYMargin]
        singleLine.state = (UserDefaults.standard.bool(forKey: "textCaptureSingleLine")) ? .on : .off
        content.addSubview(singleLine)
        status.frame = NSRect(x: 160, y: 18, width: 140, height: 18); status.autoresizingMask = [.width, .maxYMargin]
        status.font = NSFont.systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        content.addSubview(status)
        let copy = NSButton(title: L("Copiar"), target: self, action: #selector(copyClicked))
        copy.keyEquivalent = "\r"; copy.frame = NSRect(x: content.bounds.width - 100, y: 12, width: 88, height: 30); copy.autoresizingMask = [.minXMargin, .maxYMargin]
        content.addSubview(copy)
        let close = NSButton(title: L("Fechar"), target: self, action: #selector(closeClicked))
        close.keyEquivalent = "\u{1B}"; close.frame = NSRect(x: content.bounds.width - 196, y: 12, width: 88, height: 30); close.autoresizingMask = [.minXMargin, .maxYMargin]
        content.addSubview(close)

        refreshText()
        if lines.isEmpty { status.stringValue = L("Não foi encontrado texto nesta área."); status.textColor = .systemOrange }
    }

    private var isSingleLine: Bool { singleLine.state == .on }
    /// O texto como está (editado ou derivado das linhas reconhecidas).
    var text: String { textView.string }

    private func refreshText() {
        guard !edited else { return }
        textView.string = Self.join(lines, singleLine: isSingleLine)
    }

    @objc private func toggleSingleLine() {
        UserDefaults.standard.set(isSingleLine, forKey: "textCaptureSingleLine")
        if edited {
            // já foi corrigido à mão: aplica a junção ao texto atual, sem perder as correções
            edited = false
            let current = textView.string.split(separator: "\n").map(String.init)
            textView.string = Self.join(current, singleLine: isSingleLine)
            edited = true
        } else { refreshText() }
        copyText()
    }
    func setSingleLine(_ on: Bool) { singleLine.state = on ? .on : .off; toggleSingleLine() }

    func textDidChange(_ notification: Notification) { edited = true; status.stringValue = "" }

    /// Copia o texto como está e avisa.
    func copyText() {
        let t = textView.string
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
        if !t.isEmpty { status.stringValue = L("Copiado (%d letras)", t.count); status.textColor = .secondaryLabelColor }
    }
    @objc private func copyClicked() { copyText() }
    @objc private func closeClicked() { window.close() }
}
