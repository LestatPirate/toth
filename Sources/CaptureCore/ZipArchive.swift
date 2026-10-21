// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import Foundation

/// ZIP mínimo, só Foundation (portável): escreve e lê entradas **sem compressão** (método 0).
/// As imagens PNG já vão comprimidas, por isso comprimir mais não compensa; o ficheiro continua a ser um
/// ZIP normal que qualquer ferramenta abre.
public enum ZipArchive {
    public enum Failure: Error, Equatable {
        case notAZip, corrupt(String), unsupportedCompression(entry: String, method: UInt16), tooLarge
    }

    // MARK: CRC-32

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) == 1 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }

    // MARK: Escrita

    private static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    private static func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }

    /// Constrói o ZIP em memória. A ordem das entradas é a alfabética (resultado determinístico).
    public static func make(_ entries: [String: Data]) throws -> Data {
        var out = Data()
        var central = Data()
        var count: UInt16 = 0
        // 1 jan 2024 00:00 (data fixa: o conteúdo não depende da hora de gravação)
        let dosTime: UInt16 = 0, dosDate: UInt16 = (44 << 9) | (1 << 5) | 1
        for name in entries.keys.sorted() {
            let data = entries[name]!
            let nameBytes = Array(name.utf8)
            guard data.count < 0xFFFF_FFFF, out.count < 0xFFFF_FFFF, nameBytes.count < 0xFFFF, count < 0xFFFF else { throw Failure.tooLarge }
            let crc = crc32(data), size = UInt32(data.count), offset = UInt32(out.count)

            out.append(contentsOf: le32(0x04034b50) + le16(20) + le16(0x0800) + le16(0) + le16(dosTime) + le16(dosDate)
                       + le32(crc) + le32(size) + le32(size) + le16(UInt16(nameBytes.count)) + le16(0))
            out.append(contentsOf: nameBytes)
            out.append(data)

            central.append(contentsOf: le32(0x02014b50) + le16(20) + le16(20) + le16(0x0800) + le16(0) + le16(dosTime) + le16(dosDate)
                           + le32(crc) + le32(size) + le32(size) + le16(UInt16(nameBytes.count)) + le16(0) + le16(0)
                           + le16(0) + le16(0) + le32(0) + le32(offset))
            central.append(contentsOf: nameBytes)
            count += 1
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        out.append(contentsOf: le32(0x06054b50) + le16(0) + le16(0) + le16(count) + le16(count)
                   + le32(UInt32(central.count)) + le32(cdOffset) + le16(0))
        return out
    }

    // MARK: Leitura

    public struct Entry: Equatable {
        public let name: String
        public let method: UInt16
        public let compressedSize: Int
        public let size: Int
        let localOffset: Int
        let crc: UInt32
    }

    private static func u16(_ d: Data, _ o: Int) -> Int { Int(d[d.startIndex + o]) | Int(d[d.startIndex + o + 1]) << 8 }
    private static func u32(_ d: Data, _ o: Int) -> Int { u16(d, o) | u16(d, o + 2) << 16 }

    /// Lê o índice (diretório central) a partir do fim do ficheiro, sem carregar os dados.
    public static func index(of handle: FileHandle) throws -> [Entry] {
        let fileSize = Int(try handle.seekToEnd())
        guard fileSize >= 22 else { throw Failure.notAZip }
        let tailLen = min(fileSize, 22 + 0xFFFF)
        try handle.seek(toOffset: UInt64(fileSize - tailLen))
        let tail = try handle.read(upToCount: tailLen) ?? Data()
        // procura a assinatura do fim de diretório, de trás para a frente
        guard let eocd = (0...(tail.count - 22)).reversed().first(where: { u32(tail, $0) == 0x06054b50 }) else { throw Failure.notAZip }
        let total = u16(tail, eocd + 10), cdSize = u32(tail, eocd + 12), cdOffset = u32(tail, eocd + 16)
        guard cdOffset + cdSize <= fileSize else { throw Failure.corrupt("diretório central fora do ficheiro") }

        try handle.seek(toOffset: UInt64(cdOffset))
        let cd = try handle.read(upToCount: cdSize) ?? Data()
        var entries: [Entry] = []
        var p = 0
        for _ in 0..<total {
            guard p + 46 <= cd.count, u32(cd, p) == 0x02014b50 else { throw Failure.corrupt("entrada inválida") }
            let nameLen = u16(cd, p + 28), extraLen = u16(cd, p + 30), commentLen = u16(cd, p + 32)
            guard p + 46 + nameLen <= cd.count else { throw Failure.corrupt("nome fora do diretório") }
            let nameData = cd.subdata(in: (cd.startIndex + p + 46)..<(cd.startIndex + p + 46 + nameLen))
            entries.append(Entry(name: String(decoding: nameData, as: UTF8.self), method: UInt16(u16(cd, p + 10)),
                                 compressedSize: u32(cd, p + 20), size: u32(cd, p + 24),
                                 localOffset: u32(cd, p + 42), crc: UInt32(u32(cd, p + 16))))
            p += 46 + nameLen + extraLen + commentLen
        }
        return entries
    }

    /// Lê os dados de uma entrada e confere o CRC.
    public static func read(_ entry: Entry, from handle: FileHandle) throws -> Data {
        guard entry.method == 0 else { throw Failure.unsupportedCompression(entry: entry.name, method: entry.method) }
        try handle.seek(toOffset: UInt64(entry.localOffset))
        guard let header = try handle.read(upToCount: 30), header.count == 30, u32(header, 0) == 0x04034b50 else {
            throw Failure.corrupt("cabeçalho local de \(entry.name)")
        }
        let skip = u16(header, 26) + u16(header, 28)
        try handle.seek(toOffset: UInt64(entry.localOffset + 30 + skip))
        let data = try handle.read(upToCount: entry.compressedSize) ?? Data()
        guard data.count == entry.size else { throw Failure.corrupt("tamanho de \(entry.name)") }
        guard crc32(data) == entry.crc else { throw Failure.corrupt("CRC de \(entry.name)") }
        return data
    }

    /// Lê todas as entradas.
    public static func readAll(at url: URL) throws -> [String: Data] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var out: [String: Data] = [:]
        for e in try index(of: handle) where !e.name.hasSuffix("/") { out[e.name] = try read(e, from: handle) }
        return out
    }

    /// Lê uma só entrada, sem carregar o resto (usado nas miniaturas).
    public static func readEntry(_ name: String, at url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let e = try? index(of: handle).first(where: { $0.name == name }) else { return nil }
        return try? read(e, from: handle)
    }
}
