// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import SwiftUI
import AppKit
import CaptureCore

struct PropertiesPanel: View {
    @ObservedObject var model: EditorModel

    private func edit(_ f: (inout Style) -> Void) { var s = model.currentStyle; f(&s); model.setStyle(s) }

    // Linha
    private var lineColor: Binding<Color> {
        Binding(get: { Color(nsColor: NSColor(hex: model.currentStyle.colorHex)) }, set: { c in edit { $0.colorHex = NSColor(c).hexString } })
    }
    private var lineOn: Binding<Bool> {
        Binding(get: { model.currentStyle.lineVisible }, set: { v in edit { $0.lineVisible = v } })
    }
    private var width: Binding<Double> {
        Binding(get: { model.currentStyle.lineWidth }, set: { v in edit { $0.lineWidth = v } })
    }
    // Preenchimento
    private var fillOn: Binding<Bool> {
        Binding(get: { model.currentStyle.fillHex != nil }, set: { on in edit { $0.fillHex = on ? ($0.fillHex ?? "#FFFFFF") : nil } })
    }
    private var fill: Binding<Color> {
        Binding(get: { Color(nsColor: NSColor(hex: model.currentStyle.fillHex ?? "#FFFFFF")) }, set: { c in edit { $0.fillHex = NSColor(c).hexString } })
    }
    // Geral
    private var opacity: Binding<Double> {
        Binding(get: { model.currentStyle.opacity }, set: { v in edit { $0.opacity = v } })
    }
    private var shadow: Binding<Bool> {
        Binding(get: { model.currentStyle.shadow }, set: { v in edit { $0.shadow = v } })
    }
    // Texto
    private var fontSize: Binding<Double> { Binding(get: { model.currentFontSize }, set: { model.setFontSize($0) }) }
    private var fontName: Binding<String> {
        Binding(get: { model.currentStyle.text.fontName ?? "" }, set: { v in edit { $0.text.fontName = v.isEmpty ? nil : v } })
    }
    private var textColor: Binding<Color> {
        Binding(get: { Color(nsColor: RichText.textColor(model.currentStyle, legacyFallback: legacyText)) },
                set: { c in edit { $0.text.colorHex = NSColor(c).hexString } })
    }
    private var align: Binding<TextFormat.Align> { Binding(get: { model.currentStyle.text.align }, set: { v in edit { $0.text.align = v } }) }
    private var vAlign: Binding<TextFormat.VAlign> { Binding(get: { model.currentStyle.text.vAlign }, set: { v in edit { $0.text.vAlign = v } }) }
    private var list: Binding<TextFormat.ListStyle> { Binding(get: { model.currentStyle.text.list }, set: { v in edit { $0.text.list = v } }) }

    private var pixelSize: Binding<Double> { Binding(get: { model.currentPixelSize }, set: { model.setPixelSize($0) }) }
    private var blurIntensity: Binding<Double> { Binding(get: { model.currentBlurIntensity }, set: { model.setBlurIntensity($0) }) }
    private var isGaussian: Bool { if case .gaussian = model.selected?.shape { return true }; return model.selected == nil && model.tool == .gaussian }
    private var showArea: Bool { model.tool == .canvas || (model.selected == nil && model.tool == .select) }

    private var areaWidth: Binding<Double> {
        Binding(get: { model.doc.area.width.rounded() }, set: { model.setAreaSize(width: $0, height: model.doc.area.height) })
    }
    private var areaHeight: Binding<Double> {
        Binding(get: { model.doc.area.height.rounded() }, set: { model.setAreaSize(width: model.doc.area.width, height: $0) })
    }
    private var autoExpand: Binding<Bool> { Binding(get: { model.doc.autoExpand }, set: { model.setAutoExpand($0) }) }
    private var transparent: Binding<Bool> { Binding(get: { model.doc.transparentBackground }, set: { model.setTransparentBackground($0) }) }
    private var backgroundColor: Binding<Color> {
        Binding(get: { Color(nsColor: NSColor(hex: model.doc.backgroundHex)) }, set: { model.setBackground(hex: NSColor($0).hexString) })
    }

    private var areaSection: some View {
        section(L("Área de trabalho")) {
            row(L("Largura")) {
                TextField("", value: areaWidth, format: .number.grouping(.never)).frame(width: 70).multilineTextAlignment(.trailing)
                Text("px").font(.caption).foregroundStyle(.secondary)
            }
            row(L("Altura")) {
                TextField("", value: areaHeight, format: .number.grouping(.never)).frame(width: 70).multilineTextAlignment(.trailing)
                Text("px").font(.caption).foregroundStyle(.secondary)
            }
            Text(L("Arraste as alças (ferramenta Tela) ou escreva o tamanho. A imagem original nunca é alterada: aumentar a área acrescenta espaço, diminuir esconde o que fica de fora."))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            row(L("Fundo transparente")) { Toggle("", isOn: transparent).labelsHidden() }
            row(L("Cor de fundo")) { ColorPicker("", selection: backgroundColor).labelsHidden().disabled(model.doc.transparentBackground) }
            row(L("Expandir automaticamente")) { Toggle("", isOn: autoExpand).labelsHidden() }
            HStack {
                Button(L("Ajustar ao conteúdo")) { model.fitAreaToContent() }
                Button(L("Restaurar original")) { model.resetArea() }.disabled(model.doc.workArea == nil)
            }.controlSize(.small)
        }
    }

    private var isHighlight: Bool { if case .highlight = model.selected?.shape { return true }; return model.selected == nil && model.tool == .highlight }
    private var isPixelate: Bool { if case .blur = model.selected?.shape { return true }; return model.selected == nil && model.tool == .blur }

    // Etapa
    private var stepFormat: Binding<StepFormat> {
        Binding(get: { model.currentStyle.stepFormat }, set: { v in edit { $0.stepFormat = v } })
    }
    private var numberColor: Binding<Color> {
        Binding(get: { Color(nsColor: model.currentStyle.text.colorHex.map { NSColor(hex: $0) } ?? .white) },
                set: { c in edit { $0.text.colorHex = NSColor(c).hexString } })
    }
    private var stepRadius: Binding<Double> { Binding(get: { model.currentStepRadius }, set: { model.setStepRadius($0) }) }
    private var stepNumber: Binding<Int> {
        Binding(get: { model.selected?.shape.stepNumber ?? 0 }, set: { model.setStepNumber($0) })
    }
    private var nextStep: Binding<Int> {
        Binding(get: { model.doc.upcomingStepNumber }, set: { model.setNextStep($0) })
    }

    private func formatName(_ f: StepFormat) -> String {
        switch f {
        case .arabic: "1, 2, 3"; case .romanUpper: "I, II, III"; case .romanLower: "i, ii, iii"
        case .alphaUpper: "A, B, C"; case .alphaLower: "a, b, c"
        }
    }

    private var stepSection: some View {
        section(L("Etapa")) {
            row(L("Cor do círculo")) { ColorPicker("", selection: lineColor).labelsHidden() }
            row(L("Cor do número")) { ColorPicker("", selection: numberColor).labelsHidden() }
            slider(L("Tamanho"), value: stepRadius, range: Shape.stepRadiusLimits.lowerBound...100, format: "%.0f")
            Text(L("Arraste os cantos da etapa selecionada para a redimensionar (mantém a proporção).")).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            row(L("Fonte")) {
                Picker("", selection: fontName) {
                    Text(L("Sistema")).tag("")
                    ForEach(RichText.fontChoices, id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(maxWidth: 150)
            }
            row(L("Numeração")) {
                Picker("", selection: stepFormat) {
                    ForEach(StepFormat.allCases, id: \.self) { Text(formatName($0)).tag($0) }
                }.labelsHidden().frame(maxWidth: 150)
            }
            if model.selected != nil {
                Stepper(value: stepNumber, in: 0...9999) { Text(L("Número desta etapa: %d", stepNumber.wrappedValue)).font(.system(size: 12)) }
            }
            Stepper(value: nextStep, in: 0...9999) { Text(L("Próxima etapa: %@", model.currentStyle.stepFormat.label(nextStep.wrappedValue))).font(.system(size: 12)) }
            Button(L("Reiniciar sequência")) { model.restartSteps() }.controlSize(.small)
                .help(L("A próxima etapa volta a ser a número 1"))
        }
    }

    private var legacyText: Bool { if case .text = model.selected?.shape { return true } else { return false } }

        private enum Kind { case boxy, line, other }
    private var supportsBox: Bool {   // linha visível + preenchimento
        if let s = model.selected?.shape { switch s { case .rect, .ellipse, .callout, .textBox: return true; default: return false } }
        return [.rect, .ellipse, .callout, .text].contains(model.tool)
    }
    private var supportsText: Bool {
        if let a = model.selected { return a.editableString != nil }
        return model.tool == .text || model.tool == .callout || model.tool == .rect || model.tool == .ellipse
    }
    private var isStep: Bool { if case .step = model.selected?.shape { return true }; return model.selected == nil && model.tool == .step }
    private var hasLine: Bool {
        if let s = model.selected?.shape { switch s { case .text, .textBox, .blur, .highlight: return supportsBox; case .step, .gaussian, .image: return false; default: return true } }
        return ![Tool.text, .highlight, .blur, .gaussian, .step, .canvas].contains(model.tool)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("Propriedades")).font(.headline)
                Text(model.selected.map { L($0.shape.kindName) } ?? (model.tool == .canvas ? L("Área de trabalho") : L("Padrão para novos elementos")))
                    .font(.caption).foregroundStyle(.secondary)

                if showArea { areaSection }
                if hasLine {
                    section(L("Linha")) {
                        row(L("Cor")) {
                            if supportsBox { Toggle("", isOn: lineOn).labelsHidden() }
                            ColorPicker("", selection: lineColor).labelsHidden()
                                .disabled(supportsBox && !model.currentStyle.lineVisible)
                        }
                        slider(L("Espessura"), value: width, range: 1...24, format: "%.0f")
                            .disabled(supportsBox && !model.currentStyle.lineVisible)
                    }
                }
                if isStep { stepSection }
                if isHighlight {
                    section(L("Marcador")) { row(L("Cor")) { ColorPicker("", selection: lineColor).labelsHidden() } }
                }
                if isGaussian {
                    section(L("Blur")) { slider(L("Intensidade"), value: blurIntensity, range: 1...60, format: "%.0f") }
                }
                if isPixelate {
                    section(L("Pixelização")) { slider(L("Tamanho dos blocos"), value: pixelSize, range: 2...60, format: "%.0f") }
                }
                if supportsBox {
                    section(L("Preenchimento")) {
                        row(L("Cor")) {
                            Toggle("", isOn: fillOn).labelsHidden()
                            ColorPicker("", selection: fill).labelsHidden().disabled(model.currentStyle.fillHex == nil)
                        }
                    }
                }
                if supportsText { textSection }
                if !(model.tool == .canvas && model.selected == nil) { section(L("Geral")) {
                    slider(L("Opacidade"), value: opacity, range: 0.1...1, format: "%.0f%%", scale: 100)
                    row(L("Sombra")) { Toggle("", isOn: shadow).labelsHidden() }
                    if let sel = model.selected {
                        HStack {
                            Button(L("Trazer para frente")) { model.bringToFront(sel.id) }
                            Button(L("Enviar para trás")) { model.sendToBack(sel.id) }
                        }.controlSize(.small)
                    }
                } }

                Divider()
                Text(L("Camadas")).font(.headline)
                if model.doc.annotations.isEmpty {
                    Text(L("Sem elementos.")).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.doc.ordered.reversed()) { a in LayerRow(model: model, annotation: a) }
            }
            .padding(14)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var textSection: some View {
        section(L("Texto")) {
            row(L("Fonte")) {
                Picker("", selection: fontName) {
                    Text(L("Sistema")).tag("")
                    ForEach(RichText.fontChoices, id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(maxWidth: 150)
            }
            slider(L("Tamanho"), value: fontSize, range: 8...120, format: "%.0f")
            row(L("Estilo")) {
                HStack(spacing: 4) {
                    toggleButton("bold", on: model.currentStyle.text.bold, help: L("Negrito")) { v in edit { $0.text.bold = v } }
                    toggleButton("italic", on: model.currentStyle.text.italic, help: L("Itálico")) { v in edit { $0.text.italic = v } }
                    toggleButton("underline", on: model.currentStyle.text.underline, help: L("Sublinhado")) { v in edit { $0.text.underline = v } }
                }
            }
            row(L("Cor do texto")) { ColorPicker("", selection: textColor).labelsHidden() }
            row(L("Horizontal")) {
                Picker("", selection: align) {
                    Image(systemName: "text.alignleft").tag(TextFormat.Align.left)
                    Image(systemName: "text.aligncenter").tag(TextFormat.Align.center)
                    Image(systemName: "text.alignright").tag(TextFormat.Align.right)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 120)
            }
            row(L("Vertical")) {
                Picker("", selection: vAlign) {
                    Image(systemName: "align.vertical.top").tag(TextFormat.VAlign.top)
                    Image(systemName: "align.vertical.center").tag(TextFormat.VAlign.middle)
                    Image(systemName: "align.vertical.bottom").tag(TextFormat.VAlign.bottom)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 120)
            }
            row(L("Lista")) {
                Picker("", selection: list) {
                    Image(systemName: "text.alignleft").help(L("Sem lista")).tag(TextFormat.ListStyle.none)
                    Image(systemName: "list.bullet").help(L("Marcadores")).tag(TextFormat.ListStyle.bullet)
                    Image(systemName: "list.number").help(L("Numerada")).tag(TextFormat.ListStyle.numbered)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 120)
            }
        }
    }

    private func toggleButton(_ symbol: String, on: Bool, help: String, _ set: @escaping (Bool) -> Void) -> some View {
        Button { set(!on) } label: {
            Image(systemName: symbol).frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: 4).fill(on ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12)))
        }.buttonStyle(.plain).help(help)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            content()
        }
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack { Text(title).font(.system(size: 12)); Spacer(); content() }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String, scale: Double = 1) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(title).font(.system(size: 12)); Spacer()
                Text(String(format: format, value.wrappedValue * scale)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: value, in: range)
        }
    }
}

private struct LayerRow: View {
    @ObservedObject var model: EditorModel
    let annotation: Annotation

    private var title: String {
        if let s = annotation.editableString, !s.isEmpty { return L("%@: %@", L(annotation.shape.kindName), s) }
        if let n = annotation.shape.stepNumber { return L("Etapa %@", annotation.style.stepFormat.label(n)) }
        return L(annotation.shape.kindName)
    }

    var body: some View {
        HStack(spacing: 6) {
            Button { model.setVisible(annotation.id, !annotation.visible) } label: {
                Image(systemName: annotation.visible ? "eye" : "eye.slash")
            }.help(annotation.visible ? L("Ocultar") : L("Mostrar"))
            Text(title).lineLimit(1).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
            Button { model.delete(annotation.id) } label: { Image(systemName: "trash") }.help(L("Remover"))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(model.selection == annotation.id ? Color.accentColor.opacity(0.2) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { model.selection = annotation.id; model.tool = .select }
    }
}

extension NSColor {
    convenience init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt32(s.prefix(6), radix: 16) ?? 0xFF3B30
        self.init(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
}
