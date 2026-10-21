// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit
import SwiftUI

enum PermissionsSelfTest {
    /// Os passos do guia, com o sistema simulado.
    @MainActor
    static func run() -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { fails.append(what) } }

        func make(granted: Bool = false) -> (PermissionsGuide, Calls) {
            let c = Calls(); c.granted = granted
            let g = PermissionsGuide(firstRun: true)
            g.isGranted = { c.granted }
            g.requestAccess = { c.requests += 1 }
            g.restart = { c.restarts += 1 }
            g.resetEntry = { c.resets += 1 }
            g.onClose = { c.closed += 1 }
            return (g, c)
        }

        // 1) caminho normal: conceder → ativar → (a permissão passa a valer) → pronto
        var (g, c) = make()
        check(g.step == .request, "devia começar no passo 1")
        g.grant()
        check(c.requests == 1 && g.step == .restart, "«Conceder» devia pedir ao sistema e passar ao passo 2 (passo \(g.step), pedidos \(c.requests))")
        g.poll()
        check(g.step == .restart, "sem a permissão ativa o guia não devia avançar")
        c.granted = true
        g.poll()
        check(g.step == .done, "com a permissão a valer o guia devia ficar «pronto»")
        g.finish()
        check(c.closed == 1, "«Começar» devia fechar o guia")

        // 2) já estava concedida: não pede nada de novo ao sistema a mais e fica pronto
        (g, c) = make(granted: true)
        g.grant()
        check(g.step == .done, "com a permissão já ativa devia ficar pronto de imediato")

        // 3) permissão presa a uma versão anterior: repor apaga a entrada e pede de novo
        (g, c) = make()
        g.grant()
        g.resetAndAsk()
        check(c.resets == 1 && c.requests == 2 && g.step == .restart, "«Repor» devia apagar a entrada e pedir de novo (reposições \(c.resets), pedidos \(c.requests))")

        // 4) reiniciar
        g.restartApp()
        check(c.restarts == 1, "«Reiniciar o Toth» devia reiniciar a app")

        // 5) «Agora não» fecha sem pedir nada
        (g, c) = make()
        g.finish()
        check(c.closed == 1 && c.requests == 0, "«Agora não» não devia pedir nada")
        return fails
    }

    final class Calls { var granted = false; var requests = 0; var restarts = 0; var resets = 0; var closed = 0 }

    /// Desenha o guia nos três estados, um por baixo do outro (teste visual).
    @MainActor
    static func render(to path: String) {
        var images: [NSImage] = []
        for step in 0..<3 {
            let g = PermissionsGuide(firstRun: step == 0)
            let c = Calls()
            g.isGranted = { step == 2 }
            g.requestAccess = { c.requests += 1 }
            if step >= 1 { g.grant() }
            if step == 2 { g.poll() }
            let host = NSHostingView(rootView: PermissionsGuideView(guide: g).environment(\.colorScheme, .light))
            let size = host.fittingSize
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
            window.makeKeyAndOrderFront(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                let img = NSImage(size: size); img.addRepresentation(rep); images.append(img)
            }
        }
        let w = images.map { $0.size.width }.max() ?? 0, h = images.reduce(0) { $0 + $1.size.height + 10 }
        let sheet = NSImage(size: NSSize(width: w, height: h))
        sheet.lockFocus()
        NSColor(white: 0.8, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
        var y = h
        for img in images { y -= img.size.height + 10; img.draw(at: NSPoint(x: 0, y: y + 5), from: .zero, operation: .sourceOver, fraction: 1) }
        sheet.unlockFocus()
        if let tiff = sheet.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}
