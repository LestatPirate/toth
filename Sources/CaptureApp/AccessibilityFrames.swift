// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit
import ApplicationServices

/// O elemento de interface sob um ponto, pela Acessibilidade do macOS (como o Snagit): botões, campos, painéis, imagens,
/// linhas de tabela, com o retângulo exato. Precisa da permissão de Acessibilidade (Definições do Sistema → Privacidade e
/// Segurança → Acessibilidade); sem ela, o seletor fica só com a deteção pelos píxeis.
enum AccessibilityFrames {
    /// A app tem a permissão de Acessibilidade?
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Pede a permissão (o macOS abre o diálogo e as Definições; a app tem de ser reaberta depois de autorizada).
    static func requestAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Retângulo (coordenadas globais do Core Graphics: origem no canto superior esquerdo do ecrã principal) do elemento da app
    /// `pid` que está no ponto `p` (mesmas coordenadas). Sobe aos pais até ter pelo menos `minSize` de lado. `nil` se a app
    /// não responder à Acessibilidade ou não houver permissão.
    static func elementFrame(pid: pid_t, at p: CGPoint, minSize: CGFloat = 12) -> CGRect? {
        guard isTrusted, pid > 0 else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.08)   // uma app a arrastar os pés não pode prender o rato
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(p.x), Float(p.y), &found) == .success, var el = found else { return nil }
        for _ in 0..<8 {
            if let f = frame(of: el), f.width >= minSize, f.height >= minSize, f.contains(p) { return f }
            guard let parent = attribute(el, kAXParentAttribute as String) else { return nil }
            el = parent as! AXUIElement
        }
        return nil
    }

    private static func attribute(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
    }

    static func frame(of el: AXUIElement) -> CGRect? {
        guard let pos = attribute(el, kAXPositionAttribute as String), let size = attribute(el, kAXSizeAttribute as String) else { return nil }
        var origin = CGPoint.zero, sz = CGSize.zero
        guard CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID(),
              AXValueGetValue(pos as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &sz) else { return nil }
        return CGRect(origin: origin, size: sz)
    }

    /// Papel e título do elemento (para diagnóstico: `--ax-check`).
    static func describe(pid: pid_t, at p: CGPoint) -> String {
        guard isTrusted else { return "sem permissão de Acessibilidade" }
        let app = AXUIElementCreateApplication(pid)
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(p.x), Float(p.y), &found) == .success, let el = found else { return "sem elemento" }
        let role = (attribute(el, kAXRoleAttribute as String) as? String) ?? "?"
        let title = (attribute(el, kAXTitleAttribute as String) as? String) ?? (attribute(el, kAXDescriptionAttribute as String) as? String) ?? ""
        return "\(role) «\(title)» \(frame(of: el).map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "sem retângulo")"
    }
}
