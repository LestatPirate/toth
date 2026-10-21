// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit
import ScreenCaptureKit

enum ScreenCapturer {
    enum Failure: LocalizedError {
        case displayNotFound
        var errorDescription: String? { L("Não foi possível encontrar o ecrã a capturar.") }
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
}
