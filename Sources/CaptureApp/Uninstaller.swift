// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit

/// Desinstalar o Toth pela própria app (Preferências → «Desinstalar o Toth…»), sem deixar restos:
/// - preferências (`~/Library/Preferences/<id>.plist` e a antiga `Toth.plist`);
/// - dados de suporte (`~/Library/Application Support/Toth`: ícone personalizado, carimbos antigos);
/// - caches, estado guardado das janelas e ficheiros temporários (exportados para arrastar, atualizações descarregadas…);
/// - permissões do macOS (Gravação de Ecrã, Acessibilidade, Microfone): `tccutil reset All <id>`;
/// - a própria app, que vai para o Lixo.
/// As capturas são dados do utilizador: só vão para o Lixo se ele o pedir (e só o que é do Toth dentro da pasta).
///
/// O que depende de a app já não estar a correr (apagar as preferências sem o sistema as voltar a escrever, repor as
/// permissões) é feito por um pequeno comando de shell que espera pelo fim do processo.
enum Uninstaller {
    static var bundleID: String { Bundle.main.bundleIdentifier ?? "io.github.lestatpirate.toth" }

    /// Tudo o que o Toth deixa na pasta pessoal `home` (existam ou não), fora as capturas. `temp` é a pasta temporária.
    static func residues(home: URL, bundleID: String, temp: URL) -> [URL] {
        let lib = home.appendingPathComponent("Library", isDirectory: true)
        var out = [
            lib.appendingPathComponent("Preferences/\(bundleID).plist"),
            lib.appendingPathComponent("Preferences/Toth.plist"),                        // domínio antigo (antes do identificador)
            lib.appendingPathComponent("Application Support/Toth", isDirectory: true),
            lib.appendingPathComponent("Caches/\(bundleID)", isDirectory: true),
            lib.appendingPathComponent("HTTPStorages/\(bundleID)", isDirectory: true),
            lib.appendingPathComponent("HTTPStorages/\(bundleID).binarycookies"),
            lib.appendingPathComponent("Cookies/\(bundleID).binarycookies"),
            lib.appendingPathComponent("WebKit/\(bundleID)", isDirectory: true),
            lib.appendingPathComponent("Saved Application State/\(bundleID).savedState", isDirectory: true),
        ]
        // temporários: imagens exportadas para arrastar, atualizações descarregadas, gravações e edições a meio
        let prefixes = ["Toth-exportado", "toth-atualizacao-", "Toth-editado-", "Toth-gravacao-"]
        let items = (try? FileManager.default.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil)) ?? []
        out += items.filter { u in prefixes.contains { u.lastPathComponent.hasPrefix($0) } }
        return out
    }

    /// Apaga os que existirem. Devolve os que não foi possível apagar.
    @discardableResult
    static func remove(_ urls: [URL]) -> [URL] {
        var failed: [URL] = []
        for u in urls where FileManager.default.fileExists(atPath: u.path) {
            do { try FileManager.default.removeItem(at: u) } catch { failed.append(u) }
        }
        return failed
    }

    /// Tira da pasta das capturas o que é do Toth (capturas, vídeos, carimbos), com `discard` (por omissão, para o Lixo);
    /// o que lá estiver de outras origens fica. Se a pasta ficar vazia, é removida. Devolve quantos itens saíram.
    @discardableResult
    static func discardCaptures(in folder: URL, discard: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) -> Int {
        var n = 0
        for item in CaptureStore.ownedItems(in: folder) { if (try? discard(item)) != nil { n += 1 } }
        let rest = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        if rest.isEmpty { try? FileManager.default.removeItem(at: folder) }
        return n
    }

    /// O comando que corre depois de a app fechar: espera pelo processo, apaga as preferências (pelo sistema e o
    /// ficheiro), o estado guardado, e repõe as permissões. (Os argumentos vão entre plicas; nenhum vem do utilizador.)
    static func postExitScript(pid: Int32, bundleID: String, home: URL) -> String {
        let prefs = home.appendingPathComponent("Library/Preferences").path
        let state = home.appendingPathComponent("Library/Saved Application State/\(bundleID).savedState").path
        return """
        while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done
        /usr/bin/defaults delete '\(bundleID)' >/dev/null 2>&1
        /usr/bin/defaults delete Toth >/dev/null 2>&1
        /bin/rm -f '\(prefs)/\(bundleID).plist' '\(prefs)/Toth.plist'
        /bin/rm -rf '\(state)'
        /usr/bin/tccutil reset All '\(bundleID)' >/dev/null 2>&1
        """
    }

    /// Pergunta e, se confirmado, desinstala e fecha a app.
    @MainActor static func confirmAndRun() {
        let folder = CaptureStore.folder
        let captures = CaptureStore.ownedItems(in: folder).count
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Desinstalar o Toth?")
        alert.informativeText = L("O Toth vai para o Lixo e são removidas as preferências, os dados de suporte, as caches e as permissões do macOS (Gravação de Ecrã, Acessibilidade, Microfone). Não fica nada no sistema.")
        let keep = NSButton(checkboxWithTitle: L("Mover também as capturas para o Lixo (%d em %@)", captures, CaptureStore.shortPath(folder)), target: nil, action: nil)
        keep.state = .off
        keep.isEnabled = captures > 0
        alert.accessoryView = keep
        alert.addButton(withTitle: L("Desinstalar")).hasDestructiveAction = true
        alert.addButton(withTitle: L("Cancelar"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let trashCaptures = keep.state == .on
        if trashCaptures { discardCaptures(in: folder) }
        remove(residues(home: home, bundleID: bundleID, temp: FileManager.default.temporaryDirectory))
        UserDefaults.standard.removePersistentDomain(forName: bundleID)
        UserDefaults.standard.synchronize()

        // a app: para o Lixo (continua a correr até fechar). Em desenvolvimento, com o binário solto, não há pacote.
        var appTrashed = true
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            do { try FileManager.default.trashItem(at: bundle, resultingItemURL: nil) } catch { appTrashed = false }
        }

        let done = NSAlert()
        done.messageText = L("O Toth foi desinstalado")
        var text = trashCaptures ? L("As capturas foram para o Lixo; pode recuperá-las de lá.") : (captures > 0 ? L("As suas capturas continuam em %@.", CaptureStore.shortPath(folder)) : "")
        if !appTrashed { text += (text.isEmpty ? "" : "\n\n") + L("Não foi possível mover a app para o Lixo: arraste-a você mesmo da pasta Aplicações.") }
        done.informativeText = text
        done.addButton(withTitle: L("Fechar"))
        done.runModal()

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", postExitScript(pid: ProcessInfo.processInfo.processIdentifier, bundleID: bundleID, home: home)]
        task.standardInput = FileHandle.nullDevice; task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        try? task.run()
        exit(0)   // (sem passar pelo fecho normal: nada deve voltar a gravar preferências)
    }

    /// `--uninstall-selftest <pasta>`: a limpeza numa pasta pessoal de faz de conta (nunca toca na verdadeira).
    static func selfTest(dir: URL) -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ m: String) { if !ok { fails.append(m) } }
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        let home = dir.appendingPathComponent("home"), temp = dir.appendingPathComponent("tmp"), id = "io.github.lestatpirate.toth"
        func touch(_ path: String, in base: URL) -> URL {
            let u = base.appendingPathComponent(path)
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: u.path, contents: Data("x".utf8))
            return u
        }
        let mine = [
            touch("Library/Preferences/\(id).plist", in: home), touch("Library/Preferences/Toth.plist", in: home),
            touch("Library/Application Support/Toth/AppIcon-Custom.png", in: home), touch("Library/Caches/\(id)/Cache.db", in: home),
            touch("Library/HTTPStorages/\(id)/httpstorages.sqlite", in: home), touch("Library/Saved Application State/\(id).savedState/windows.plist", in: home),
            touch("Toth-exportado/Captura.png", in: temp), touch("toth-atualizacao-v9.9.9/Toth.zip", in: temp), touch("Toth-gravacao-ABC.mp4", in: temp),
        ]
        let others = [
            touch("Library/Preferences/com.outra.app.plist", in: home), touch("Library/Preferences/Capture.plist", in: home),
            touch("Library/Application Support/Outra/dados.db", in: home), touch("Library/Caches/com.outra.app/Cache.db", in: home),
            touch("outro-temporario.txt", in: temp),
        ]
        let failed = remove(residues(home: home, bundleID: id, temp: temp))
        check(failed.isEmpty, "não apagou: \(failed.map(\.lastPathComponent))")
        for u in mine { check(!fm.fileExists(atPath: u.path), "ficou um resto do Toth: \(u.lastPathComponent)") }
        check(!fm.fileExists(atPath: home.appendingPathComponent("Library/Application Support/Toth").path), "a pasta de suporte do Toth devia sair")
        for u in others { check(fm.fileExists(atPath: u.path), "apagou o que não é do Toth: \(u.path)") }

        // capturas: só sai o que é do Toth; o resto da pasta fica (e a pasta também)
        let caps = dir.appendingPathComponent("Capturas")
        let owned = [touch("Toth_2026-01-01.capture", in: caps), touch("Video.tothvideo/video.mp4", in: caps).deletingLastPathComponent(), touch("Carimbos/a.png", in: caps).deletingLastPathComponent()]
        let foreign = touch("ferias.jpg", in: caps)
        let n = discardCaptures(in: caps) { try fm.removeItem(at: $0) }
        check(n == 3, "saíram \(n) itens do Toth (deviam ser 3)")
        for u in owned { check(!fm.fileExists(atPath: u.path), "a captura \(u.lastPathComponent) devia sair") }
        check(fm.fileExists(atPath: foreign.path), "um ficheiro que não é do Toth ficou na pasta")
        // pasta só com coisas do Toth: fica vazia e é removida
        let only = dir.appendingPathComponent("SoToth")
        _ = touch("A.capture", in: only)
        discardCaptures(in: only) { try fm.removeItem(at: $0) }
        check(!fm.fileExists(atPath: only.path), "a pasta que ficou vazia é removida")

        let script = postExitScript(pid: 4242, bundleID: id, home: home)
        check(script.contains("kill -0 4242") && script.contains("tccutil reset All '\(id)'") && script.contains("defaults delete '\(id)'"), "o comando final espera pelo processo, apaga as preferências e repõe as permissões")
        return fails
    }
}
