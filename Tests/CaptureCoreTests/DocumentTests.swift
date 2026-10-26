// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import Foundation
import Testing
@testable import CaptureCore

private func tmp() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).capture")
}

@Test func removeAnnotationSurvivesSaveAndReopen() throws {
    var doc = CaptureDocument(canvasWidth: 100, canvasHeight: 50)
    let arrow = doc.add(.arrow(from: Point(x: 0, y: 0), to: Point(x: 10, y: 10)))
    let text = doc.add(.text(origin: Point(x: 5, y: 5), string: "oi", fontSize: 14))
    let url = tmp(); defer { try? FileManager.default.removeItem(at: url) }
    try CapturePackage.write(doc, originalImage: Data([1, 2, 3]), to: url)

    var reopened = try CapturePackage.read(from: url)
    #expect(reopened.ordered.map(\.id) == [arrow.id, text.id])
    #expect(reopened.remove(id: arrow.id) != nil)
    try CapturePackage.write(reopened, originalImage: Data([9, 9, 9]), to: url)

    let final = try CapturePackage.read(from: url)
    #expect(final.ordered.map(\.id) == [text.id])
    let original = try CaptureContainer(url: url).data(CapturePackage.originalFile)
    #expect(original == Data([1, 2, 3]))  // original permanece intacto
}

@Test func undoByReinsert() {
    var doc = CaptureDocument(canvasWidth: 10, canvasHeight: 10)
    let a = doc.add(.rect(origin: Point(x: 0, y: 0), width: 1, height: 1))
    let removed = doc.remove(id: a.id)!
    #expect(doc.ordered.isEmpty)
    doc.insert(removed)
    #expect(doc.ordered == [a])
}

@Test func rejectsNewerFormat() throws {
    var doc = CaptureDocument(canvasWidth: 1, canvasHeight: 1)
    doc.formatVersion = 99
    let url = tmp(); defer { try? FileManager.default.removeItem(at: url) }
    try CapturePackage.write(doc, originalImage: nil, to: url)
    #expect(throws: (any Error).self) { try CapturePackage.read(from: url) }
}

@Test func hitTestAndMove() {
    var doc = CaptureDocument(canvasWidth: 100, canvasHeight: 100)
    let line = doc.add(.line(from: Point(x: 0, y: 0), to: Point(x: 100, y: 0)))
    let box = doc.add(.rect(origin: Point(x: 20, y: 20), width: 10, height: 10))
    #expect(doc.topmost(at: Point(x: 50, y: 2), tolerance: 4)?.id == line.id)
    #expect(doc.topmost(at: Point(x: 25, y: 25), tolerance: 4)?.id == box.id)
    #expect(doc.topmost(at: Point(x: 80, y: 80), tolerance: 4) == nil)
    let moved = box.shape.translated(dx: 50, dy: 0)
    #expect(moved.bounds.minX == 70)
}

@Test func resizeByHandle() {
    let rect = Shape.rect(origin: Point(x: 10, y: 10), width: 20, height: 20)
    #expect(rect.handle(at: Point(x: 30, y: 30), tolerance: 2) == 2)
    // arrastar o canto inferior direito mantém o superior esquerdo fixo
    #expect(rect.movingHandle(2, to: Point(x: 50, y: 40)) == .rect(origin: Point(x: 10, y: 10), width: 40, height: 30))
    // arrastar para além do canto oposto normaliza
    #expect(rect.movingHandle(2, to: Point(x: 0, y: 0)) == .rect(origin: Point(x: 0, y: 0), width: 10, height: 10))
    let arrow = Shape.arrow(from: Point(x: 0, y: 0), to: Point(x: 5, y: 5))
    #expect(arrow.movingHandle(1, to: Point(x: 9, y: 9)) == .arrow(from: Point(x: 0, y: 0), to: Point(x: 9, y: 9)))
}

@Test func calloutHandlesAndTail() {
    let c = Shape.callout(origin: Point(x: 10, y: 10), width: 100, height: 40, tail: Point(x: 30, y: 90), string: "oi", fontSize: 20)
    #expect(c.handles.count == 5)
    #expect(c.bounds.maxY == 90)                       // inclui o ponteiro
    #expect(c.movingHandle(4, to: Point(x: 5, y: 120)).bounds.maxY == 120)
    let resized = c.movingHandle(2, to: Point(x: 200, y: 80))  // canto inferior direito
    #expect(resized.calloutBox == Rect(x: 10, y: 10, width: 190, height: 70))
    #expect(c.hits(Point(x: 40, y: 70), tolerance: 3))  // sobre o ponteiro
}

@Test func layerOrderAndVisibility() {
    var doc = CaptureDocument(canvasWidth: 10, canvasHeight: 10)
    let a = doc.add(.rect(origin: Point(x: 0, y: 0), width: 5, height: 5))
    let b = doc.add(.rect(origin: Point(x: 0, y: 0), width: 5, height: 5))
    doc.bringToFront(id: a.id)
    #expect(doc.ordered.map(\.id) == [b.id, a.id])
    doc.sendToBack(id: a.id)
    #expect(doc.ordered.map(\.id) == [a.id, b.id])
    doc.setVisible(id: b.id, false)
    #expect(doc.topmost(at: Point(x: 1, y: 1), tolerance: 1)?.id == a.id)
}

@Test func oldStyleWithoutNewFieldsStillDecodes() throws {
    let json = ##"{"colorHex":"#FF0000","lineWidth":3,"shadow":true}"##.data(using: .utf8)!
    let s = try JSONDecoder().decode(Style.self, from: json)
    #expect(s.opacity == 1 && s.fillHex == nil)
}

@Test func textBoxBehavesLikeBoxAndKeepsFormat() throws {
    let t = Shape.textBox(origin: Point(x: 0, y: 0), width: 100, height: 40, string: "a", fontSize: 20)
    #expect(t.handles.count == 4)
    #expect(t.movingHandle(2, to: Point(x: 150, y: 60)).bounds == Rect(x: 0, y: 0, width: 150, height: 60))
    #expect(t.with(string: "b").string == "b")

    var style = Style()
    style.lineVisible = false
    style.text = TextFormat(fontName: "Georgia", bold: true, align: .center, vAlign: .middle, list: .numbered)
    var doc = CaptureDocument(canvasWidth: 10, canvasHeight: 10)
    doc.add(t, style: style)
    let back = try JSONDecoder().decode(CaptureDocument.self, from: JSONEncoder().encode(doc))
    #expect(back.annotations[0].style.text.list == .numbered)
    #expect(back.annotations[0].style.text.vAlign == .middle)
    #expect(back.annotations[0].style.lineVisible == false)
}

@Test func pixelSizeAndNames() {
    let b = Shape.blur(origin: Point(x: 0, y: 0), width: 10, height: 10, radius: 12)
    #expect(b.pixelSize == 12)
    #expect(b.with(pixelSize: 30).pixelSize == 30)
    #expect(Shape.rect(origin: Point(x: 0, y: 0), width: 1, height: 1).pixelSize == nil)
    #expect(b.kindName == "Pixelização")
    #expect(Shape.highlight(origin: Point(x: 0, y: 0), width: 1, height: 1).kindName == "Marcador")
    #expect(Shape.callout(origin: Point(x: 0, y: 0), width: 1, height: 1, tail: Point(x: 0, y: 5), string: "", fontSize: 10).kindName == "Balão")
}

@Test func stepFormats() {
    #expect(StepFormat.arabic.label(7) == "7")
    #expect(StepFormat.romanUpper.label(4) == "IV")
    #expect(StepFormat.romanUpper.label(1994) == "MCMXCIV")
    #expect(StepFormat.romanLower.label(9) == "ix")
    #expect(StepFormat.alphaUpper.label(1) == "A")
    #expect(StepFormat.alphaUpper.label(27) == "AA")
    #expect(StepFormat.alphaLower.label(26) == "z")
}

@Test func stepSequenceAndRestart() throws {
    var doc = CaptureDocument(canvasWidth: 10, canvasHeight: 10)
    #expect(doc.upcomingStepNumber == 1)
    doc.add(.step(center: Point(x: 1, y: 1), number: doc.upcomingStepNumber))
    doc.add(.step(center: Point(x: 2, y: 2), number: doc.upcomingStepNumber))
    #expect(doc.upcomingStepNumber == 3)
    doc.nextStepNumber = 1          // reiniciar sequência
    #expect(doc.upcomingStepNumber == 1)
    let back = try JSONDecoder().decode(CaptureDocument.self, from: JSONEncoder().encode(doc))
    #expect(back.upcomingStepNumber == 1)    // o reinício sobrevive a guardar/reabrir
}

@Test func rectAndEllipseCarryCaption() throws {
    var doc = CaptureDocument(canvasWidth: 10, canvasHeight: 10)
    var a = doc.add(.rect(origin: Point(x: 0, y: 0), width: 10, height: 10))
    #expect(a.editableString == "")
    a.setEditableString("dentro")
    doc.update(a)
    let back = try JSONDecoder().decode(CaptureDocument.self, from: JSONEncoder().encode(doc))
    #expect(back.annotations[0].editableString == "dentro")
    #expect(Annotation(z: 0, shape: .arrow(from: Point(x: 0, y: 0), to: Point(x: 1, y: 1))).editableString == nil)
}


@Test func areaExpandsAndShrinksWithoutTouchingImage() throws {
    var doc = CaptureDocument(canvasWidth: 100, canvasHeight: 50)
    #expect(doc.area == Rect(x: 0, y: 0, width: 100, height: 50))
    // objeto dentro: nada muda
    let inside = doc.add(.rect(origin: Point(x: 10, y: 10), width: 20, height: 20), style: Style(lineWidth: 2, lineVisible: false))
    #expect(doc.expandAreaToFit(ids: [inside.id]) == false)
    // objeto sai pela direita e por baixo: a área cresce, com origem inalterada
    let out = doc.add(.rect(origin: Point(x: 90, y: 40), width: 40, height: 30), style: Style(lineWidth: 4))
    #expect(doc.expandAreaToFit(ids: [out.id]) == true)
    #expect(doc.area == Rect(x: 0, y: 0, width: 132, height: 72))      // 90+40+2 e 40+30+2 (meia linha)
    // objeto sai pela esquerda/cima: origem negativa
    let arrow = doc.add(.arrow(from: Point(x: -20, y: -10), to: Point(x: 5, y: 5)), style: Style(lineWidth: 2))
    doc.expandAreaToFit(ids: [arrow.id])
    #expect(doc.area.minX == -21 && doc.area.minY == -11)
    // a área não encolhe sozinha
    doc.remove(id: out.id)
    doc.expandAreaToFit(ids: [arrow.id])
    #expect(doc.area.maxX == 132)
    // encolhida de propósito, mexer noutro objeto NÃO reabre a área por causa dos que ficaram de fora
    doc.workArea = WorkArea(origin: Point(x: 0, y: 0), width: 60, height: 40)
    doc.expandAreaToFit(ids: [inside.id])
    #expect(doc.area == Rect(x: 0, y: 0, width: 60, height: 40))
    // sem autoExpand também não cresce
    doc.autoExpand = false
    let far = doc.add(.rect(origin: Point(x: 500, y: 500), width: 5, height: 5))
    #expect(doc.expandAreaToFit(ids: [far.id]) == false)
    // ajustar ao conteúdo e restaurar
    doc.fitAreaToContent()
    #expect(doc.area.maxX >= 505 && doc.area.minX <= -20)
    #expect(doc.imageRect == Rect(x: 0, y: 0, width: 100, height: 50))   // a imagem original nunca muda
    doc.workArea = nil
    #expect(doc.area == doc.imageRect)
}

@Test func legacyCropDecodesAsWorkArea() throws {
    let json = ##"{"formatVersion":1,"canvasWidth":100,"canvasHeight":50,"crop":{"origin":{"x":10,"y":5},"width":40,"height":20},"annotations":[]}"##.data(using: .utf8)!
    let doc = try JSONDecoder().decode(CaptureDocument.self, from: json)
    #expect(doc.area == Rect(x: 10, y: 5, width: 40, height: 20))
    #expect(doc.autoExpand == true && doc.transparentBackground == false)
}

@Test func gaussianAndImageShapes() {
    let g = Shape.gaussian(origin: Point(x: 0, y: 0), width: 10, height: 10, intensity: 8)
    #expect(g.blurIntensity == 8 && g.with(blurIntensity: 20).blurIntensity == 20)
    #expect(g.handles.count == 4 && g.kindName == "Blur")
    let img = Shape.image(origin: Point(x: 0, y: 0), width: 10, height: 10, asset: "a.png")
    #expect(img.imageAsset == "a.png")
    #expect(img.movingHandle(2, to: Point(x: 30, y: 20)).bounds == Rect(x: 0, y: 0, width: 30, height: 20))
}

@Test func insertCopyGetsNewIdAndOffset() {
    var doc = CaptureDocument(canvasWidth: 10, canvasHeight: 10)
    let a = doc.add(.rect(origin: Point(x: 1, y: 1), width: 5, height: 5))
    let c = doc.insertCopy(of: a, dx: 20, dy: 20)
    #expect(c.id != a.id && c.z > a.z && c.shape.bounds.minX == 21)
    #expect(doc.annotations.count == 2)
}


// MARK: - Arquivo .capture (ZIP) e compatibilidade com pastas antigas

@Test func zipRoundTripAndStandardCompliance() throws {
    let entries: [String: Data] = ["document.json": Data("{}".utf8), "assets/original.png": Data((0..<5000).map { UInt8($0 % 251) }), "vazio.bin": Data()]
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("z-\(UUID().uuidString).capture")
    defer { try? FileManager.default.removeItem(at: url) }
    try ZipArchive.make(entries).write(to: url)
    #expect(try ZipArchive.readAll(at: url) == entries)
    #expect(ZipArchive.readEntry("assets/original.png", at: url) == entries["assets/original.png"])
    #expect(ZipArchive.readEntry("nao-existe", at: url) == nil)
    // CRC de referência (valor conhecido de "123456789")
    #expect(ZipArchive.crc32(Data("123456789".utf8)) == 0xCBF43926)
}

@Test func zipDetectsCorruptionAndNonZip() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("c-\(UUID().uuidString).capture")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("isto não é um zip".utf8).write(to: url)
    #expect(throws: ZipArchive.Failure.self) { try ZipArchive.readAll(at: url) }
    // um byte alterado nos dados: o CRC apanha
    var bytes = try ZipArchive.make(["a.bin": Data([1, 2, 3, 4, 5, 6, 7, 8])])
    bytes[bytes.startIndex + 31 + 5] ^= 0xFF
    try bytes.write(to: url)
    #expect(throws: ZipArchive.Failure.self) { try ZipArchive.readAll(at: url) }
}

@Test func newCapturesAreArchivesAndSurviveEditing() throws {
    var doc = CaptureDocument(canvasWidth: 10, canvasHeight: 10)
    let a = doc.add(.rect(origin: Point(x: 0, y: 0), width: 5, height: 5))
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("n-\(UUID().uuidString).capture")
    defer { try? FileManager.default.removeItem(at: url) }
    try CapturePackage.write(doc, originalImage: Data([7, 7, 7]), to: url)

    var isDir: ObjCBool = true
    #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue)   // ficheiro único
    let c = try CaptureContainer(url: url)
    #expect(c.kind == .archive && c.data(CapturePackage.originalFile) == Data([7, 7, 7]))

    var d2 = try CapturePackage.read(from: c)
    d2.remove(id: a.id)
    try c.write("assets/colada.png", Data([9]))
    try CapturePackage.save(d2, originalImage: Data([0, 0, 0]), to: c)          // não sobrescreve o original
    let again = try CaptureContainer(url: url)
    #expect(try CapturePackage.read(from: again).annotations.isEmpty)
    #expect(again.data(CapturePackage.originalFile) == Data([7, 7, 7]))
    #expect(again.data("assets/colada.png") == Data([9]))
}

@Test func oldFolderCapturesStillOpenAndCanBeArchived() throws {
    var doc = CaptureDocument(canvasWidth: 10, canvasHeight: 10)
    doc.add(.rect(origin: Point(x: 0, y: 0), width: 5, height: 5))
    let tmp = FileManager.default.temporaryDirectory
    let folder = tmp.appendingPathComponent("f-\(UUID().uuidString).capture")
    let archive = tmp.appendingPathComponent("a-\(UUID().uuidString).capture")
    defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: archive) }
    // pasta antiga (formato anterior)
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("assets"), withIntermediateDirectories: true)
    try CapturePackage.encode(doc).write(to: folder.appendingPathComponent("document.json"))
    try Data([1, 2, 3]).write(to: folder.appendingPathComponent("assets/original.png"))
    try Data([4]).write(to: folder.appendingPathComponent("preview.png"))

    #expect(CaptureContainer.isFolderCapture(folder))
    #expect(try CapturePackage.read(from: folder).annotations.count == 1)       // continua a abrir
    try CaptureContainer.archive(folder: folder, to: archive)                    // compactar (com verificação)
    let c = try CaptureContainer(url: archive)
    #expect(c.kind == .archive && !CaptureContainer.isFolderCapture(archive))
    #expect(c.paths == ["assets/original.png", "document.json", "preview.png"])
    #expect(try CapturePackage.read(from: c).annotations.count == 1)
    #expect(CaptureContainer.readEntry("preview.png", at: archive) == Data([4]))
    #expect(CaptureContainer.readEntry("preview.png", at: folder) == Data([4]))
}

// MARK: - Atalho de teclado

@Test func shortcutDisplayAndDefault() {
    #expect(Shortcut.default.display == "⌃⇧4")
    #expect(Shortcut(keyCode: 8, modifiers: [.command, .option, .shift, .control], keyLabel: "C").display == "⌃⌥⇧⌘C")
    #expect(Shortcut.default.problem == nil)
    #expect(Shortcut.specialLabel(forKeyCode: 49) == "Espaço" && Shortcut.specialLabel(forKeyCode: 0) == nil)
}

@Test func shortcutValidation() throws {
    // letra sozinha ou só com ⇧ dispararia ao escrever
    #expect(Shortcut(keyCode: 8, modifiers: [], keyLabel: "C").problem == .needsModifier)
    #expect(Shortcut(keyCode: 8, modifiers: [.shift], keyLabel: "C").problem == .needsModifier)
    // teclas de função podem ir sozinhas
    #expect(Shortcut(keyCode: 96, modifiers: [], keyLabel: "F5").problem == nil)
    // capturas de ecrã do macOS e outras do sistema
    #expect(Shortcut(keyCode: 21, modifiers: [.command, .shift], keyLabel: "4").problem == .reservedBySystem("⇧⌘4"))
    #expect(Shortcut(keyCode: 23, modifiers: [.command, .shift], keyLabel: "5").problem == .reservedBySystem("⇧⌘5"))
    #expect(Shortcut(keyCode: 49, modifiers: [.command], keyLabel: "Espaço").problem == .reservedBySystem("⌘Espaço"))
    // com ⌘/⌃/⌥ numa tecla livre é aceite (⌘⇧4 é do sistema, mas ⌃⇧4 não)
    #expect(Shortcut(keyCode: 8, modifiers: [.control, .option], keyLabel: "C").problem == nil)
    // guarda e lê (persistência)
    let s = Shortcut(keyCode: 8, modifiers: [.control, .option], keyLabel: "C")
    #expect(try JSONDecoder().decode(Shortcut.self, from: JSONEncoder().encode(s)) == s)
}

// MARK: - Etapa redimensionável

@Test func stepResizesProportionallyAndKeepsOppositeCorner() {
    let s = Shape.step(center: Point(x: 100, y: 100), number: 3)            // raio padrão (16)
    #expect(s.stepRadius == 16 && s.bounds == Rect(x: 84, y: 84, width: 32, height: 32))
    #expect(s.handles.count == 4)
    // canto inferior direito (índice 2) arrastado para (180, 140): lado = max(|dx|,|dy|) = 96 → raio 48; o canto superior esquerdo fica em (84, 84)
    let big = s.movingHandle(2, to: Point(x: 180, y: 140))
    #expect(big.stepRadius == 48)
    #expect(big.bounds == Rect(x: 84, y: 84, width: 96, height: 96))         // quadrado: proporção mantida
    #expect(big.stepNumber == 3)
    // arrastar o canto superior esquerdo (0) em direção ao centro encolhe, mantendo o inferior direito (116, 116)
    let small = s.movingHandle(0, to: Point(x: 100, y: 100))
    #expect(small.bounds.maxX == 116 && small.bounds.maxY == 116 && small.stepRadius == 8)   // mínimo (raio 8)
    // passar para o outro lado do canto fixo vira o círculo, sem deformar
    let flipped = s.movingHandle(2, to: Point(x: 60, y: 70))
    #expect(flipped.bounds.maxX == 84 && flipped.bounds.maxY == 84)           // o canto fixo não se mexe
    #expect(flipped.bounds.width == flipped.bounds.height)
    // limites
    #expect((s.movingHandle(2, to: Point(x: 5000, y: 5000)).stepRadius ?? 0) <= 400)
}

@Test func oldStepsWithoutRadiusStillDecodeAndSizeSurvivesSaving() throws {
    let old = ##"{"formatVersion":1,"canvasWidth":10,"canvasHeight":10,"annotations":[{"id":"6B1F7C3E-8A2D-4E5B-9C10-0A1B2C3D4E5F","z":0,"visible":true,"shape":{"step":{"center":{"x":5,"y":5},"number":2}},"style":{"colorHex":"#FF3B30","lineWidth":4}}]}"##.data(using: .utf8)!
    var doc = try JSONDecoder().decode(CaptureDocument.self, from: old)
    #expect(doc.annotations[0].shape.stepNumber == 2 && doc.annotations[0].shape.stepRadius == 16)   // ficheiro antigo: raio padrão
    var a = doc.annotations[0]; a.shape = a.shape.with(stepRadius: 30); doc.update(a)
    let back = try JSONDecoder().decode(CaptureDocument.self, from: JSONEncoder().encode(doc))
    #expect(back.annotations[0].shape.stepRadius == 30 && back.annotations[0].shape.bounds.width == 60)
    #expect(Shape.step(center: Point(x: 0, y: 0), number: 1).translated(dx: 5, dy: 5).stepRadius == 16)
    #expect(Shape.step(center: Point(x: 0, y: 0), number: 1, radius: 40).translated(dx: 5, dy: 5).stepRadius == 40)
}

// MARK: - Captura por rolagem

import Foundation

@Suite struct ScrollStitchTests {
    static let tall = ScrollTestPage(width: 400, height: 2800)
    static let wide = ScrollTestPage(width: 2400, height: 400, seed: 21)

    /// Percorre `path` (posições sucessivas da janela), como se o utilizador estivesse a rolar e a app a capturar.
    static func feed(_ s: inout MosaicStitcher, page: ScrollTestPage, path: [(Int, Int)], w: Int, h: Int,
                     header: Int = 0, footer: Int = 0, sidebar: Int = 0) -> [MosaicStitcher.Result] {
        path.map { s.add(page.window(ox: $0.0, oy: $0.1, width: w, height: h, header: header, footer: footer, sidebar: sidebar)) }
    }

    /// Posições de `a` até `b` em passos de `step` (inclui `b`).
    static func walkY(_ x: Int, from a: Int, to b: Int, step: Int) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        var y = a
        let dir = b >= a ? step : -step
        while (dir > 0 && y < b) || (dir < 0 && y > b) { out.append((x, y)); y += dir }
        out.append((x, b))
        return out
    }
    static func walkX(_ y: Int, from a: Int, to b: Int, step: Int) -> [(Int, Int)] {
        walkY(y, from: a, to: b, step: step).map { ($0.1, $0.0) }
    }

    /// Todas as linhas/colunas do resultado (a partir de `at`) coincidem com a página em `(px, py)` nas colunas dadas.
    static func matches(_ f: PixelFrame, at: (Int, Int), size: (Int, Int), page: ScrollTestPage, page0: (Int, Int), skipColumns: Range<Int> = 0..<0) -> Bool {
        for y in 0..<size.1 {
            for x in 0..<size.0 where !skipColumns.contains(x) {
                let a = ((at.1 + y) * f.width + at.0 + x) * 4, b = ((page0.1 + y) * page.width + page0.0 + x) * 4
                if f.rgba[a] != page.rgba[b] || f.rgba[a + 1] != page.rgba[b + 1] || f.rgba[a + 2] != page.rgba[b + 2] { return false }
            }
        }
        return true
    }

    @Test func downWithFixedHeaderFooterSidebar() {
        let w = 400, h = 500, header = 50, footer = 40, sidebar = 60
        var s = MosaicStitcher()
        let r = Self.feed(&s, page: Self.tall, path: Self.walkY(0, from: 0, to: 1960, step: 140), w: w, h: h, header: header, footer: footer, sidebar: sidebar)
        #expect(r.first == .first)
        #expect(r.dropFirst().allSatisfy { if case .moved = $0 { true } else { false } })
        // parado no fim: nada muda
        #expect(s.add(Self.tall.window(ox: 0, oy: 1960, width: w, height: h, header: header, footer: footer, sidebar: sidebar)) == .unchanged)
        guard let out = s.result() else { Issue.record("sem resultado"); return }
        let body = 1960 + (h - header - footer)
        #expect(out.width == w && out.height == header + body + footer)   // cabeçalho e rodapé uma só vez
        #expect(Self.matches(out, at: (sidebar, header), size: (w - sidebar, body), page: Self.tall, page0: (sidebar, 0)))
    }

    @Test func startsInTheMiddleThenGoesBothWaysAndRevisits() {
        // começa a meio, sobe até ao topo, desce até ao fim, volta a subir (passa outra vez pela mesma zona), desce
        var s = MosaicStitcher()
        var path = Self.walkY(0, from: 900, to: 0, step: 130)
        path += Self.walkY(0, from: 0, to: 2300, step: 170)
        path += Self.walkY(0, from: 2300, to: 1200, step: 150)
        path += Self.walkY(0, from: 1200, to: 2300, step: 90)
        let r = Self.feed(&s, page: Self.tall, path: path, w: 400, h: 500)
        #expect(!r.contains(.failed))
        let out = s.result()!
        #expect(out.width == 400 && out.height == 2300 + 500)
        #expect(Self.matches(out, at: (0, 0), size: (400, 2800), page: Self.tall, page0: (0, 0)))
    }

    @Test func horizontalBothWays() {
        var s = MosaicStitcher()
        var path = Self.walkX(0, from: 700, to: 0, step: 110)
        path += Self.walkX(0, from: 0, to: 1900, step: 160)
        path += Self.walkX(0, from: 1900, to: 1000, step: 120)
        let r = Self.feed(&s, page: Self.wide, path: path, w: 500, h: 400)
        #expect(!r.contains(.failed))
        let out = s.result()!
        #expect(out.width == 1900 + 500 && out.height == 400)
        #expect(Self.matches(out, at: (0, 0), size: (2400, 400), page: Self.wide, page0: (0, 0)))
    }

    @Test func switchingAxis() {
        // desce, vai para a direita, sobe: forma um "U"; confere os píxeis dentro das janelas visitadas
        let page = ScrollTestPage(width: 1400, height: 1800, seed: 33)
        var s = MosaicStitcher()
        var path = Self.walkY(0, from: 0, to: 700, step: 120)
        path += Self.walkX(700, from: 0, to: 600, step: 100)
        path += Self.walkY(600, from: 700, to: 200, step: 110)
        let r = Self.feed(&s, page: page, path: path, w: 500, h: 500)
        #expect(!r.contains(.failed))
        let out = s.result()!
        #expect(out.width == 600 + 500 && out.height == 700 + 500)
        // as três janelas extremas (início, canto, fim) coincidem com a página
        #expect(Self.matches(out, at: (0, 0), size: (500, 500), page: page, page0: (0, 0)))
        #expect(Self.matches(out, at: (600, 700), size: (500, 500), page: page, page0: (600, 700)))
        #expect(Self.matches(out, at: (600, 200), size: (500, 500), page: page, page0: (600, 200)))
    }

    @Test func tooFastIsReportedAndRecovers() {
        var s = MosaicStitcher()
        _ = s.add(Self.tall.window(ox: 0, oy: 500, width: 400, height: 500))
        _ = s.add(Self.tall.window(ox: 0, oy: 700, width: 400, height: 500))
        // salto maior do que a janela: sem sobreposição com a anterior
        #expect(s.add(Self.tall.window(ox: 0, oy: 1900, width: 400, height: 500)) == .failed)
        // quando volta à zona anterior, retoma
        if case .moved = s.add(Self.tall.window(ox: 0, oy: 900, width: 400, height: 500)) {} else { Issue.record("não retomou") }
        let out = s.result()!
        #expect(out.height == 900 - 500 + 500)
        #expect(Self.matches(out, at: (0, 0), size: (400, out.height), page: Self.tall, page0: (0, 500)))
    }

    @Test func smallChangesWithoutScrollingAreIgnored() {
        var s = MosaicStitcher()
        _ = s.add(Self.tall.window(ox: 0, oy: 300, width: 400, height: 500))
        var f = Self.tall.window(ox: 0, oy: 300, width: 400, height: 500)
        // um "relógio" pisca num canto: 20×20 píxeis diferentes
        for y in 10..<30 { for x in 10..<30 { let i = (y * 400 + x) * 4; f.rgba[i] = 0; f.rgba[i + 1] = 0; f.rgba[i + 2] = 0 } }
        #expect(s.add(f) == .unchanged)
        #expect(s.accepted == 0)
    }

    @Test func oneFrameOnlyReturnsItself() {
        var s = MosaicStitcher()
        let f = Self.tall.window(ox: 0, oy: 0, width: 300, height: 200)
        _ = s.add(f)
        #expect(s.result() == f)
    }

    @Test func transposeAndFlipAreInvolutions() {
        let f = Self.tall.window(ox: 3, oy: 5, width: 37, height: 53)
        #expect(f.transposed().transposed() == f)
        #expect(f.flippedVertically().flippedVertically() == f)
    }
}

// MARK: - Atualizações

@Suite struct UpdateInfoTests {
    @Test func versionOrdering() {
        func v(_ s: String) -> AppVersion { AppVersion(s)! }
        #expect(v("0.2.0") > v("0.1.5.5"))
        #expect(v("0.1.5.10") > v("0.1.5.9"))
        #expect(v("1.0") == v("1.0.0"))
        #expect(v("v1.2.3") == v("1.2.3"))
        #expect(v("1.2.3-beta") == v("1.2.3"))
        #expect(v("0.1.5.5") < v("0.1.6"))
        #expect(v("2") > v("1.9.9.9"))
        #expect(Set([v("1.0"), v("1.0.0")]).count == 1)
        #expect(AppVersion("abc") == nil && AppVersion("") == nil && AppVersion("1..2") == nil && AppVersion("1.-2") == nil)
        #expect(v("0.1.5.5").description == "0.1.5.5")
    }

    static let json = #"""
    {"tag_name":"v0.2.0","name":"Toth 0.2.0","draft":false,"prerelease":false,"html_url":"https://github.com/x/toth/releases/tag/v0.2.0",
     "body":"## Novidades\n- coisa\n\nSHA-256 do zip: `0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef`",
     "assets":[{"name":"notes.txt","browser_download_url":"https://x/notes.txt"},
               {"name":"Toth-0.2.0.zip","browser_download_url":"https://x/Toth-0.2.0.zip","digest":"sha256:ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef0123456789"}]}
    """#

    @Test func parsesGitHubRelease() {
        let r = ReleaseInfo.parse(Data(Self.json.utf8))
        #expect(r?.tag == "v0.2.0" && r?.version == AppVersion("0.2.0"))
        #expect(r?.assetName == "Toth-0.2.0.zip" && r?.assetURL.absoluteString == "https://x/Toth-0.2.0.zip")
        #expect(r?.sha256 == "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789")   // do `digest`, em minúsculas
        #expect(r?.isNewer(than: AppVersion("0.1.5.5")!) == true)
        #expect(r?.isNewer(than: AppVersion("0.2.0")!) == false)
        #expect(r?.isNewer(than: AppVersion("1.0")!) == false)
    }

    @Test func shaFromNotesWhenNoDigest() {
        let j = Self.json.replacingOccurrences(of: #","digest":"sha256:ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef0123456789""#, with: "")
        #expect(ReleaseInfo.parse(Data(j.utf8))?.sha256 == "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
    }

    @Test func rejectsUnusableReleases() {
        #expect(ReleaseInfo.parse(Data("{}".utf8)) == nil)
        #expect(ReleaseInfo.parse(Data("não é json".utf8)) == nil)
        #expect(ReleaseInfo.parse(Data(Self.json.replacingOccurrences(of: "\"draft\":false", with: "\"draft\":true").utf8)) == nil)
        #expect(ReleaseInfo.parse(Data(Self.json.replacingOccurrences(of: "Toth-0.2.0.zip", with: "outro.zip").utf8)) == nil)
        #expect(ReleaseInfo.parse(Data(Self.json.replacingOccurrences(of: "v0.2.0", with: "nightly").utf8)) == nil)
        // pré-lançamento nunca é oferecido
        let pre = ReleaseInfo.parse(Data(Self.json.replacingOccurrences(of: "\"prerelease\":false", with: "\"prerelease\":true").utf8))
        #expect(pre?.isNewer(than: AppVersion("0.1")!) == false)
    }

    @Test func schedule() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(UpdateSchedule.isDue(last: nil, now: now))
        #expect(!UpdateSchedule.isDue(last: now.addingTimeInterval(-3600), now: now))
        #expect(UpdateSchedule.isDue(last: now.addingTimeInterval(-25 * 3600), now: now))
        #expect(UpdateSchedule.isDue(last: now.addingTimeInterval(3 * 24 * 3600), now: now))   // data no futuro: relógio mudado
    }
}


// MARK: - Mistura de áudio (gravação de vídeo)

@Suite struct AudioMixerTests {
    /// Tom estéreo intercalado (`freq` Hz) com `frames` frames a começar na posição `from`.
    static func tone(_ freq: Double, from: Int64, frames: Int, amp: Float = 0.4) -> [Float] {
        var out = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let v = amp * Float(sin(2 * Double.pi * freq * Double(from + Int64(i)) / 48_000))
            out[2 * i] = v; out[2 * i + 1] = v
        }
        return out
    }

    /// Energia do tom `freq` (Goertzel) num trecho do canal esquerdo, normalizada pelo comprimento.
    static func energy(_ chunks: [(frame: Int64, samples: [Float])], _ freq: Double, frames: ClosedRange<Int64>) -> Double {
        var s: [Double] = []
        for c in chunks { for i in 0..<(c.samples.count / 2) where frames.contains(c.frame + Int64(i)) { s.append(Double(c.samples[2 * i])) } }
        guard !s.isEmpty else { return 0 }
        let w = 2 * Double.pi * freq / 48_000, k = 2 * cos(w)
        var a = 0.0, b = 0.0
        for x in s { let n = x + k * a - b; b = a; a = n }
        let power = a * a + b * b - k * a * b
        return power / Double(s.count * s.count)
    }

    static func joined(_ chunks: [(frame: Int64, samples: [Float])]) -> Int64 { Int64(chunks.reduce(0) { $0 + $1.samples.count / 2 }) }

    @Test func bothSourcesAreMixedAndAligned() {
        var m = AudioMixer(system: true, microphone: true)
        var out: [(frame: Int64, samples: [Float])] = []
        var f: Int64 = 0
        while f < 48_000 {                                  // tamanhos de bloco diferentes em cada fonte
            m.push(.system, samples: Self.tone(440, from: f, frames: 1024), startFrame: f)
            m.push(.microphone, samples: Self.tone(880, from: f, frames: 1024), startFrame: f)
            f += 1024
            m.advance(toFrame: f)
            out += m.pop()
        }
        out += m.pop(flush: true)
        #expect(Self.joined(out) >= 48_000)
        let sys = Self.energy(out, 440, frames: 4_800...43_200), mic = Self.energy(out, 880, frames: 4_800...43_200)
        #expect(sys > 0.01 && mic > 0.01, "sistema \(sys), microfone \(mic)")
        #expect(Self.energy(out, 1_500, frames: 4_800...43_200) < 0.001)       // nenhum tom estranho
    }

    @Test func microphoneCanBeSwitchedOffAndOnAnytime() {
        var m = AudioMixer(system: true, microphone: true)
        var out: [(frame: Int64, samples: [Float])] = []
        var f: Int64 = 0
        while f < 96_000 {
            if f == 32_768 { m.setEnabled(.microphone, false) }       // 0,7 s: desliga
            if f == 65_536 { m.setEnabled(.microphone, true) }        // 1,4 s: volta a ligar
            m.push(.system, samples: Self.tone(440, from: f, frames: 1024), startFrame: f)
            m.push(.microphone, samples: Self.tone(880, from: f, frames: 1024), startFrame: f)
            f += 1024; m.advance(toFrame: f); out += m.pop()
        }
        out += m.pop(flush: true)
        #expect(Self.energy(out, 880, frames: 2_000...30_000) > 0.01)             // antes: microfone presente
        #expect(Self.energy(out, 880, frames: 36_000...62_000) < 0.0005)          // desligado: ausente
        #expect(Self.energy(out, 880, frames: 68_000...94_000) > 0.01)            // religado: presente
        #expect(Self.energy(out, 440, frames: 36_000...62_000) > 0.01)            // o sistema nunca parou
    }

    @Test func gapsBecomeSilenceAndPositionsAreKept() {
        var m = AudioMixer(system: true, microphone: false)
        m.push(.system, samples: Self.tone(440, from: 0, frames: 9_600), startFrame: 0)
        m.push(.system, samples: Self.tone(440, from: 19_200, frames: 9_600), startFrame: 19_200)   // falha de 0,2 s
        m.advance(toFrame: 28_800)
        var out = m.pop(); out += m.pop(flush: true)
        #expect(Self.energy(out, 440, frames: 1_000...8_000) > 0.01)
        #expect(Self.energy(out, 440, frames: 10_500...18_500) < 0.0001)           // a falha ficou em silêncio
        #expect(Self.energy(out, 440, frames: 20_000...28_000) > 0.01)
    }

    @Test func overlapsAreTrimmed() {
        var m = AudioMixer(system: true, microphone: false)
        m.push(.system, samples: Self.tone(440, from: 0, frames: 4_800), startFrame: 0)
        m.push(.system, samples: Self.tone(440, from: 2_400, frames: 4_800), startFrame: 2_400)   // repete 2 400 frames
        m.advance(toFrame: 7_200)
        var out = m.pop(); out += m.pop(flush: true)
        #expect(Self.joined(out) >= 7_200 && Self.joined(out) <= 7_200 + 960)      // o último bloco completa-se com silêncio
        // contínuo: sem saltos de amplitude entre amostras consecutivas
        let flat = out.flatMap { $0.samples }
        var maxJump: Float = 0
        for i in stride(from: 2, to: 7_200 * 2, by: 2) { maxJump = max(maxJump, abs(flat[i] - flat[i - 2])) }
        #expect(maxJump < 0.1)
    }

    @Test func aLateSourceDoesNotBlockTheOthers() {
        var m = AudioMixer(chunkFrames: 960, maxLatencyFrames: 4_800, system: true, microphone: true)   // microfone ligado mas mudo
        var out: [(frame: Int64, samples: [Float])] = []
        var f: Int64 = 0
        while f < 48_000 {
            m.push(.system, samples: Self.tone(440, from: f, frames: 960), startFrame: f)
            f += 960; m.advance(toFrame: f); out += m.pop()
        }
        // a meio segundo de atraso máximo, o áudio já tem de ter saído (sem esperar pelo microfone)
        #expect(Self.joined(out) >= 48_000 - 4_800 - 960)
        #expect(Self.energy(out, 440, frames: 2_000...30_000) > 0.01)
    }

    @Test func silenceWhenNothingIsEnabled() {
        var m = AudioMixer(system: false, microphone: false)
        m.advance(toFrame: 9_600)
        let out = m.pop()
        #expect(Self.joined(out) == 9_600)
        #expect(out.allSatisfy { $0.samples.allSatisfy { $0 == 0 } })
    }

    @Test func clipsInsteadOfOverflowing() {
        var m = AudioMixer(system: true, microphone: true)
        m.push(.system, samples: Self.tone(440, from: 0, frames: 4_800, amp: 0.9), startFrame: 0)
        m.push(.microphone, samples: Self.tone(440, from: 0, frames: 4_800, amp: 0.9), startFrame: 0)
        m.advance(toFrame: 4_800)
        let out = m.pop()
        #expect(out.allSatisfy { $0.samples.allSatisfy { abs($0) <= 1.0 } })
    }
}

// MARK: - Linha de tempo de edição (várias linhas, clipes e espaços)

@Suite struct EditTimelineTests {
    static func tl() -> EditTimeline { EditTimeline(sourceDuration: 60, tracks: [.video, .system, .microphone]) }
    static let all: Set<EditTrack> = [.video, .system, .microphone]

    @Test func startsWithOneClipPerLane() {
        let t = Self.tl()
        #expect(t.duration == 60 && !t.isEdited && t.tracks == [.video, .system, .microphone])
        #expect(t.clips(.video) == [Clip(media: 0, src: TimeSpan(start: 0, end: 60), at: 0)])
        #expect(t.gaps(.video).isEmpty)
    }

    @Test func cutAndJoinClosesTheGapOnEveryLane() {
        var t = Self.tl()
        let ok = t.remove(TimeSpan(start: 20, end: 30), tracks: Self.all, ripple: true)
        #expect(ok && t.duration == 50 && t.isEdited)
        #expect(t.clips(.video) == [Clip(media: 0, src: TimeSpan(start: 0, end: 20), at: 0), Clip(media: 0, src: TimeSpan(start: 30, end: 60), at: 20)])
        #expect(t.gaps(.system).isEmpty)
    }

    @Test func cutLeavingASpaceKeepsTheRestWhereItIs() {
        var t = Self.tl()
        let ok = t.remove(TimeSpan(start: 20, end: 30), tracks: Self.all, ripple: false)
        #expect(ok && t.duration == 60)
        #expect(t.clips(.video)[1] == Clip(media: 0, src: TimeSpan(start: 30, end: 60), at: 30))
        #expect(t.gaps(.video) == [TimeSpan(start: 20, end: 30)])
        #expect(t.clip(at: 25, in: .video) == nil && t.clip(at: 35, in: .video) != nil)
    }

    @Test func cuttingOnlyTheAudioLeavesASpaceWithVideo() {
        var t = Self.tl()
        let ok = t.remove(TimeSpan(start: 10, end: 20), tracks: [.system, .microphone], ripple: false)
        #expect(ok)
        #expect(t.clips(.video).count == 1)                                           // o vídeo continua a correr
        #expect(t.gaps(.system) == [TimeSpan(start: 10, end: 20)] && t.gaps(.microphone) == [TimeSpan(start: 10, end: 20)])
        var u = Self.tl()
        let ok2 = u.remove(TimeSpan(start: 10, end: 20), tracks: [.video], ripple: false)   // espaço sem vídeo, com áudio
        #expect(ok2 && u.gaps(.video) == [TimeSpan(start: 10, end: 20)] && u.gaps(.system).isEmpty)
    }

    @Test func partialCutsSplitClipsCorrectly() {
        var t = Self.tl()
        t.remove(TimeSpan(start: 10, end: 20), tracks: Self.all, ripple: true)      // 10 s a menos
        t.remove(TimeSpan(start: 15, end: 25), tracks: Self.all, ripple: true)      // cai sobre as duas partes
        let v = t.clips(.video)
        #expect(t.duration == 40)
        #expect(v == [Clip(media: 0, src: TimeSpan(start: 0, end: 10), at: 0), Clip(media: 0, src: TimeSpan(start: 20, end: 25), at: 10), Clip(media: 0, src: TimeSpan(start: 35, end: 60), at: 15)])
    }

    @Test func rejectsUselessOrTotalCuts() {
        var t = Self.tl()
        do { let ok = t.remove(TimeSpan(start: 5, end: 5.01), tracks: Self.all, ripple: true); #expect(!ok) }
        do { let ok = t.remove(TimeSpan(start: 100, end: 120), tracks: Self.all, ripple: true); #expect(!ok) }
        do { let ok = t.remove(TimeSpan(start: 0, end: 60), tracks: Self.all, ripple: true); #expect(!ok) }
        #expect(!t.isEdited)
        // retirar tudo de uma linha só é permitido enquanto sobrar conteúdo noutra
        do { let ok = t.remove(TimeSpan(start: 0, end: 60), tracks: [.microphone], ripple: false); #expect(ok) }
        #expect(t.contentLength(.microphone) == 0 && t.contentLength(.video) == 60)
    }

    @Test func extractCopiesRelativeToTheStart() {
        var t = Self.tl()
        t.remove(TimeSpan(start: 20, end: 30), tracks: Self.all, ripple: false)
        let p = t.extract(TimeSpan(start: 15, end: 35), tracks: [.video])
        #expect(p.length == 20 && Array(p.lanes.keys) == [.video])
        #expect(p.lanes[.video] == [Clip(media: 0, src: TimeSpan(start: 15, end: 20), at: 0), Clip(media: 0, src: TimeSpan(start: 30, end: 35), at: 15)])   // o espaço vem junto
    }

    @Test func pasteInsertsAndPushesTheRestWhenRippling() {
        var t = Self.tl()
        let p = t.extract(TimeSpan(start: 10, end: 15), tracks: Self.all)           // 5 s
        t.insert(p, at: 40, ripple: true)
        #expect(t.duration == 65)
        #expect(t.clips(.video) == [Clip(media: 0, src: TimeSpan(start: 0, end: 40), at: 0), Clip(media: 0, src: TimeSpan(start: 10, end: 15), at: 40), Clip(media: 0, src: TimeSpan(start: 40, end: 60), at: 45)])
    }

    @Test func pasteOverwritesWhenNotRippling() {
        var t = Self.tl()
        let p = t.extract(TimeSpan(start: 10, end: 15), tracks: [.system])
        t.insert(p, at: 40, ripple: false)
        #expect(t.duration == 60)
        #expect(t.clips(.system) == [Clip(media: 0, src: TimeSpan(start: 0, end: 40), at: 0), Clip(media: 0, src: TimeSpan(start: 10, end: 15), at: 40), Clip(media: 0, src: TimeSpan(start: 45, end: 60), at: 45)])
        #expect(t.clips(.video).count == 1)                                          // só a linha copiada mudou
    }

    @Test func mirrorAndReplaceForReversing() {
        var t = Self.tl()
        t.remove(TimeSpan(start: 20, end: 30), tracks: [.video], ripple: false)
        let range = TimeSpan(start: 10, end: 40)
        let p = t.extract(range, tracks: [.video])                                   // 10–20 e 30–40, com espaço no meio
        #expect(p.lanes[.video]?.map { EditTimeline.mirroredAt($0, length: p.length) } == [20, 0])   // trocam de lugar
        let reversed = (p.lanes[.video] ?? []).map { Clip(media: 1, src: TimeSpan(start: 0, end: $0.length), at: EditTimeline.mirroredAt($0, length: p.length)) }
        t.replace(range, tracks: [.video], with: [.video: reversed])
        #expect(t.clips(.video).map(\.media) == [0, 1, 1, 0])
        #expect(t.gaps(.video) == [TimeSpan(start: 20, end: 30)])                    // o espaço do meio mantém-se no meio
        #expect(t.duration == 60)
    }

    @Test func codable() throws {
        var t = Self.tl()
        t.remove(TimeSpan(start: 20, end: 30), tracks: Self.all, ripple: true)
        let back = try JSONDecoder().decode(EditTimeline.self, from: JSONEncoder().encode(t))
        #expect(back == t)
    }
}

@Suite struct EditTimelineMoveTests {
    static let all: Set<EditTrack> = [.video, .system, .microphone]
    static func tl() -> EditTimeline { EditTimeline(sourceDuration: 60, tracks: [.video, .system, .microphone]) }

    @Test func movingLeavesAGapAndOverwritesTheDestination() {
        var t = Self.tl()
        let at = t.move(TimeSpan(start: 10, end: 20), tracks: Self.all, to: 40, ripple: false)
        #expect(at == 40 && t.duration == 60)
        #expect(t.gaps(.video) == [TimeSpan(start: 10, end: 20)])                       // onde estava ficou um espaço
        #expect(t.clips(.video) == [Clip(media: 0, src: TimeSpan(start: 0, end: 10), at: 0),
                                    Clip(media: 0, src: TimeSpan(start: 20, end: 40), at: 20),
                                    Clip(media: 0, src: TimeSpan(start: 10, end: 20), at: 40),
                                    Clip(media: 0, src: TimeSpan(start: 50, end: 60), at: 50)])   // 40–50 foi substituído
    }

    @Test func movingWithRippleClosesTheSourceAndPushesTheDestination() {
        var t = Self.tl()
        let at = t.move(TimeSpan(start: 10, end: 20), tracks: Self.all, to: 40, ripple: true)
        #expect(at == 30 && t.duration == 60 && t.gaps(.video).isEmpty)               // 40 − 10: o espaço de origem fechou
        #expect(t.clips(.video) == [Clip(media: 0, src: TimeSpan(start: 0, end: 10), at: 0),
                                    Clip(media: 0, src: TimeSpan(start: 20, end: 40), at: 10),     // o clipe divide-se onde entra o trecho
                                    Clip(media: 0, src: TimeSpan(start: 10, end: 20), at: 30),
                                    Clip(media: 0, src: TimeSpan(start: 40, end: 60), at: 40)])
    }

    @Test func movingBackwardAndOnlyOneLane() {
        var t = Self.tl()
        let at = t.move(TimeSpan(start: 30, end: 40), tracks: [.system], to: 5, ripple: false)
        #expect(at == 5)
        #expect(t.clips(.video).count == 1 && t.clips(.microphone).count == 1)         // só a linha escolhida mexeu
        #expect(t.clip(at: 7, in: .system) == Clip(media: 0, src: TimeSpan(start: 30, end: 40), at: 5))   // o trecho de 30–40 começa agora em 5
        #expect(t.gaps(.system) == [TimeSpan(start: 30, end: 40)])
    }

    @Test func movingPastTheEndGrowsTheTimeline() {
        var t = Self.tl()
        let at = t.move(TimeSpan(start: 50, end: 60), tracks: Self.all, to: 70, ripple: false)
        #expect(at == 70 && t.duration == 80)
        #expect(t.gaps(.video) == [TimeSpan(start: 50, end: 70)])
    }

    @Test func noopsAndRejections() {
        var t = Self.tl()
        #expect(t.move(TimeSpan(start: 10, end: 10.01), tracks: Self.all, to: 20, ripple: false) == nil)   // curto demais
        #expect(t.move(TimeSpan(start: 10, end: 20), tracks: Self.all, to: 10, ripple: false) == 10)         // já está lá
        #expect(!t.isEdited)
        #expect(t.move(TimeSpan(start: 10, end: 20), tracks: [], to: 30, ripple: false) == nil)             // nenhuma linha
    }
}
