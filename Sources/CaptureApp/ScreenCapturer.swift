// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit
import ScreenCaptureKit

/// Uma janela de outra app que está no ecrã (para a captura de janela).
struct WindowInfo: Equatable {
    let id: CGWindowID
    /// Retângulo da janela nas coordenadas da vista do seletor desse ecrã (pontos, origem no canto superior esquerdo do ecrã).
    let frame: CGRect
    let title: String
    let app: String
}

enum ScreenCapturer {
    enum Failure: LocalizedError {
        case displayNotFound, windowNotFound
        var errorDescription: String? {
            switch self {
            case .displayNotFound: L("Não foi possível encontrar o ecrã a capturar.")
            case .windowNotFound: L("A janela já não está no ecrã.")
            }
        }
    }

    /// Instantâneo do ecrã inteiro, em pixels nativos, tirado neste instante. É este instantâneo (e não o ecrã
    /// "ao vivo") que depois se mostra e recorta, por isso a captura corresponde ao momento do atalho.
    /// As janelas da própria Capture ficam de fora.
    static func snapshot(of screen: NSScreen) async throws -> CGImage {
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw Failure.displayNotFound }

        let config = SCStreamConfiguration()
        config.width = Int((screen.frame.width * screen.backingScaleFactor).rounded())
        config.height = Int((screen.frame.height * screen.backingScaleFactor).rounded())
        config.showsCursor = false
        config.capturesAudio = false

        let own = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingWindows: own)
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// As janelas normais (de outras apps) visíveis em `screen`, da frente para trás, com o retângulo em coordenadas da vista
    /// do seletor desse ecrã. Ficam de fora as do próprio Toth, as do sistema (barra de menus, Dock) e as minúsculas.
    static func windows(on screen: NSScreen) async -> [WindowInfo] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return [] }
        return windows(from: content.windows.map { ($0.windowID, $0.frame, $0.title ?? "", $0.owningApplication?.applicationName ?? "", $0.owningApplication?.bundleIdentifier ?? "", $0.owningApplication?.processID ?? 0, $0.windowLayer) }, on: screen)
    }

    /// Apps do sistema cujas «janelas» não são janelas (gestor de janelas, Dock, Centro de Controlo, notificações).
    static let systemBundles: Set<String> = ["com.apple.WindowManager", "com.apple.dock", "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.Spotlight", "com.apple.wallpaper.agent"]

    /// (Separado para os testes.) `frame` vem nas coordenadas globais do Core Graphics (origem no canto superior esquerdo do ecrã principal).
    static func windows(from list: [(id: CGWindowID, frame: CGRect, title: String, app: String, bundle: String, pid: pid_t, layer: Int)], on screen: NSScreen) -> [WindowInfo] {
        let main = NSScreen.screens.first ?? screen
        let top = main.frame.maxY - screen.frame.maxY     // y (CG) do topo deste ecrã
        let me = ProcessInfo.processInfo.processIdentifier
        var out: [WindowInfo] = []
        for w in list where w.pid != me && w.layer == 0 && w.frame.width >= 40 && w.frame.height >= 40 && !systemBundles.contains(w.bundle) {
            let local = CGRect(x: w.frame.minX - screen.frame.minX, y: w.frame.minY - top, width: w.frame.width, height: w.frame.height)
            let visible = local.intersection(CGRect(origin: .zero, size: screen.frame.size))
            guard !visible.isNull, visible.width >= 20, visible.height >= 20 else { continue }
            out.append(WindowInfo(id: w.id, frame: local, title: w.title, app: w.app))
        }
        return out
    }

    /// Captura só uma janela (mesmo que esteja parcialmente tapada), em píxeis nativos, com ou sem sombra.
    /// A captura é sempre sem a sombra do sistema (para ficar ao tamanho exato da janela); com `shadow`, desenha-se uma sombra
    /// própria à volta, numa margem transparente (`shadowMargin` pontos). `scale`: píxeis por ponto do ecrã onde a janela está.
    static func captureWindow(id: CGWindowID, shadow: Bool, scale: CGFloat) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let w = content.windows.first(where: { $0.windowID == id }) else { throw Failure.windowNotFound }
        let filter = SCContentFilter(desktopIndependentWindow: w)
        let config = SCStreamConfiguration()
        let r = filter.contentRect
        config.width = max(2, Int((r.width * scale).rounded()))
        config.height = max(2, Int((r.height * scale).rounded()))
        config.showsCursor = false
        config.capturesAudio = false
        config.ignoreShadowsSingleWindow = true
        config.shouldBeOpaque = false
        config.captureResolution = .best
        let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return shadow ? addShadow(to: img, scale: scale) : img
    }

    static let shadowMargin: CGFloat = 40

    /// A imagem numa tela maior e transparente, com uma sombra suave por baixo (como a das janelas do macOS).
    static func addShadow(to img: CGImage, scale: CGFloat) -> CGImage {
        let m = Int(shadowMargin * scale)
        let w = img.width + 2 * m, h = img.height + 2 * m
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return img }
        ctx.setShadow(offset: CGSize(width: 0, height: -8 * scale), blur: 28 * scale, color: CGColor(gray: 0, alpha: 0.5))
        ctx.draw(img, in: CGRect(x: m, y: m, width: img.width, height: img.height))
        return ctx.makeImage() ?? img
    }
}
