// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit
import SwiftUI

/// O ícone da aplicação à escolha: o original, quatro alternativos que vêm com a app, ou uma imagem do utilizador.
/// A escolha fica nas preferências e a imagem personalizada é copiada (já normalizada) para
/// `~/Library/Application Support/Toth/AppIcon-Custom.png`, por isso mantém-se entre arranques.
///
/// O ícone é aplicado de duas maneiras: à app a correr (`NSApp.applicationIconImage`: Dock, ⌘Tab, diálogos) e ao pacote
/// `.app` no disco, como ícone personalizado do Finder (`NSWorkspace.setIcon`, o mesmo que colar uma imagem em «Obter
/// informações»): é esse que o Dock mostra com a app fechada, e o Stage Manager, o Finder e o Launchpad sempre.
/// O ícone personalizado fica *ao lado* do conteúdo assinado (ficheiro `Icon\r` + atributo do Finder): o executável e a sua
/// assinatura não mudam, por isso a permissão de gravação de ecrã mantém-se. Uma atualização substitui o pacote e leva o
/// ícone personalizado; `apply()` repõe-no no arranque seguinte.
@MainActor
final class AppIcon: ObservableObject {
    static let shared = AppIcon()

    struct Option: Identifiable {
        let id: String
        let title: String
    }
    static let original = "original", custom = "custom"
    /// Os que vêm com a app (ficheiros `Resources/icons/AppIcon-<Id>.png`, 512×512, já na grelha de ícones do macOS).
    static var bundled: [Option] {
        [Option(id: original, title: L("Original")), Option(id: "Aurora", title: L("Aurora")), Option(id: "Night", title: L("Noite")),
         Option(id: "Indigo", title: L("Índigo")), Option(id: "Teal", title: L("Petróleo"))]
    }

    private static let key = "appIcon"
    @Published private(set) var current: String = UserDefaults.standard.string(forKey: AppIcon.key) ?? AppIcon.original
    /// Muda quando a imagem personalizada é substituída (para a pré-visualização se refazer).
    @Published private(set) var customRevision = 0

    static var customURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Toth/AppIcon-Custom.png")
    }
    var hasCustom: Bool { FileManager.default.fileExists(atPath: Self.customURL.path) }

    func image(for id: String) -> NSImage? {
        switch id {
        case Self.original: return AppLogo.image
        case Self.custom: return NSImage(contentsOf: Self.customURL)
        default:
            let name = "AppIcon-\(id)"
            if let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "icons") { return NSImage(contentsOf: url) }
            // (em desenvolvimento, `swift run`: pacote de recursos do SwiftPM; só se toca nele se o recurso não estiver no .app)
            if Bundle.main.url(forResource: "toth-logo", withExtension: "png") != nil { return nil }
            return Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "icons").flatMap { NSImage(contentsOf: $0) }
        }
    }

    /// Põe o ícone escolhido na app a correr e no pacote (se a escolha já não existir, volta ao original).
    /// No arranque só toca no pacote se for preciso: falta o ícone personalizado (primeira vez, ou depois de uma
    /// atualização), ou sobra (voltou-se ao original).
    func apply() {
        let chosen = image(for: current)
        if let image = chosen ?? AppLogo.image { NSApp.applicationIconImage = image }
        let wantsCustom = chosen != nil && current != Self.original
        if wantsCustom != Self.bundleHasCustomIcon { applyToBundle(wantsCustom ? chosen : nil) }
    }

    func select(_ id: String) {
        guard let image = image(for: id) else { return }
        current = id
        UserDefaults.standard.set(id, forKey: Self.key)
        NSApp.applicationIconImage = image
        applyToBundle(id == Self.original ? nil : image)
    }

    /// O pacote `.app` de onde a app corre (`nil` em desenvolvimento, com o binário solto).
    private static var bundleURL: URL? {
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app" ? url : nil
    }
    /// O pacote tem um ícone personalizado do Finder?
    static var bundleHasCustomIcon: Bool {
        bundleURL.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Icon\r").path) } ?? false
    }
    /// Põe (ou tira, com `nil`) o ícone personalizado do pacote. Falha em silêncio se o pacote não for gravável
    /// (app numa pasta só de leitura): fica só o ícone da app a correr.
    @discardableResult
    private func applyToBundle(_ image: NSImage?) -> Bool {
        guard let url = Self.bundleURL else { return false }
        let ok = NSWorkspace.shared.setIcon(image, forFile: url.path, options: [])
        if ok { NSWorkspace.shared.noteFileSystemChanged(url.path) }
        return ok
    }

    /// Usa uma imagem do utilizador: normaliza-a (grelha de ícones do macOS, 1024×1024), guarda-a e escolhe-a.
    @discardableResult
    func setCustom(from url: URL) -> Bool {
        guard let source = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let icon = Self.normalized(source), let png = Self.png(icon) else { return false }
        do {
            try FileManager.default.createDirectory(at: Self.customURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: Self.customURL, options: .atomic)
        } catch { return false }
        customRevision += 1
        select(Self.custom)
        return true
    }

    // MARK: Normalização

    /// Lado do corpo do ícone numa tela de 1024 (grelha de ícones do macOS: 824 de corpo, 100 de margem).
    nonisolated static let bodyRatio = 824.0 / 1024.0

    /// Leva qualquer imagem à grelha de ícones do macOS, numa tela quadrada de `side` píxeis:
    /// - com transparência: a parte opaca (o «corpo») é centrada e ocupa 824/1024 do lado; sombras suaves ficam à volta;
    /// - sem transparência (uma fotografia): recorta-se ao centro em quadrado e arredondam-se os cantos como nos ícones do macOS.
    nonisolated static func normalized(_ source: CGImage, side: Int = 1024) -> CGImage? {
        // cópia RGBA de trabalho (até 1024 de lado) para medir a transparência
        let k = min(1, 1024.0 / Double(max(source.width, source.height)))
        let w = max(1, Int(Double(source.width) * k)), h = max(1, Int(Double(source.height) * k))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let probe = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        probe.interpolationQuality = .high
        probe.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = probe.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var minX = w, minY = h, maxX = -1, maxY = -1, clear = 0
        for y in 0..<h {
            for x in 0..<w {
                if px[(y * w + x) * 4 + 3] > 128 {
                    if x < minX { minX = x }; if x > maxX { maxX = x }
                    if y < minY { minY = y }; if y > maxY { maxY = y }
                } else { clear += 1 }
            }
        }
        guard maxX >= minX, maxY >= minY, let out = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: space,
                                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        out.interpolationQuality = .high
        let body = Double(side) * bodyRatio, margin = (Double(side) - body) / 2
        if Double(clear) > Double(w * h) * 0.01 {
            // tem transparência: o corpo (caixa do que é opaco) vai para o quadrado de 824, o resto da imagem acompanha
            // (as linhas do mapa de bits contam de cima; o Core Graphics desenha de baixo: daí o `h - 1 - maxY`)
            let bw = Double(maxX - minX + 1), bh = Double(maxY - minY + 1)
            let s = body / max(bw, bh)
            let bx = Double(minX), by = Double(h - 1 - maxY)
            let ox = margin + (body - bw * s) / 2 - bx * s, oy = margin + (body - bh * s) / 2 - by * s
            out.draw(source, in: CGRect(x: ox, y: oy, width: Double(w) * s, height: Double(h) * s))
        } else {
            // opaca: quadrado ao centro, com os cantos arredondados dos ícones do macOS
            let rect = CGRect(x: margin, y: margin, width: body, height: body)
            out.addPath(CGPath(roundedRect: rect, cornerWidth: body * 0.225, cornerHeight: body * 0.225, transform: nil))
            out.clip()
            let s = body / Double(min(w, h))
            out.draw(source, in: CGRect(x: margin - (Double(w) * s - body) / 2, y: margin - (Double(h) * s - body) / 2, width: Double(w) * s, height: Double(h) * s))
        }
        return out.makeImage()
    }

    nonisolated static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// `--icon-selftest`: a normalização (com e sem transparência) e os ícones que vêm com a app.
    static func selfTest() -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ m: String) { if !ok { fails.append(m) } }
        func make(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> CGImage? {
            guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            draw(c); return c.makeImage()
        }
        func alpha(_ image: CGImage, _ x: Int, _ y: Int) -> Int {
            guard let c = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let d = { c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)); return c.data }() else { return -1 }
            return Int(d.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)[(y * image.width + x) * 4 + 3])
        }
        // fotografia (opaca, 400×300): quadrado de 824 ao centro, com cantos arredondados e margem transparente
        if let photo = make(400, 300, { $0.setFillColor(NSColor.systemOrange.cgColor); $0.fill(CGRect(x: 0, y: 0, width: 400, height: 300)) }),
           let icon = normalized(photo) {
            check(icon.width == 1024 && icon.height == 1024, "o ícone tem 1024×1024 (\(icon.width)×\(icon.height))")
            check(alpha(icon, 512, 512) == 255 && alpha(icon, 512, 110) == 255 && alpha(icon, 110, 512) == 255, "o corpo da fotografia enche o quadrado de 824")
            check(alpha(icon, 50, 512) == 0 && alpha(icon, 512, 50) == 0, "fica a margem transparente à volta")
            check(alpha(icon, 108, 108) == 0, "os cantos ficam arredondados (\(alpha(icon, 108, 108)))")
        } else { fails.append("não normalizou a fotografia") }
        // desenho com transparência (corpo pequeno e descentrado): o corpo é centrado e cresce até aos 824
        if let art = make(400, 400, { $0.setFillColor(NSColor.systemBlue.cgColor); $0.fill(CGRect(x: 40, y: 220, width: 100, height: 100)) }),
           let icon = normalized(art) {
            check(alpha(icon, 512, 512) == 255 && alpha(icon, 115, 115) == 255 && alpha(icon, 908, 908) == 255, "o corpo opaco ocupa o quadrado de 824, centrado")
            check(alpha(icon, 80, 512) == 0 && alpha(icon, 512, 944) == 0, "fora do corpo fica transparente")
        } else { fails.append("não normalizou o desenho com transparência") }
        for option in bundled {
            let size = shared.image(for: option.id)?.representations.first.map { ($0.pixelsWide, $0.pixelsHigh) }
            check(size.map { $0.0 == $0.1 && $0.0 >= 512 } ?? false, "o ícone «\(option.id)» vem com a app e é quadrado (\(String(describing: size)))")
        }
        return fails
    }

    /// `--normalize-icon <entrada> <saída.png> [lado]`: gera um ícone normalizado (para preparar os que vêm com a app).
    nonisolated static func normalizeFile(_ input: URL, to output: URL, side: Int) -> Bool {
        guard let src = NSImage(contentsOf: input)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { print("não foi possível ler a imagem"); return false }
        guard let icon = normalized(src, side: side), let data = png(icon) else { print("não foi possível normalizar"); return false }
        do { try data.write(to: output, options: .atomic); return true } catch { print("\(error.localizedDescription)"); return false }
    }
}

/// A escolha do ícone nas Preferências: os que vêm com a app, o personalizado (se existir) e «Escolher imagem…».
struct AppIconPicker: View {
    @ObservedObject var icons: AppIcon = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ForEach(AppIcon.bundled) { option in tile(option.id, option.title) }
                if icons.hasCustom { tile(AppIcon.custom, L("Personalizado")).id(icons.customRevision) }
            }
            HStack(spacing: 10) {
                Button(L("Escolher imagem…")) { choose() }
                Text(L("Qualquer imagem do computador; é ajustada ao formato dos ícones do macOS.")).font(.caption).foregroundStyle(.secondary)
            }
            Text(L("O ícone muda no Dock, no Finder e no Stage Manager, com o Toth aberto ou fechado. Depois de uma atualização, é reposto ao abrir o Toth."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tile(_ id: String, _ title: String) -> some View {
        let selected = icons.current == id
        return VStack(spacing: 3) {
            if let image = icons.image(for: id) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit().frame(width: 52, height: 52)
            }
            Text(title).font(.system(size: 10)).foregroundStyle(selected ? .primary : .secondary).lineLimit(1)
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Color.accentColor.opacity(0.16) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture { icons.select(id) }
        .help(title)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.prompt = L("Escolher")
        panel.message = L("Escolha a imagem a usar como ícone do Toth")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !icons.setCustom(from: url) { NSSound.beep() }
    }
}
