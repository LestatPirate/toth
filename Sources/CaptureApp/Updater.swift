// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit
import CaptureCore
import CryptoKit

/// Atualizações: o Toth pergunta ao GitHub (API pública de *releases*) se há uma versão nova; se houver, o
/// utilizador escolhe atualizar ou não. É o único pedido à internet que a app faz (ver PRIVACY.md); não envia
/// identificadores nem dados. Pode ser desligado em Preferências. Nada é instalado sem confirmação.

enum UpdateError: LocalizedError, Equatable {
    case network(String)
    case noRelease
    case noChecksum
    case checksumMismatch
    case badArchive
    case wrongApp
    case notNewer
    case notWritable(String)
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case let .network(m): L("Não foi possível contactar o servidor de atualizações (%@).", m)
        case .noRelease: L("Não encontrei uma versão utilizável no servidor de atualizações.")
        case .noChecksum: L("A versão não traz a soma de verificação (SHA-256), por isso não a instalo automaticamente.")
        case .checksumMismatch: L("O ficheiro descarregado não corresponde à soma de verificação (SHA-256): foi descartado.")
        case .badArchive: L("O ficheiro descarregado não é uma aplicação Toth válida.")
        case .wrongApp: L("O ficheiro descarregado não é do Toth.")
        case .notNewer: L("A versão descarregada não é mais recente do que a instalada.")
        case let .notWritable(p): L("Não tenho permissão para substituir a aplicação em %@.", p)
        case let .installFailed(m): L("A instalação falhou: %@", m)
        }
    }
}

/// A parte que não mexe na interface (por isso testa-se sem ecrã).
enum UpdateEngine {
    static let defaultFeed = URL(string: "https://api.github.com/repos/LestatPirate/toth/releases/latest")!

    static func fetchLatest(feed: URL, userAgent: String) async throws -> ReleaseInfo {
        var req = URLRequest(url: feed, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await URLSession.shared.data(for: req) }
        catch { throw UpdateError.network(error.localizedDescription) }
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 { throw UpdateError.noRelease }
            if http.statusCode == 403 || http.statusCode == 429 { throw UpdateError.network(L("limite de pedidos; tente mais tarde")) }
            if !(200..<300).contains(http.statusCode) { throw UpdateError.network("HTTP \(http.statusCode)") }
        }
        guard let release = ReleaseInfo.parse(data) else { throw UpdateError.noRelease }
        return release
    }

    /// Descarrega o ficheiro da versão para `dir` e devolve o caminho.
    static func download(_ r: ReleaseInfo, into dir: URL, userAgent: String) async throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var req = URLRequest(url: r.assetURL, timeoutInterval: 60)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let tmp: URL
        do { (tmp, _) = try await URLSession.shared.download(for: req) }
        catch { throw UpdateError.network(error.localizedDescription) }
        let zip = dir.appendingPathComponent(r.assetName)
        try? FileManager.default.removeItem(at: zip)
        try FileManager.default.moveItem(at: tmp, to: zip)
        return zip
    }

    static func sha256(of file: URL) throws -> String {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Confere a soma de verificação, descomprime, e valida que é o Toth e que é mais recente. Devolve a `.app`.
    static func verifyAndExtract(zip: URL, expectedSHA256: String?, into dir: URL, currentVersion: AppVersion,
                                 bundleID: String, checkSignature: Bool) throws -> URL {
        guard let expected = expectedSHA256 else { throw UpdateError.noChecksum }
        guard try sha256(of: zip) == expected.lowercased() else { throw UpdateError.checksumMismatch }

        let out = dir.appendingPathComponent("extraido", isDirectory: true)
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, out.path]
        try unzip.run(); unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw UpdateError.badArchive }

        let items = (try? FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)) ?? []
        guard let app = items.first(where: { $0.pathExtension == "app" }), let bundle = Bundle(url: app) else { throw UpdateError.badArchive }
        guard bundle.bundleIdentifier == bundleID else { throw UpdateError.wrongApp }
        guard let v = (bundle.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init), v > currentVersion else { throw UpdateError.notNewer }
        if checkSignature {
            let verify = Process()
            verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            verify.arguments = ["--verify", "--deep", "--strict", app.path]
            verify.standardError = Pipe()
            try verify.run(); verify.waitUntilExit()
            guard verify.terminationStatus == 0 else { throw UpdateError.badArchive }
        }
        return app
    }

    /// Script que troca a app depois de ela fechar (uma app em execução não pode ser substituída por ela própria).
    /// Se algo falhar, repõe a anterior. Arguments: PID, NOVA, ATUAL, [sem-abrir].
    static let installerScript = """
    #!/bin/sh
    PID="$1"; NEW="$2"; TARGET="$3"; NOOPEN="$4"
    exec >> "$(dirname "$NEW")/instalacao.log" 2>&1
    echo "inicio $(date)"
    n=0
    while kill -0 "$PID" 2>/dev/null && [ "$n" -lt 150 ]; do sleep 0.2; n=$((n+1)); done
    BACKUP="$TARGET.anterior"
    rm -rf "$BACKUP"
    if mv "$TARGET" "$BACKUP"; then
      if /usr/bin/ditto "$NEW" "$TARGET"; then
        /usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
        rm -rf "$BACKUP"
        echo "atualizada"
      else
        echo "falhou ao copiar: repoe a anterior"
        rm -rf "$TARGET"; mv "$BACKUP" "$TARGET"
      fi
    else
      echo "nao foi possivel mover a app atual"
    fi
    [ "$NOOPEN" = "sem-abrir" ] || /usr/bin/open "$TARGET"
    echo "fim"
    """

    /// Lança o script (fica a correr depois de a app fechar). `waitForScript`: para testes.
    @discardableResult
    static func launchInstaller(newApp: URL, target: URL, waitForPID pid: Int32, reopen: Bool, waitForScript: Bool = false) throws -> Process {
        let dir = newApp.deletingLastPathComponent()
        let script = dir.appendingPathComponent("instalar.sh")
        try installerScript.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path, String(pid), newApp.path, target.path, reopen ? "abrir" : "sem-abrir"]
        p.standardInput = nil; p.standardOutput = nil; p.standardError = nil
        try p.run()
        if waitForScript { p.waitUntilExit() }
        return p
    }
}

@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    /// Para testes: outro endereço de verificação e outra app a substituir (ver `--update-e2e`).
    nonisolated(unsafe) static var feedOverride: URL?
    /// Para testes: aceita a atualização sem perguntar (nunca é ligado num uso normal).
    nonisolated(unsafe) static var autoAccept = false

    private let defaults = UserDefaults.standard
    private var busy = false

    @Published var automatic: Bool {
        didSet { defaults.set(automatic, forKey: "updateAutoCheck") }
    }

    private init() {
        automatic = (defaults.object(forKey: "updateAutoCheck") as? Bool) ?? true
    }

    var currentVersion: AppVersion {
        AppVersion((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0") ?? AppVersion("0")!
    }
    var currentVersionText: String { currentVersion.description }

    private var userAgent: String { "Toth/\(currentVersionText)" }
    private var feed: URL { Self.feedOverride ?? UpdateEngine.defaultFeed }
    private var lastCheck: Date? {
        get { defaults.object(forKey: "updateLastCheck") as? Date }
        set { defaults.set(newValue, forKey: "updateLastCheck") }
    }
    private var skippedTag: String? {
        get { defaults.string(forKey: "updateSkippedTag") }
        set { defaults.set(newValue, forKey: "updateSkippedTag") }
    }

    // MARK: Quando procurar

    /// Ao abrir a app e ao voltar a ela: procura em silêncio se a verificação automática está ligada e já passou um dia.
    func checkIfDue() {
        guard automatic, UpdateSchedule.isDue(last: lastCheck) else { return }
        Task { await check(userInitiated: false) }
    }

    /// «Procurar atualizações…» (menu e Preferências): responde sempre, com ou sem versão nova.
    func checkNow() { Task { await check(userInitiated: true) } }

    // MARK: Procurar

    private func check(userInitiated: Bool) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            let release = try await UpdateEngine.fetchLatest(feed: feed, userAgent: userAgent)
            lastCheck = Date()
            if release.isNewer(than: currentVersion) {
                if !userInitiated && skippedTag == release.tag { return }
                await offer(release)
            } else if userInitiated {
                let a = NSAlert()
                a.messageText = L("O Toth está atualizado")
                a.informativeText = L("Está a usar a versão mais recente (%@).", currentVersionText)
                NSApp.activate(ignoringOtherApps: true)
                a.runModal()
            }
        } catch {
            if userInitiated {
                let a = NSAlert(error: error)
                a.messageText = L("Não foi possível procurar atualizações")
                NSApp.activate(ignoringOtherApps: true)
                a.runModal()
            }
        }
    }

    // MARK: Oferecer

    private func offer(_ r: ReleaseInfo) async {
        if Self.autoAccept { await install(r); return }
        let a = NSAlert()
        a.messageText = L("Há uma versão nova do Toth: %@", r.version.description)
        a.informativeText = L("Está a usar a versão %@. Quer atualizar agora? O Toth fecha e volta a abrir sozinho; as suas capturas não são tocadas.", currentVersionText)
        a.accessoryView = Self.notesView(r.notes)
        a.addButton(withTitle: L("Atualizar agora"))
        a.addButton(withTitle: L("Mais tarde"))
        a.addButton(withTitle: L("Ignorar esta versão"))
        NSApp.activate(ignoringOtherApps: true)
        switch a.runModal() {
        case .alertFirstButtonReturn: await install(r)
        case .alertThirdButtonReturn: skippedTag = r.tag
        default: break   // «Mais tarde»: volta a perguntar daqui a um dia
        }
    }

    private static func notesView(_ notes: String) -> NSView {
        let text = String(notes.prefix(1400))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 150))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let tv = NSTextView(frame: scroll.bounds)
        tv.isEditable = false; tv.string = text; tv.font = .systemFont(ofSize: 12)
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.isVerticallyResizable = true; tv.autoresizingMask = [.width]
        scroll.documentView = tv
        return scroll
    }

    // MARK: Instalar

    private func install(_ r: ReleaseInfo) async {
        let progress = UpdateProgressWindow(title: L("A atualizar o Toth…"), detail: L("A descarregar a versão %@", r.version.description))
        progress.show()
        defer { progress.close() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("toth-atualizacao-\(r.tag)", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        do {
            let zip = try await UpdateEngine.download(r, into: dir, userAgent: userAgent)
            progress.setDetail(L("A verificar o ficheiro…"))
            let app = try UpdateEngine.verifyAndExtract(zip: zip, expectedSHA256: r.sha256, into: dir, currentVersion: currentVersion,
                                                        bundleID: Bundle.main.bundleIdentifier ?? "io.github.lestatpirate.toth", checkSignature: true)
            let target = Bundle.main.bundleURL
            guard Bundle.main.bundleURL.pathExtension == "app" else { throw UpdateError.installFailed(L("a app não está empacotada")) }
            guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
                throw UpdateError.notWritable(target.deletingLastPathComponent().path)
            }
            progress.setDetail(L("A instalar…"))
            try UpdateEngine.launchInstaller(newApp: app, target: target, waitForPID: ProcessInfo.processInfo.processIdentifier, reopen: true)
            NSApp.terminate(nil)
        } catch {
            progress.close()
            let a = NSAlert(error: error)
            a.messageText = L("Não foi possível atualizar")
            a.informativeText = (error.localizedDescription) + "\n\n" + L("Pode descarregar a versão manualmente na página das versões.")
            a.addButton(withTitle: L("Abrir a página das versões"))
            a.addButton(withTitle: L("Fechar"))
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(r.pageURL) }
        }
    }
}

/// Janela pequena com um indicador a girar enquanto se descarrega e instala.
@MainActor
final class UpdateProgressWindow {
    private let panel: NSPanel
    private let detail = NSTextField(labelWithString: "")

    init(title: String, detail text: String) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 96), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = title
        panel.isReleasedWhenClosed = false
        let spinner = NSProgressIndicator(frame: NSRect(x: 20, y: 40, width: 24, height: 24))
        spinner.style = .spinning; spinner.startAnimation(nil)
        detail.frame = NSRect(x: 56, y: 40, width: 290, height: 24)
        detail.stringValue = text
        panel.contentView?.addSubview(spinner)
        panel.contentView?.addSubview(detail)
        panel.center()
    }

    func show() { panel.makeKeyAndOrderFront(nil) }
    func setDetail(_ s: String) { detail.stringValue = s }
    func close() { panel.orderOut(nil) }
}
