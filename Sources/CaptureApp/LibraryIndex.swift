// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit
import CaptureCore

/// Índice da biblioteca para a pesquisa: por captura, o nome dado pelo utilizador, o texto das anotações e o texto
/// reconhecido na imagem (OCR, no Mac, sem rede). O texto reconhecido fica guardado em `text.txt` dentro de cada
/// pacote `.capture` (o original nunca muda, por isso nunca fica desatualizado); as capturas sem ele são reconhecidas
/// em segundo plano, uma de cada vez, com prioridade baixa, quando a biblioteca abre.
@MainActor
final class LibraryIndex: ObservableObject {
    static let shared = LibraryIndex()
    nonisolated static let textFile = "text.txt"

    struct Entry: Equatable {
        var title: String?
        var annotationText: String = ""
        var recognizedText: String?   // nil = ainda não reconhecido
    }

    /// Chave por captura: o caminho com os atalhos resolvidos (`/tmp` e `/private/tmp` são a mesma pasta).
    nonisolated static func key(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
    @Published private(set) var entries: [URL: Entry] = [:]
    /// Quantas capturas ainda estão à espera de reconhecimento de texto.
    @Published private(set) var pending = 0
    /// `false` desliga o reconhecimento em segundo plano (testes).
    var recognizes = true
    /// Captura aberta no editor: o pacote dela não é reescrito pelo indexador.
    var openURL: (() -> URL?)?
    private var running = false
    private var queue: [URL] = []

    /// Lê (em segundo plano) o que cada captura já tem, e põe na fila as que ainda não têm texto reconhecido.
    func sync(_ items: [LibraryItem]) {
        let urls = items.filter { !$0.isVideo }.map { Self.key($0.url) }
        let known = entries
        Task.detached(priority: .utility) {
            var fresh: [URL: Entry] = [:]
            for u in urls where known[u] == nil || known[u]?.recognizedText == nil {
                fresh[u] = Self.read(u)
            }
            Self.onMain { [fresh] in
                for (u, e) in fresh { self.entries[u] = e }
                for u in Set(self.entries.keys).subtracting(urls) { self.entries[u] = nil }
                self.queue = urls.filter { self.entries[$0]?.recognizedText == nil }
                self.pending = self.queue.count
                self.runNext()
            }
        }
    }

    /// A captura foi gravada: volta a ler o nome e o texto das anotações.
    func reload(_ raw: URL) {
        let url = Self.key(raw)
        Task.detached(priority: .utility) {
            let e = Self.read(url)
            Self.onMain { var cur = self.entries[url] ?? e; cur.title = e.title; cur.annotationText = e.annotationText; if cur.recognizedText == nil { cur.recognizedText = e.recognizedText }; self.entries[url] = cur }
        }
    }

    /// Entrega no fio principal pelo run loop (e não pela fila principal): assim também chega quando o fio principal
    /// está num `RunLoop.run` encaixado, como nos autotestes.
    nonisolated private static func onMain(_ f: @escaping @MainActor () -> Void) {
        RunLoop.main.perform { MainActor.assumeIsolated { f() } }
    }

    nonisolated private static func read(_ url: URL) -> Entry {
        var e = Entry()
        if let d = CaptureContainer.readEntry(CapturePackage.documentFile, at: url), let doc = try? JSONDecoder().decode(CaptureDocument.self, from: d) {
            e.title = doc.title; e.annotationText = doc.annotationText
        }
        if let t = CaptureContainer.readEntry(textFile, at: url) { e.recognizedText = String(decoding: t, as: UTF8.self) }
        return e
    }

    private func runNext() {
        guard recognizes, !running, let url = queue.first else { if queue.isEmpty { pending = 0 }; return }
        running = true
        let writable = openURL?().map { Self.key($0) } != url
        Task.detached(priority: .utility) {
            let text = Self.recognizeAndStore(url, writable: writable)
            Self.onMain { self.recognized(url, text: text); self.running = false; self.runNext() }
        }
    }

    /// Reconhece já (no fio atual) o texto de uma captura e guarda-o (testes).
    func recognizeNow(_ raw: URL) {
        let url = Self.key(raw)
        let text = Self.recognizeAndStore(url, writable: openURL?().map { Self.key($0) } != url)
        recognized(url, text: text)
    }

    private func recognized(_ url: URL, text: String) {
        var cur = entries[url] ?? Entry(); cur.recognizedText = text; entries[url] = cur
        queue.removeAll { $0 == url }
        pending = queue.count
    }

    nonisolated private static func recognizeAndStore(_ url: URL, writable: Bool) -> String {
        let text = recognize(url) ?? ""
        if writable, let c = try? CaptureContainer(url: url), c.data(CapturePackage.documentFile) != nil {
            try? c.write(textFile, Data(text.utf8)); try? c.flush()
        }
        return text
    }

    nonisolated private static func recognize(_ url: URL) -> String? {
        guard let d = CaptureContainer.readEntry(CapturePackage.originalFile, at: url), let src = CGImageSourceCreateWithData(d as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return (try? TextRecognizer.recognize(img, origin: Point(x: 0, y: 0)))?.map(\.text).joined(separator: "\n")
    }

    // MARK: Pesquisa

    enum DateFilter: String, CaseIterable, Identifiable {
        case all, today, week, month, year
        var id: String { rawValue }
        var title: String {
            switch self { case .all: L("Todas as datas"); case .today: L("Hoje"); case .week: L("Últimos 7 dias"); case .month: L("Últimos 30 dias"); case .year: L("Este ano") }
        }
        func contains(_ d: Date, now: Date = Date()) -> Bool {
            let cal = Calendar.current
            switch self {
            case .all: return true
            case .today: return cal.isDate(d, inSameDayAs: now)
            case .week: return d >= cal.date(byAdding: .day, value: -7, to: now)!
            case .month: return d >= cal.date(byAdding: .day, value: -30, to: now)!
            case .year: return cal.component(.year, from: d) == cal.component(.year, from: now)
            }
        }
    }

    /// Texto sem acentos nem maiúsculas, para comparar.
    nonisolated static func fold(_ s: String) -> String { s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil).lowercased() }

    /// Nome a mostrar (o dado pelo utilizador, ou a data).
    func title(for url: URL) -> String {
        entries[Self.key(url)]?.title ?? LibraryNames.title(forFileName: url.deletingPathExtension().lastPathComponent)
    }
    func entry(for url: URL) -> Entry? { entries[Self.key(url)] }

    /// As capturas que batem com o texto (nome, nome do ficheiro, anotações, texto da imagem) e com a data.
    func filter(_ items: [LibraryItem], query: String, date: DateFilter) -> [LibraryItem] {
        let words = query.split(separator: " ").map { Self.fold(String($0)) }.filter { !$0.isEmpty }
        return items.filter { item in
            if date != .all {
                let d = LibraryNames.date(forFileName: item.url.deletingPathExtension().lastPathComponent)
                    ?? (try? item.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if !date.contains(d) { return false }
            }
            guard !words.isEmpty else { return true }
            let e = entries[Self.key(item.url)]
            let hay = Self.fold([title(for: item.url), item.url.deletingPathExtension().lastPathComponent, e?.annotationText ?? "", e?.recognizedText ?? ""].joined(separator: "\n"))
            return words.allSatisfy { hay.contains($0) }
        }
    }
}
