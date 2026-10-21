// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import Foundation

/// Versão do tipo `0.1.5.5` ou `1.2.0` (qualquer número de componentes). Compara-se componente a componente,
/// com zeros à direita implícitos (`1.0` = `1.0.0`). Um prefixo `v` e um sufixo `-beta` são ignorados.
public struct AppVersion: Comparable, Hashable, CustomStringConvertible, Sendable {
    public let parts: [Int]

    public init?(_ text: String) {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
        if let dash = t.firstIndex(where: { $0 == "-" || $0 == "+" }) { t = String(t[..<dash]) }
        let comps = t.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !comps.isEmpty, comps.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        parts = comps.map { $0! }
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0, y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }
    public func hash(into h: inout Hasher) {   // consistente com == (zeros à direita não contam)
        var p = parts; while p.last == 0 { p.removeLast() }; h.combine(p)
    }
}

/// O que a app precisa de saber de uma release do GitHub para oferecer a atualização.
public struct ReleaseInfo: Equatable, Sendable {
    public var tag: String
    public var version: AppVersion
    public var name: String
    public var notes: String
    public var pageURL: URL
    public var assetName: String
    public var assetURL: URL
    public var sha256: String?          // da descrição do ficheiro (`digest`) ou da nota da release
    public var isPrerelease: Bool

    /// Lê a resposta de `GET /repos/{dono}/{repo}/releases/latest` da API do GitHub. `nil` se não houver uma versão
    /// utilizável (rascunho, sem número de versão, sem o ficheiro `Toth-….zip`).
    public static func parse(_ data: Data, assetPrefix: String = "Toth-") -> ReleaseInfo? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        guard (root["draft"] as? Bool) != true, let tag = root["tag_name"] as? String, let version = AppVersion(tag) else { return nil }
        let notes = (root["body"] as? String) ?? ""
        guard let page = (root["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let assets = (root["assets"] as? [[String: Any]]) ?? []
        guard let asset = assets.first(where: {
            let n = ($0["name"] as? String) ?? ""
            return n.hasPrefix(assetPrefix) && n.hasSuffix(".zip")
        }), let name = asset["name"] as? String,
              let url = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)) else { return nil }

        var sha: String?
        if let d = asset["digest"] as? String, d.lowercased().hasPrefix("sha256:") { sha = String(d.dropFirst(7)).lowercased() }
        if sha == nil {   // «SHA-256 do zip: `…`» na nota: a primeira sequência de 64 hexadecimais logo a seguir
            var from = notes.startIndex
            while sha == nil, let r = notes.range(of: #"(?i)sha-?256"#, options: .regularExpression, range: from..<notes.endIndex) {
                let tail = notes[r.upperBound...].prefix(120)
                if let h = String(tail).range(of: #"(?<![0-9a-fA-F])[0-9a-fA-F]{64}(?![0-9a-fA-F])"#, options: .regularExpression) { sha = String(String(tail)[h]).lowercased() }
                from = r.upperBound
            }
        }
        return ReleaseInfo(tag: tag, version: version, name: (root["name"] as? String) ?? tag, notes: notes, pageURL: page,
                           assetName: name, assetURL: url, sha256: sha, isPrerelease: (root["prerelease"] as? Bool) ?? false)
    }

    /// Há uma versão mais recente do que `current`?
    public func isNewer(than current: AppVersion) -> Bool { !isPrerelease && version > current }
}

/// Quando voltar a procurar: no máximo uma vez por dia.
public enum UpdateSchedule {
    public static let interval: TimeInterval = 24 * 3600
    public static func isDue(last: Date?, now: Date = Date()) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= interval || last > now.addingTimeInterval(60)   // relógio mudado para trás: volta a procurar
    }
}
