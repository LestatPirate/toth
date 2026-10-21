// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import SwiftUI
import AppKit

/// Dados do diálogo "Imagem em branco". Lembra o último tamanho e fundo usados.
final class NewImageForm: ObservableObject {
    static let limits = 16...16384
    static let maxPixels = 100_000_000
    static let presets: [(String, Int, Int)] = [("1280 × 800", 1280, 800), ("1920 × 1080", 1920, 1080), ("2560 × 1440", 2560, 1440),
                                                 ("1080 × 1080", 1080, 1080), ("800 × 600", 800, 600)]

    @Published var width: Int
    @Published var height: Int
    @Published var color: Color
    @Published var transparent: Bool
    @Published var message: String?

    init() {
        let d = UserDefaults.standard
        width = d.object(forKey: "newImage.width") as? Int ?? 1280
        height = d.object(forKey: "newImage.height") as? Int ?? 800
        color = Color(nsColor: NSColor(hex: d.string(forKey: "newImage.color") ?? "#FFFFFF"))
        transparent = d.bool(forKey: "newImage.transparent")
    }

    var colorHex: String { NSColor(color).hexString }

    /// Cria a imagem; devolve `true` se foi criada. Em caso de erro deixa a mensagem no diálogo.
    @MainActor func create(in state: AppState) -> Bool {
        if let error = state.createBlankImage(width: width, height: height, backgroundHex: colorHex, transparent: transparent) {
            message = error
            return false
        }
        let d = UserDefaults.standard
        d.set(width, forKey: "newImage.width"); d.set(height, forKey: "newImage.height")
        d.set(colorHex, forKey: "newImage.color"); d.set(transparent, forKey: "newImage.transparent")
        return true
    }
}

struct NewImageSheet: View {
    @ObservedObject var state: AppState
    @ObservedObject var localizer: Localizer = .shared
    @StateObject private var form = NewImageForm()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Nova imagem em branco")).font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 8) {
                Text(L("Tamanhos comuns")).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(NewImageForm.presets, id: \.0) { p in
                        Button(p.0) { form.width = p.1; form.height = p.2 }.controlSize(.small)
                    }
                }
            }

            HStack(spacing: 10) {
                Text(L("Largura")); TextField("", value: $form.width, format: .number.grouping(.never)).frame(width: 80).multilineTextAlignment(.trailing)
                Text("×")
                Text(L("Altura")); TextField("", value: $form.height, format: .number.grouping(.never)).frame(width: 80).multilineTextAlignment(.trailing)
                Text("px").foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Text(L("Cor de fundo"))
                ColorPicker("", selection: $form.color).labelsHidden().disabled(form.transparent)
                Toggle(L("Fundo transparente"), isOn: $form.transparent)
            }

            if let m = form.message {
                Label(m, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            } else {
                Text(L("Entre %d e %d pixels de lado (no máximo 100 milhões de pixels no total).", NewImageForm.limits.lowerBound, NewImageForm.limits.upperBound))
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button(L("Cancelar")) { state.showNewImage = false }.keyboardShortcut(.cancelAction)
                Button(L("Criar")) { if form.create(in: state) { state.showNewImage = false } }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}
