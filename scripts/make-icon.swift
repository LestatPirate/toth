// Copyright © 2026 Alex Felizardo. Licença MIT: ver LICENSE.
// Gera as imagens do ícone a partir do logótipo: `swift scripts/make-icon.swift TothLogo.png <pasta-de-saída.iconset> <logo-512.png>`
import AppKit

let args = CommandLine.arguments
guard args.count == 4, let logo = NSImage(contentsOfFile: args[1]) else { print("uso: make-icon <logo.png> <saida.iconset> <logo-512.png>"); exit(1) }

func render(_ size: Int, scale: CGFloat) -> Data {
    let px = Int(CGFloat(size) * scale)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    // margem do macOS: a arte ocupa ~80% da tela
    let inset = CGFloat(px) * 0.1
    logo.draw(in: NSRect(x: inset, y: inset, width: CGFloat(px) - 2 * inset, height: CGFloat(px) - 2 * inset), from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try? FileManager.default.createDirectory(atPath: args[2], withIntermediateDirectories: true)
for s in [16, 32, 128, 256, 512] {
    try! render(s, scale: 1).write(to: URL(fileURLWithPath: "\(args[2])/icon_\(s)x\(s).png"))
    try! render(s, scale: 2).write(to: URL(fileURLWithPath: "\(args[2])/icon_\(s)x\(s)@2x.png"))
}
// recurso usado dentro da app (sem margem: é desenhado em tamanhos pequenos)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 512, pixelsHigh: 512, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
logo.draw(in: NSRect(x: 0, y: 0, width: 512, height: 512), from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[3]))
print("ícone gerado")
