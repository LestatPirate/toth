// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit
import SwiftUI

/// O símbolo do Toth (recurso `toth-logo.png`, 512×512).
enum AppLogo {
    static let image: NSImage? = {
        // Dentro do .app: Contents/Resources. Em desenvolvimento (`swift run`): pacote de recursos do SwiftPM.
        // (Bundle.module só é tocado se o recurso não estiver no .app, porque falha se o pacote não existir.)
        if let url = Bundle.main.url(forResource: "toth-logo", withExtension: "png") { return NSImage(contentsOf: url) }
        guard let url = Bundle.module.url(forResource: "toth-logo", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()

    /// O símbolo nos diálogos do sistema e no Dock.
    @MainActor static func installAsApplicationIcon() {
        if let image { NSApp.applicationIconImage = image }
    }
}

struct LogoView: View {
    var size: CGFloat
    var body: some View {
        if let image = AppLogo.image {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit().frame(width: size, height: size)
        }
    }
}
