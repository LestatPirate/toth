// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit

/// Falhas: o macOS guarda um relatório (`~/Library/Logs/DiagnosticReports/Toth-….ips`) sempre que uma app falha.
/// Ao abrir, o Toth vê se há um relatório novo desde a última vez e avisa: «O Toth fechou inesperadamente», com botões
/// para ver o relatório, copiá-lo ou abrir um pedido no GitHub já preenchido.
///
/// **Nada é enviado sozinho.** O Toth só lê o ficheiro que o macOS escreveu; quem decide enviar é o utilizador, que vê
/// o conteúdo antes. O pedido no GitHub leva só um resumo (versão, exceção e as funções da thread que falhou, sem
/// caminhos do computador); o relatório completo vai para a área de transferência, para colar se quiser.
enum CrashReports {
    struct Report: Equatable {
        var url: URL
        var date: Date
        var version: String
        var build: String
        var os: String
        /// «EXC_BAD_ACCESS (SIGSEGV)»
        var exception: String
        /// As primeiras funções da thread que falhou: «Toth  EditorModel.paste() + 124».
        var frames: [String]
    }

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }
    static let issuesURL = "https://github.com/LestatPirate/toth/issues/new"

    /// Os relatórios de falha desta app em `dir`, do mais recente para o mais antigo. Só os que trazem o identificador da
    /// app: o binário de desenvolvimento (sem identificador) e outras apps chamadas «Toth» ficam de fora.
    static func reports(in dir: URL, bundleID: String) -> [Report] {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return items.filter { $0.pathExtension == "ips" && $0.lastPathComponent.hasPrefix("Toth") }
            .compactMap { parse($0, bundleID: bundleID) }
            .sorted { $0.date > $1.date }
    }

    /// Um `.ips` é uma linha de cabeçalho em JSON e, a seguir, o corpo, também em JSON.
    static func parse(_ url: URL, bundleID: String) -> Report? {
        guard let text = try? String(contentsOf: url, encoding: .utf8), let nl = text.firstIndex(of: "\n"),
              let header = (try? JSONSerialization.jsonObject(with: Data(text[..<nl].utf8))) as? [String: Any],
              (header["bundleID"] as? String) == bundleID else { return nil }
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        var report = Report(url: url, date: date, version: header["app_version"] as? String ?? "?", build: header["build_version"] as? String ?? "?",
                            os: header["os_version"] as? String ?? "?", exception: "?", frames: [])
        guard let body = (try? JSONSerialization.jsonObject(with: Data(text[text.index(after: nl)...].utf8))) as? [String: Any] else { return report }
        if let e = body["exception"] as? [String: Any] {
            let type = e["type"] as? String ?? "?"
            report.exception = (e["signal"] as? String).map { "\(type) (\($0))" } ?? type
        }
        let images = (body["usedImages"] as? [[String: Any]] ?? []).map { $0["name"] as? String ?? "?" }
        let threads = body["threads"] as? [[String: Any]] ?? []
        let crashed = threads.first { $0["triggered"] as? Bool == true } ?? (body["faultingThread"] as? Int).flatMap { threads.indices.contains($0) ? threads[$0] : nil }
        for f in (crashed?["frames"] as? [[String: Any]] ?? []).prefix(12) {
            let image = (f["imageIndex"] as? Int).flatMap { images.indices.contains($0) ? images[$0] : nil } ?? "?"
            let symbol = f["symbol"] as? String ?? "0x\(String(f["imageOffset"] as? Int ?? 0, radix: 16))"
            let offset = (f["symbolLocation"] as? Int).map { " + \($0)" } ?? ""
            report.frames.append("\(image)  \(symbol)\(offset)")
        }
        return report
    }

    /// O pedido no GitHub já preenchido: título e um resumo sem caminhos do computador (o endereço fica curto).
    static func issueURL(for r: Report) -> URL? {
        let top = r.frames.first.map { String($0.split(separator: " ", omittingEmptySubsequences: true).dropFirst().joined(separator: " ").prefix(70)) } ?? ""
        let title = "Falha / Crash: \(r.exception)" + (top.isEmpty ? "" : " — \(top)")
        let body = """
        **Toth** \(r.version) (\(r.build)) · \(r.os)
        **Exceção / Exception:** \(r.exception)

        **Thread que falhou / Crashed thread:**
        ```
        \(r.frames.enumerated().map { "\($0.offset)  \($0.element)" }.joined(separator: "\n"))
        ```

        **O que estava a fazer quando o Toth fechou? / What were you doing when Toth closed?**


        <!-- O relatório completo está na área de transferência: cole-o aqui se quiser (contém caminhos do seu computador).
             The full report is on the clipboard: paste it here if you wish (it contains paths from your computer). -->
        """
        var c = URLComponents(string: issuesURL)
        c?.queryItems = [URLQueryItem(name: "title", value: String(title.prefix(160))), URLQueryItem(name: "body", value: body), URLQueryItem(name: "labels", value: "bug")]
        return c?.url
    }

    // MARK: Aviso

    private static let seenKey = "crashReportsSeenUntil"

    /// O relatório novo desde a última verificação, se houver. Na primeira vez não há «novo»: fica só marcado o momento,
    /// para relatórios antigos (de outra instalação) não aparecerem.
    static func unseen(in dir: URL, bundleID: String, defaults: UserDefaults = .standard, now: Date = Date()) -> Report? {
        guard let seen = defaults.object(forKey: seenKey) as? Double else {
            defaults.set(now.timeIntervalSince1970, forKey: seenKey)
            return nil
        }
        return reports(in: dir, bundleID: bundleID).first { $0.date.timeIntervalSince1970 > seen }
    }
    static func markSeen(defaults: UserDefaults = .standard, now: Date = Date()) { defaults.set(now.timeIntervalSince1970, forKey: seenKey) }

    /// Ao abrir: passados uns segundos (o macOS demora a escrever o relatório), avisa se a sessão anterior falhou.
    @MainActor static func checkAtLaunch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard let r = unseen(in: folder, bundleID: Uninstaller.bundleID) else { return }
            markSeen()
            present(r, title: L("O Toth fechou inesperadamente"))
        }
    }

    /// Preferências → «Ver o último relatório de falha…».
    @MainActor static func showLatest() {
        if let r = reports(in: folder, bundleID: Uninstaller.bundleID).first {
            present(r, title: L("Último relatório de falha"))
        } else {
            let a = NSAlert()
            a.messageText = L("Sem relatórios de falha")
            a.informativeText = L("O macOS não tem nenhum relatório de falha do Toth.")
            a.runModal()
        }
    }

    @MainActor private static func present(_ r: Report, title: String) {
        NSApp.activate(ignoringOtherApps: true)
        let when = DateFormatter.localizedString(from: r.date, dateStyle: .medium, timeStyle: .short)
        while true {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = title
            a.informativeText = L("O macOS guardou um relatório da falha (%@, versão %@). Nada é enviado automaticamente: pode vê-lo, copiá-lo ou abrir um pedido no GitHub já preenchido com um resumo, para a falha ser corrigida.", when, r.version)
            a.addButton(withTitle: L("Abrir pedido no GitHub"))
            a.addButton(withTitle: L("Copiar relatório"))
            a.addButton(withTitle: L("Ver relatório"))
            a.addButton(withTitle: L("Fechar"))
            switch a.runModal() {
            case .alertFirstButtonReturn:
                copy(r)   // o relatório completo fica pronto a colar no pedido
                if let url = issueURL(for: r) { NSWorkspace.shared.open(url) }
                return
            case .alertSecondButtonReturn: copy(r)
            case .alertThirdButtonReturn: NSWorkspace.shared.open(r.url)
            default: return
            }
        }
    }

    @MainActor private static func copy(_ r: Report) {
        guard let text = try? String(contentsOf: r.url, encoding: .utf8) else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// `--crash-selftest <pasta>`: leitura de relatórios de faz de conta (nunca toca nos verdadeiros).
    static func selfTest(dir: URL) -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ m: String) { if !ok { fails.append(m) } }
        let fm = FileManager.default
        try? fm.removeItem(at: dir); try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = "io.github.lestatpirate.toth"
        func write(_ name: String, bundle: String?, at date: Date) {
            let header: [String: Any] = ["app_name": "Toth", "app_version": "0.6.5", "build_version": "70", "os_version": "macOS 27.2 (26C100)", "bug_type": "309"]
                .merging(bundle.map { ["bundleID": $0] } ?? [:]) { a, _ in a }
            let body: [String: Any] = [
                "exception": ["type": "EXC_BAD_ACCESS", "signal": "SIGSEGV"], "faultingThread": 1,
                "usedImages": [["name": "Toth", "path": "/Users/alguem/Applications/Toth.app/Contents/MacOS/Toth"], ["name": "AppKit"]],
                "threads": [["frames": [["imageIndex": 1, "symbol": "outra", "symbolLocation": 1]]],
                            ["triggered": true, "frames": [["imageIndex": 0, "symbol": "EditorModel.paste()", "symbolLocation": 124], ["imageIndex": 1, "symbol": "-[NSApplication sendAction:to:from:]", "symbolLocation": 60], ["imageIndex": 0, "imageOffset": 4096]]]],
            ]
            let h = String(data: try! JSONSerialization.data(withJSONObject: header), encoding: .utf8)!
            let b = String(data: try! JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted]), encoding: .utf8)!
            let u = dir.appendingPathComponent(name)
            try? (h + "\n" + b).write(to: u, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.modificationDate: date], ofItemAtPath: u.path)
        }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        write("Toth-2026-11-10-100000.ips", bundle: id, at: t0)
        write("Toth-2026-11-12-100000.ips", bundle: id, at: t0.addingTimeInterval(200))
        write("Toth-2026-11-13-100000.ips", bundle: nil, at: t0.addingTimeInterval(300))               // binário de desenvolvimento
        write("Toth-2026-11-14-100000.ips", bundle: "com.outra.toth", at: t0.addingTimeInterval(400))    // outra app com o mesmo nome
        write("Safari-2026-11-15-100000.ips", bundle: id, at: t0.addingTimeInterval(500))
        try? "lixo".write(to: dir.appendingPathComponent("Toth-estragado.ips"), atomically: true, encoding: .utf8)

        let all = reports(in: dir, bundleID: id)
        check(all.count == 2 && all.first?.url.lastPathComponent == "Toth-2026-11-12-100000.ips", "só contam os relatórios desta app, do mais recente para o mais antigo (\(all.map(\.url.lastPathComponent)))")
        guard let r = all.first else { return fails + ["sem relatório"] }
        check(r.version == "0.6.5" && r.build == "70" && r.exception == "EXC_BAD_ACCESS (SIGSEGV)", "lê a versão e a exceção (\(r.version), \(r.build), \(r.exception))")
        check(r.frames.first == "Toth  EditorModel.paste() + 124" && r.frames.count == 3 && r.frames[2] == "Toth  0x1000", "lê a thread que falhou (\(r.frames))")

        // pedido no GitHub: resumo sem caminhos do computador, endereço curto
        if let url = issueURL(for: r), let c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let body = c.queryItems?.first { $0.name == "body" }?.value ?? "", title = c.queryItems?.first { $0.name == "title" }?.value ?? ""
            check(url.absoluteString.hasPrefix(issuesURL) && url.absoluteString.count < 6000, "o endereço do pedido é do repositório e curto (\(url.absoluteString.count))")
            check(title.contains("EXC_BAD_ACCESS") && title.contains("EditorModel.paste()"), "o título diz a exceção e a função (\(title))")
            check(body.contains("0.6.5 (70)") && body.contains("EditorModel.paste() + 124") && !body.contains("/Users/"), "o resumo tem a versão e as funções, sem caminhos do computador")
        } else { fails.append("não construiu o endereço do pedido") }

        // só avisa do que é novo: a primeira vez marca o momento; depois, só relatórios posteriores
        let suite = "toth-crash-selftest"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        check(unseen(in: dir, bundleID: id, defaults: d, now: t0.addingTimeInterval(100)) == nil, "na primeira vez não há aviso (relatórios antigos não contam)")
        check(unseen(in: dir, bundleID: id, defaults: d)?.url.lastPathComponent == "Toth-2026-11-12-100000.ips", "um relatório posterior à última verificação é novo")
        markSeen(defaults: d, now: t0.addingTimeInterval(250))
        check(unseen(in: dir, bundleID: id, defaults: d) == nil, "depois de visto, não volta a avisar")
        d.removePersistentDomain(forName: suite)
        return fails
    }
}
