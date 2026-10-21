// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit
import SwiftUI

@MainActor
enum MainWindow {
    private static var window: NSWindow?

    static let minContentSize = NSSize(width: 720, height: 520)   // estreita: as ferramentas deslizam na barra
    static var isVisible: Bool { window?.isVisible ?? false }
    /// Para testes: tamanho do conteúdo e posição (canto superior esquerdo a 40,40 do ecrã principal).
    static func placeForTests(width: CGFloat, height: CGFloat) {
        guard let w = window else { return }
        w.setContentSize(NSSize(width: width, height: height))
        if let screen = NSScreen.main { w.setFrameTopLeftPoint(NSPoint(x: 40, y: screen.frame.maxY - 40)) }
    }

    /// Para testes: clique do rato em (x, y) medidos a partir do canto superior esquerdo do conteúdo.
    static func clickForTests(x: CGFloat, y: CGFloat) {
        guard let w = window, let content = w.contentView else { return }
        let p = content.convert(NSPoint(x: x, y: content.bounds.height - y), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { w.sendEvent(e) }
        }
    }

    /// Para testes.
    static func closeForTests() { window?.close() }

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 820),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "Toth"
            w.contentMinSize = Self.minContentSize
            w.contentView = NSHostingView(rootView: MainView(state: AppState.shared))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        AppState.shared.refreshLibrary()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func hide() { window?.orderOut(nil) }

    /// Esconde as janelas normais do Toth (editor, preferências…) antes de uma captura. Ativar o Toth traz TODAS as
    /// suas janelas para a frente (e muda de Espaço se alguma estiver noutro): o editor passava por cima da aplicação
    /// que se queria capturar. Escondidas, a ativação não tem nada para trazer. O editor volta a abrir-se quando a
    /// captura termina (`show()`).
    static func hideForCapture() {
        for w in NSApp.windows where w.isVisible && w.styleMask.contains(.titled) && !(w is NSPanel) { w.orderOut(nil) }
    }

    /// Para testes: janelas do Toth visíveis no ecrã (nível normal), segundo o sistema.
    static func onScreenNormalWindowCount() -> Int {
        let pid = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }.count
    }
}
