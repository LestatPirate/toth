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
    private var showArea: Bool { !model.isVideoOverlay && (model.tool == .canvas || (model.selected == nil && model.tool == .select)) }

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

    // Imagem (Tela → Imagem)
    private var canvasTarget: Binding<CanvasTarget> { Binding(get: { model.canvasTarget }, set: { model.canvasTarget = $0 }) }
    private var keepAspect: Binding<Bool> { Binding(get: { model.keepImageAspect }, set: { model.keepImageAspect = $0 }) }
    private var imageWidth: Binding<Double> { Binding(get: { model.imagePlacement.width.rounded() }, set: { model.setImageSize(width: $0) }) }
    private var imageHeight: Binding<Double> { Binding(get: { model.imagePlacement.height.rounded() }, set: { model.setImageSize(height: $0) }) }
    private var imageScale: Binding<Double> { Binding(get: { model.imageScale * 100 }, set: { model.setImageScale(max(1, $0) / 100) }) }
    private var imageRotation: Binding<Double> { Binding(get: { model.imageRotation }, set: { model.setImageRotation($0) }) }
    private var rotation: Binding<Double> { Binding(get: { model.currentRotation }, set: { model.setRotation($0) }) }
    private var textScales: Binding<Bool> { Binding(get: { model.textScalesWithBox }, set: { model.textScalesWithBox = $0 }) }

    private var imageSection: some View {
        section(L("Imagem")) {
            row(L("Largura")) {
                TextField("", value: imageWidth, format: .number.grouping(.never)).frame(width: 70).multilineTextAlignment(.trailing)
                Text("px").font(.caption).foregroundStyle(.secondary)
            }
            row(L("Altura")) {
                TextField("", value: imageHeight, format: .number.grouping(.never)).frame(width: 70).multilineTextAlignment(.trailing)
                Text("px").font(.caption).foregroundStyle(.secondary)
            }
            row(L("Manter proporção")) { Toggle("", isOn: keepAspect).labelsHidden() }
            row(L("Escala")) {
                TextField("", value: imageScale, format: .number.precision(.fractionLength(0))).frame(width: 60).multilineTextAlignment(.trailing)
                Text("%").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                ForEach([25, 50, 75, 100], id: \.self) { k in Button("\(k)%") { model.setImageScale(Double(k) / 100) } }
            }.controlSize(.small)
            rotationRow(imageRotation, rotate: { model.rotateImage(by: $0) })
            Text(L("Arraste a imagem para a mover, os cantos para a redimensionar (⇧ inverte «manter proporção»; os lados mudam só uma medida) e a alça redonda para a rodar. A imagem original nunca é alterada."))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(L("Restaurar original")) { model.resetImage() }.controlSize(.small).disabled(model.imageIsNatural)
        }
    }

    /// Rotação em graus: deslizador, campo e rodar 90° para cada lado.
    private func rotationRow(_ value: Binding<Double>, rotate: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L("Rotação")).font(.system(size: 12)); Spacer()
                TextField("", value: value, format: .number.precision(.fractionLength(0...1))).frame(width: 56).multilineTextAlignment(.trailing)
                Text("°").font(.caption).foregroundStyle(.secondary)
            }
            Slider(value: value, in: -180...180)
            HStack(spacing: 4) {
                Button { rotate(-90) } label: { Image(systemName: "rotate.left") }.help(L("Rodar 90° para a esquerda"))
                Button { rotate(90) } label: { Image(systemName: "rotate.right") }.help(L("Rodar 90° para a direita"))
                Button(L("Endireitar")) { value.wrappedValue = 0 }.disabled(value.wrappedValue == 0)
            }.controlSize(.small)
        }
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
            row(L("Ajustar sempre ao conteúdo")) { Toggle("", isOn: autoExpand).labelsHidden() }
                .help(L("A área cresce quando um elemento sai e encolhe quando volta ou é apagado. Mudar a área à mão desliga isto."))
            HStack {
                Button(L("Ajustar ao conteúdo")) { model.fitAreaToContent() }.disabled(model.doc.autoExpand)
                Button(L("Restaurar original")) { model.resetArea() }.disabled(model.doc.workArea == nil)
            }.controlSize(.small)
        }
    }

    private var isHighlight: Bool { if case .highlight = model.selected?.shape { return true }; return model.selected == nil && model.tool == .highlight }
    private var isStamp: Bool { if case .stamp = model.selected?.shape { return true }; return model.selected == nil && model.tool == .stamp }
    private var isRepair: Bool { if model.selected?.shape.isRepair == true { return true }; return model.selected == nil && model.tool == .repair }
    private var stampSize: Binding<Double> { Binding(get: { model.defaultStampSize }, set: { model.defaultStampSize = $0 }) }
    private var repairClones: Binding<Bool> { Binding(get: { model.currentRepairClones }, set: { model.setRepairClones($0) }) }
    @ObservedObject private var stamps = StampLibrary.shared

    /// Carimbos: símbolos (com a cor do estilo), emojis, um campo para outro emoji, e as imagens importadas.
    private var stampSection: some View {
        section(L("Carimbo")) {
            row(L("Cor")) { ColorPicker("", selection: lineColor).labelsHidden() }
            if model.selected == nil { slider(L("Tamanho"), value: stampSize, range: 16...512, format: "%.0f") }
            let cols = [GridItem(.adaptive(minimum: 30), spacing: 4)]
            LazyVGrid(columns: cols, spacing: 4) {
                ForEach(StampLibrary.symbols, id: \.self) { name in
                    stampCell(selected: model.currentStamp == StampLibrary.symbolKey(name)) {
                        let c = Color(nsColor: NSColor(hex: model.currentStyle.colorHex))
                        if StampLibrary.isBadge(name) { Image(systemName: name).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white, c) }
                        else { Image(systemName: name).font(.system(size: 16, weight: .semibold)).foregroundStyle(c) }
                    }
                        .onTapGesture { model.chooseStamp(StampLibrary.symbolKey(name)) }
                }
            }
            LazyVGrid(columns: cols, spacing: 4) {
                ForEach(StampLibrary.emojis, id: \.self) { e in
                    stampCell(selected: model.currentStamp == e) { Text(e).font(.system(size: 17)) }.onTapGesture { model.chooseStamp(e) }
                }
            }
            row(L("Outro emoji ou texto")) {
                TextField("", text: Binding(get: { StampLibrary.isSymbol(model.currentStamp) ? "" : model.currentStamp }, set: { if !$0.isEmpty { model.chooseStamp(String($0.prefix(8))) } })).frame(width: 90)
            }
            Text(L("Clique na imagem para pôr o carimbo (arraste para escolher o tamanho). As imagens importadas entram como imagem.")).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !stamps.images.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 4)], spacing: 4) {
                    ForEach(stamps.images, id: \.self) { url in
                        stampCell(selected: false) { if let img = NSImage(contentsOf: url) { Image(nsImage: img).resizable().scaledToFit().padding(3) } }
                            .frame(height: 44)
                            .onTapGesture { model.addImageStamp(url, at: model.visibleCenter) }
                            .contextMenu { Button(L("Remover da biblioteca de carimbos")) { stamps.remove(url) } }
                            .help(url.deletingPathExtension().lastPathComponent)
                    }
                }
            }
            Button(L("Importar imagens…")) { importStamps() }.controlSize(.small)
        }
    }

    private func stampCell<C: View>(selected: Bool, @ViewBuilder _ content: () -> C) -> some View {
        content().frame(width: 30, height: 30).frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.1)))
            .contentShape(Rectangle())
    }

    private func importStamps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = true
        panel.message = L("Escolha imagens para usar como carimbos (PNG, JPEG, HEIC, SVG…)")
        guard panel.runModal() == .OK else { return }
        let failed = stamps.importImages(panel.urls)
        if !failed.isEmpty { AppState.shared.errorMessage = L("Não foi possível importar: %@", failed.joined(separator: ", ")) }
    }

    /// Alinhar (entre si, ou à área se for só um), distribuir e agrupar.
    private var arrangeSection: some View {
        section(model.isMultiSelection ? L("Disposição") : L("Disposição (à área de trabalho)")) {
            HStack(spacing: 3) {
                arrangeButton("align.horizontal.left", L("Alinhar à esquerda")) { model.alignSelection(.left) }
                arrangeButton("align.horizontal.center", L("Alinhar ao centro")) { model.alignSelection(.centerX) }
                arrangeButton("align.horizontal.right", L("Alinhar à direita")) { model.alignSelection(.right) }
                Divider().frame(height: 16)
                arrangeButton("align.vertical.top", L("Alinhar ao topo")) { model.alignSelection(.top) }
                arrangeButton("align.vertical.center", L("Alinhar ao meio")) { model.alignSelection(.centerY) }
                arrangeButton("align.vertical.bottom", L("Alinhar à base")) { model.alignSelection(.bottom) }
            }
            HStack(spacing: 3) {
                arrangeButton("distribute.horizontal.center", L("Distribuir na horizontal (3 ou mais)")) { model.distributeSelection(horizontal: true) }.disabled(model.selectedIDs.count < 3)
                arrangeButton("distribute.vertical.center", L("Distribuir na vertical (3 ou mais)")) { model.distributeSelection(horizontal: false) }.disabled(model.selectedIDs.count < 3)
                Divider().frame(height: 16)
                Button(L("Agrupar")) { model.groupSelection() }.disabled(!model.canGroup).help(L("Juntar num grupo: clicar num membro seleciona todos (⌘G)"))
                Button(L("Desagrupar")) { model.ungroupSelection() }.disabled(!model.canUngroup).help(L("Separar o grupo (⇧⌘G)"))
            }.controlSize(.small)
            if model.isMultiSelection {
                Text(L("Arraste um canto da caixa do grupo para o redimensionar em proporção, ou a alça redonda para o rodar todo.")).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func arrangeButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 24, height: 20).background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12))) }
            .buttonStyle(.plain).help(help)
    }

    private var isImageObject: Bool { if case .image = model.selected?.shape { return true }; return false }
    private var objectAspect: Binding<Bool> { Binding(get: { model.keepObjectAspect }, set: { model.keepObjectAspect = $0 }) }
    private var objWidth: Binding<Double> { Binding(get: { (model.selected?.shape.bounds.width ?? 0).rounded() }, set: { model.setImageObjectSize(width: $0) }) }
    private var objHeight: Binding<Double> { Binding(get: { (model.selected?.shape.bounds.height ?? 0).rounded() }, set: { model.setImageObjectSize(height: $0) }) }

    /// Imagem colada: tamanho, proporção e voltar ao tamanho real.
    private var imageObjectSection: some View {
        section(L("Imagem colada")) {
            row(L("Largura")) {
                TextField("", value: objWidth, format: .number.grouping(.never)).frame(width: 70).multilineTextAlignment(.trailing)
                Text("px").font(.caption).foregroundStyle(.secondary)
            }
            row(L("Altura")) {
                TextField("", value: objHeight, format: .number.grouping(.never)).frame(width: 70).multilineTextAlignment(.trailing)
                Text("px").font(.caption).foregroundStyle(.secondary)
            }
            row(L("Redimensionar em proporção")) { Toggle("", isOn: objectAspect).labelsHidden() }
            Text(L("Marcado: os cantos mantêm a proporção (⇧ liberta). As imagens coladas entram ao tamanho real.")).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let px = model.selectedImagePixelSize {
                Button(L("Tamanho real (%@)", "\(Int(px.width)) × \(Int(px.height))")) { model.resetImageObjectSize() }.controlSize(.small)
                    .disabled(abs((model.selected?.shape.bounds.width ?? 0) - px.width) < 0.5 && abs((model.selected?.shape.bounds.height ?? 0) - px.height) < 0.5)
            }
        }
    }

    private var areaMode: Binding<EditorModel.AreaMode> { Binding(get: { model.areaMode }, set: { model.areaMode = $0 }) }
    private var areaCombineMode: Binding<AreaMask.Combine> { Binding(get: { model.areaCombineMode }, set: { model.areaCombineMode = $0 }) }
    private var wandTolerance: Binding<Double> { Binding(get: { model.wandTolerance }, set: { model.wandTolerance = $0 }) }
    private var wandContiguous: Binding<Bool> { Binding(get: { model.wandContiguous }, set: { model.wandContiguous = $0 }) }

    /// Selecionar área: forma, varinha e o que fazer com a seleção.
    private var selectAreaSection: some View {
        section(L("Selecionar área")) {
            Picker("", selection: areaMode) {
                Image(systemName: "rectangle.dashed").tag(EditorModel.AreaMode.rect)
                Image(systemName: "circle.dashed").tag(EditorModel.AreaMode.ellipse)
                Image(systemName: "wand.and.stars").tag(EditorModel.AreaMode.wand)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
            // como a próxima seleção se combina com a que existe (como no Pixelmator)
            Picker("", selection: areaCombineMode) {
                Text(L("Nova")).tag(AreaMask.Combine.replace)
                Text(L("Juntar")).tag(AreaMask.Combine.add)
                Text(L("Tirar")).tag(AreaMask.Combine.subtract)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 190)
                .help(L("Nova: substitui a seleção. Juntar: acrescenta-lhe. Tirar: retira-lhe. (⇧ junta e ⌥ tira em qualquer modo.)"))
            if model.areaMode == .wand {
                slider(L("Tolerância"), value: wandTolerance, range: 0...128, format: "%.0f")
                row(L("Só píxeis contíguos")) { Toggle("", isOn: wandContiguous).labelsHidden() }
            }
            Text(model.areaMode == .wand
                 ? L("Clique numa cor para selecionar os píxeis parecidos; arraste para ir apanhando mais zonas. ⇧ junta, ⌥ tira.")
                 : L("Arraste para selecionar (⇧ junta, ⌥ tira). Depois: arraste de dentro para a mover como objeto, ou use os botões. Esc limpa."))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let sel = model.areaSelection, !sel.isEmpty {
                Text(L("%d × %d px", sel.width, sel.height)).font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Button(L("Levantar como objeto (↩)")) { model.liftSelection(erase: true) }.help(L("Os píxeis passam a ser um objeto que se move, copia, roda e redimensiona; o sítio de onde saíram fica apagado"))
                    Button(L("Duplicar como objeto (⌘D)")) { model.liftSelection(erase: false) }.help(L("Uma cópia dos píxeis como objeto, deixando o original no sítio"))
                    Button(L("Copiar píxeis (⌘C)")) { model.copySelectionPixels() }
                    Button(L("Apagar (Delete)")) { model.eraseSelection() }.help(L("Passa a cor de fundo (ou transparente)"))
                    Button(L("Preencher (Reparo)")) { model.fillSelection() }.help(L("Preenche a partir do que a rodeia"))
                }.controlSize(.small)
            }
        }
    }

    /// Texto da imagem: o que foi reconhecido e o que fazer com ele.
    private var ocrSection: some View {
        section(L("Texto da imagem")) {
            if model.recognizing {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(L("A reconhecer o texto…")).font(.caption).foregroundStyle(.secondary) }
            } else if let e = model.recognitionError {
                Text(e).font(.caption).foregroundStyle(.red)
            } else if model.textBlocks.isEmpty {
                Text(L("Não foi encontrado texto na imagem.")).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(model.selectedBlocks.isEmpty ? L("%d linhas de texto", model.textBlocks.count) : L("%d de %d linhas marcadas", model.selectedBlocks.count, model.textBlocks.count))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(L("Clique numa linha para a marcar (⇧ junta várias); ⌘C copia o texto marcado. Duplo clique numa linha torna-a editável: o original é apagado com um Reparo e fica uma caixa de Texto com as mesmas palavras, tamanho, cor e peso."))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Button(L("Copiar todo o texto")) { model.copyRecognizedText(all: true) }.disabled(model.textBlocks.isEmpty)
                Button(L("Copiar linhas marcadas (⌘C)")) { model.copyRecognizedText() }.disabled(model.selectedBlocks.isEmpty)
                Button(L("Editar linha marcada")) {
                    if let id = model.selectedBlocks.first, model.selectedBlocks.count == 1, model.editTextBlock(id) != nil { CanvasView.current?.editSelectedText() }
                }.disabled(model.selectedBlocks.count != 1)
                Button(L("Reconhecer de novo")) { model.recognizeText() }.disabled(model.recognizing)
            }.controlSize(.small)
            Text(L("Reconhecimento feito no seu Mac (Vision), em português e inglês. Nada sai do computador."))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var repairSection: some View {
        section(L("Reparo")) {
            Picker("", selection: repairClones) {
                Text(L("Preencher")).tag(false)
                Text(L("Clonar")).tag(true)
            }.pickerStyle(.segmented).labelsHidden()
            Text(model.currentRepairClones
                 ? L("A região é coberta com o que está por baixo noutro sítio: arraste a alça verde (a origem) para escolher de onde copiar.")
                 : L("A região é preenchida a partir do que a rodeia (apaga o que lá está). Funciona melhor em fundos lisos ou com gradientes."))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
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
        if let s = model.selected?.shape { switch s { case .text, .textBox, .blur, .highlight: return supportsBox; case .step, .gaussian, .image, .stamp, .patch, .clone, .erase: return false; default: return true } }
        return ![Tool.text, .highlight, .blur, .gaussian, .step, .canvas, .stamp, .repair, .area, .ocr].contains(model.tool)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("Propriedades")).font(.headline)
                Text(model.selected.map { L($0.shape.kindName) } ?? (model.tool == .canvas ? L("Área de trabalho") : L("Padrão para novos elementos")))
                    .font(.caption).foregroundStyle(.secondary)

                if model.tool == .canvas {
                    Picker("", selection: canvasTarget) {
                        Text(L("Área de trabalho")).tag(CanvasTarget.area)
                        Text(L("Imagem")).tag(CanvasTarget.image)
                    }.pickerStyle(.segmented).labelsHidden()
                }
                if showArea && !(model.tool == .canvas && model.canvasTarget == .image) { areaSection }
                if model.tool == .canvas && model.canvasTarget == .image { imageSection }
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
                if model.tool == .area && model.selected == nil { selectAreaSection }
                if model.tool == .ocr && model.selected == nil { ocrSection }
                if isStep { stepSection }
                if isImageObject { imageObjectSection }
                if isStamp { stampSection }
                if isRepair { repairSection }
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
                if !((model.tool == .canvas || model.tool == .area || model.tool == .ocr) && model.selected == nil) { section(L("Geral")) {
                    slider(L("Opacidade"), value: opacity, range: 0.1...1, format: "%.0f%%", scale: 100)
                    row(L("Sombra")) { Toggle("", isOn: shadow).labelsHidden() }
                    if let sel = model.selected {
                        rotationRow(rotation, rotate: { model.rotateSelection(by: $0) })
                        Text(L("Arraste a alça redonda acima do elemento para o rodar (encosta aos 15°; ⌥ liberta).")).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button(L("Trazer para frente")) { model.bringToFront(sel.id) }
                            Button(L("Enviar para trás")) { model.sendToBack(sel.id) }
                        }.controlSize(.small)
                    }
                } }
                if model.selected != nil { arrangeSection }

                Divider()
                Text(L("Camadas")).font(.headline)
                if model.doc.annotations.isEmpty {
                    Text(L("Sem elementos.")).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.doc.ordered.filter { model.isShown($0) }.reversed()) { a in LayerRow(model: model, annotation: a) }
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
            slider(L("Tamanho"), value: fontSize, range: 8...400, format: "%.0f")
            row(L("Redimensionar em proporção")) { Toggle("", isOn: textScales).labelsHidden() }
            Text(L("Marcado: ao redimensionar o objeto, a letra acompanha. Desmarcado: só a caixa muda e o texto quebra de linha (sem hifenização)."))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
        .onTapGesture { model.selectWithGroup(annotation.id); model.tool = .select }
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
