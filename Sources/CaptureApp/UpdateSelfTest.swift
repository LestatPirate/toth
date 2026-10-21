// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import AppKit
import CaptureCore

/// Autoteste do motor de atualização com uma «release» falsa em ficheiros locais (sem internet nem tocar na app instalada).
enum UpdateSelfTest {
    static func makeApp(at root: URL, version: String, bundleID: String = "io.github.lestatpirate.toth") throws -> URL {
        let app = root.appendingPathComponent("Toth.app")
        try? FileManager.default.removeItem(at: app)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>\(bundleID)</string>
        <key>CFBundleShortVersionString</key><string>\(version)</string>
        <key>CFBundleExecutable</key><string>Toth</string>
        </dict></plist>
        """
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 0\n".write(to: app.appendingPathComponent("Contents/MacOS/Toth"), atomically: true, encoding: .utf8)
        return app
    }

    static func version(of app: URL) -> String? { Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String }

    static func run(dir: URL) async -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { fails.append(what) } }
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return ["sem pasta de teste: \(error)"] }

        do {
            // a «release» falsa: Toth 9.9.9 num zip, com o seu SHA-256 no feed
            let build = dir.appendingPathComponent("construir")
            let newApp = try makeApp(at: build, version: "9.9.9")
            let zip = dir.appendingPathComponent("Toth-9.9.9.zip")
            let z = Process(); z.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            z.arguments = ["-c", "-k", "--keepParent", newApp.path, zip.path]
            try z.run(); z.waitUntilExit()
            let sha = try UpdateEngine.sha256(of: zip)
            func feed(_ name: String, sha: String?, tag: String = "v9.9.9") throws -> URL {
                let digest = sha.map { ",\"digest\":\"sha256:\($0)\"" } ?? ""
                let json = "{\"tag_name\":\"\(tag)\",\"name\":\"Toth\",\"draft\":false,\"prerelease\":false,\"html_url\":\"https://example.org/r\",\"body\":\"notas\",\"assets\":[{\"name\":\"Toth-9.9.9.zip\",\"browser_download_url\":\"\(zip.absoluteString)\"\(digest)}]}"
                let f = dir.appendingPathComponent(name)
                try json.write(to: f, atomically: true, encoding: .utf8)
                return f
            }
            let good = try feed("feed-bom.json", sha: sha)

            // 1) ler o feed
            let r = try await UpdateEngine.fetchLatest(feed: good, userAgent: "Toth/teste")
            check(r.version == AppVersion("9.9.9") && r.sha256 == sha, "feed mal lido: \(r)")
            check(r.isNewer(than: AppVersion("0.1.5.5")!), "9.9.9 devia ser mais recente do que 0.1.5.5")
            do { _ = try await UpdateEngine.fetchLatest(feed: dir.appendingPathComponent("nao-existe.json"), userAgent: "Toth/teste"); fails.append("feed inexistente devia dar erro") } catch {}

            // 2) descarregar e verificar
            let work = dir.appendingPathComponent("trabalho")
            let got = try await UpdateEngine.download(r, into: work, userAgent: "Toth/teste")
            let extracted = try UpdateEngine.verifyAndExtract(zip: got, expectedSHA256: r.sha256, into: work, currentVersion: AppVersion("0.1.5.5")!,
                                                              bundleID: "io.github.lestatpirate.toth", checkSignature: false)
            check(version(of: extracted) == "9.9.9", "versão extraída \(version(of: extracted) ?? "nil")")

            func expect(_ err: UpdateError, _ what: String, sha: String?, current: String = "0.1.5.5", id: String = "io.github.lestatpirate.toth") {
                do {
                    _ = try UpdateEngine.verifyAndExtract(zip: got, expectedSHA256: sha, into: work, currentVersion: AppVersion(current)!, bundleID: id, checkSignature: false)
                    fails.append("\(what): devia falhar")
                } catch let e as UpdateError { check(e == err, "\(what): erro \(e), esperado \(err)") } catch { fails.append("\(what): \(error)") }
            }
            expect(.checksumMismatch, "SHA-256 errado", sha: String(repeating: "0", count: 64))
            expect(.noChecksum, "sem SHA-256", sha: nil)
            expect(.notNewer, "versão não mais recente", sha: sha, current: "10.0")
            expect(.wrongApp, "outra aplicação", sha: sha, id: "com.outra.app")

            // 3) instalar: troca a app e não deixa cópia de segurança
            let install = dir.appendingPathComponent("instalacao")
            let target = try makeApp(at: install, version: "0.0.1")
            let ext2 = try UpdateEngine.verifyAndExtract(zip: got, expectedSHA256: r.sha256, into: dir.appendingPathComponent("trabalho2"), currentVersion: AppVersion("0.0.1")!,
                                                         bundleID: "io.github.lestatpirate.toth", checkSignature: false)
            try UpdateEngine.launchInstaller(newApp: ext2, target: target, waitForPID: 999_999, reopen: false, waitForScript: true)
            check(version(of: target) == "9.9.9", "a app devia ter passado a 9.9.9 (é \(version(of: target) ?? "nil"))")
            check(!fm.fileExists(atPath: target.path + ".anterior"), "a cópia de segurança devia ter sido apagada")

            // 4) se a cópia falhar, repõe a anterior
            let target2 = try makeApp(at: dir.appendingPathComponent("instalacao2"), version: "0.0.1")
            let missing = dir.appendingPathComponent("trabalho3/Toth.app")
            try fm.createDirectory(at: missing.deletingLastPathComponent(), withIntermediateDirectories: true)
            try UpdateEngine.launchInstaller(newApp: missing, target: target2, waitForPID: 999_999, reopen: false, waitForScript: true)
            check(version(of: target2) == "0.0.1", "se a cópia falhar devia ficar a versão anterior (é \(version(of: target2) ?? "nil"))")
            check(!fm.fileExists(atPath: target2.path + ".anterior"), "não devia sobrar cópia de segurança depois de repor")

            // 5) espera que a app feche antes de a trocar
            let target3 = try makeApp(at: dir.appendingPathComponent("instalacao3"), version: "0.0.1")
            let sleeper = Process(); sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep"); sleeper.arguments = ["2"]
            try sleeper.run()
            let started = Date()
            let ext3 = try UpdateEngine.verifyAndExtract(zip: got, expectedSHA256: r.sha256, into: dir.appendingPathComponent("trabalho4"), currentVersion: AppVersion("0.0.1")!,
                                                         bundleID: "io.github.lestatpirate.toth", checkSignature: false)
            try UpdateEngine.launchInstaller(newApp: ext3, target: target3, waitForPID: sleeper.processIdentifier, reopen: false, waitForScript: true)
            check(Date().timeIntervalSince(started) >= 1.5, "o instalador devia esperar que o processo terminasse (esperou \(Date().timeIntervalSince(started)) s)")
            check(version(of: target3) == "9.9.9", "depois de esperar devia ter trocado")
        } catch { fails.append("exceção: \(error)") }
        try? fm.removeItem(at: dir)
        return fails
    }
}
