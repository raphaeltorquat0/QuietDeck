import Foundation

/// Compatibilidade com o nome antigo: o PS4 virou um caso de `GameFolder`.
public enum PS4Game {
    public static let entry = "eboot.bin"
    public static func isGameFolder(_ url: URL) -> Bool { GameFolder.system(url) == "ps4" }
    public static func folderName(_ url: URL) -> String { GameFolder.folderName(url) }
}

/// Jogo que é uma pasta: PS4 (`CUSA…/eboot.bin`) e disco de PS3 (`PS3_GAME/USRDIR/EBOOT.BIN`).
/// O nome no Deck sai do `PARAM.SFO` de cada um.
public enum GameFolder {
    static let kinds: [(system: String, marker: String, sfo: String)] = [
        ("ps4", "eboot.bin", "sce_sys/param.sfo"),
        ("ps3", "PS3_GAME/USRDIR/EBOOT.BIN", "PS3_GAME/PARAM.SFO"),
    ]

    public static func system(_ url: URL) -> String? {
        let fm = FileManager.default
        return kinds.first { fm.fileExists(atPath: url.appendingPathComponent($0.marker).path) && fm.fileExists(atPath: url.appendingPathComponent($0.sfo).path) }?.system
    }

    /// `Título [ID]`, ou o nome da pasta quando o `PARAM.SFO` não é legível.
    public static func folderName(_ url: URL) -> String {
        guard let kind = kinds.first(where: { $0.system == system(url) }),
              let data = try? Data(contentsOf: url.appendingPathComponent(kind.sfo)),
              let sfo = ParamSFO.parse(data), let title = sfo["TITLE"], !title.isEmpty else { return url.lastPathComponent }
        let clean = title.components(separatedBy: CharacterSet(charactersIn: "/:\n\r\t")).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard let id = sfo["TITLE_ID"], !id.isEmpty else { return clean }
        return "\(clean) [\(id)]"
    }
}

/// `param.sfo` do PS4/PS3: cabeçalho `\0PSF`, tabela de índices de 16 bytes, chaves e valores. Só texto UTF-8.
public enum ParamSFO {
    public static func parse(_ data: Data) -> [String: String]? {
        let d = [UInt8](data)
        func u16(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        guard d.count >= 20, d.starts(with: [0, 0x50, 0x53, 0x46]) else { return nil }
        let keys = u32(8), values = u32(12), count = u32(16)
        guard 20 + count * 16 <= d.count else { return nil }
        var result: [String: String] = [:]
        for i in 0..<count {
            let e = 20 + i * 16
            let keyStart = keys + u16(e), format = u16(e + 2), length = u32(e + 4), valueStart = values + u32(e + 12)
            guard format == 0x0204, keyStart < d.count, valueStart + length <= d.count,
                  let keyEnd = d[keyStart...].firstIndex(of: 0) else { continue }
            let key = String(decoding: d[keyStart..<keyEnd], as: UTF8.self)
            let raw = d[valueStart..<valueStart + length]
            result[key] = String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return result
    }
}
