import Foundation

/// Jogo de PS4 é uma pasta (`CUSA00900/`) com `eboot.bin` e `sce_sys/param.sfo`. O shadPS4 abre o `eboot.bin`.
public enum PS4Game {
    public static let entry = "eboot.bin"

    public static func isGameFolder(_ url: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: url.appendingPathComponent(entry).path)
            && fm.fileExists(atPath: url.appendingPathComponent("sce_sys/param.sfo").path)
    }

    /// Nome da pasta no Deck: `Título [CUSA00900]`. Sem `param.sfo` legível, fica o nome da pasta.
    public static func folderName(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("sce_sys/param.sfo")),
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
