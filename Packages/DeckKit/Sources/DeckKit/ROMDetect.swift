import Foundation

public enum ROMDetection: Equatable, Sendable {
    case system(String)
    /// Vários sistemas aceitam o arquivo: a UI pergunta em vez de chutar.
    case ambiguous([String])
    case unknown
}

/// Ordem de confiança: pasta de origem, cabeçalho, extensão exclusiva.
public struct ROMDetector: Sendable {
    public let systems: [GameSystem]
    /// Quanto do início do arquivo `detect` precisa ler.
    public static let prefixLength = 1 << 20

    public init(systems: [GameSystem]) { self.systems = systems }

    public func detect(path: String, prefix: Data, size: Int64) -> ROMDetection {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        let accepting = systems.filter { $0.extensions.contains(ext) }

        for folder in url.deletingLastPathComponent().pathComponents.reversed().prefix(3) {
            let name = folder.lowercased()
            if let s = systems.first(where: { $0.id == name || $0.aliases.contains(name) }),
               s.extensions.contains(ext) || ext.isEmpty { return .system(s.id) }
        }
        if let id = Self.header(prefix, size: size), systems.contains(where: { $0.id == id }) { return .system(id) }
        switch accepting.count {
        case 0: return .unknown
        case 1: return .system(accepting[0].id)
        default:
            // zip e 7z entram em quase tudo, e nessa altura não dizem nada.
            return .ambiguous(accepting.map(\.id))
        }
    }

    public static func header(_ d: Data, size: Int64) -> String? {
        func at(_ offset: Int, _ text: String) -> Bool { match(d, offset, Array(text.utf8)) }
        func at(_ offset: Int, _ bytes: [UInt8]) -> Bool { match(d, offset, bytes) }

        // `.pkg` existe nos dois: PS3 começa com `\x7FPKG`, PS4 com `\x7FCNT`.
        if at(0, [0x7F, 0x50, 0x4B, 0x47]) { return "ps3" }
        if at(0, [0x7F, 0x43, 0x4E, 0x54]) { return "ps4" }
        if at(0, [0x4E, 0x45, 0x53, 0x1A]) || at(0, [0x46, 0x44, 0x53, 0x1A]) { return "nes" }
        if at(0, [0x80, 0x37, 0x12, 0x40]) || at(0, [0x37, 0x80, 0x40, 0x12]) || at(0, [0x40, 0x12, 0x37, 0x80]) { return "n64" }
        let logo: [UInt8] = [0x24, 0xFF, 0xAE, 0x51, 0x69, 0x9A, 0xA2, 0x21]
        if at(0x04, logo) { return "gba" }
        if at(0xC0, logo) { return "nds" }
        if at(0x104, [0xCE, 0xED, 0x66, 0x66]) {
            return d.count > 0x143 && d[d.startIndex + 0x143] & 0x80 != 0 ? "gbc" : "gb"
        }
        if at(0x100, "NCSD") { return "n3ds" }
        if at(0x100, "SEGA 32X") { return "sega32x" }
        if at(0x100, "SEGA") { return "genesis" }
        if at(0x7FF0, "TMR SEGA") { return "mastersystem" }
        if at(0x1C, [0xC2, 0x33, 0x9F, 0x3D]) { return "gc" }
        if at(0x18, [0x5D, 0x1C, 0x9E, 0xA3]) { return "wii" }
        if at(0x10000, "MICROSOFT*XBOX*MEDIA") { return "xbox" }
        for offset in [0, 0x10] {
            if at(offset, "SEGA SEGASATURN") { return "saturn" }
            if at(offset, "SEGA SEGAKATANA") { return "dreamcast" }
            if at(offset, "SEGADISCSYSTEM") { return "segacd" }
        }
        // Volume ISO 9660: setor de 2048 bytes (0x8001) ou imagem crua de 2352 (0x9319).
        for pvd in [0x8001, 0x9319] where at(pvd, "CD001") {
            if at(pvd + 7, "PSP GAME") { return "psp" }
            if at(pvd + 7, "PLAYSTATION") { return playStation(d, size: size) }
        }
        return nil
    }

    private static func playStation(_ d: Data, size: Int64) -> String? {
        if d.range(of: Data("BOOT2".utf8)) != nil { return "ps2" }
        if d.range(of: Data("BOOT =".utf8)) != nil || d.range(of: Data("BOOT=".utf8)) != nil { return "psx" }
        return size > 900_000_000 ? "ps2" : nil
    }

    private static func match(_ d: Data, _ offset: Int, _ bytes: [UInt8]) -> Bool {
        guard offset + bytes.count <= d.count else { return false }
        let start = d.startIndex + offset
        return d[start..<(start + bytes.count)].elementsEqual(bytes)
    }
}

/// Decide o que fazer com cada jogo antes de enviar. Funções puras: quem executa é o `RomImporter`.
public enum ROMPlan {
    public enum Conversion: String, Codable, Sendable { case cd = "createcd", dvd = "createdvd" }

    public static let discTrackExtensions: Set<String> = ["cue", "gdi", "toc", "iso"]
    private static let dvdThreshold: Int64 = 900_000_000

    /// `chdman` só entende o que tem índice; `.bin` solto não dá para converter sem o `.cue`.
    public static func conversion(for system: GameSystem, fileExtension: String, size: Int64) -> Conversion? {
        guard let mode = system.chd, discTrackExtensions.contains(fileExtension.lowercased()) else { return nil }
        if mode == "auto", fileExtension.lowercased() == "iso", size > dvdThreshold { return .dvd }
        return .cd
    }

    public static func mustExtract(system: GameSystem, fileExtension: String) -> Bool {
        ["zip", "7z"].contains(fileExtension.lowercased()) && !system.readsArchives
    }

    /// Ryubing e Eden só abrem `.nsp` e `.xci`: o compactado do Switch nunca vai como está.
    public static func mustDecompress(fileExtension: String) -> Bool {
        ["nsz", "xcz"].contains(fileExtension.lowercased())
    }

    /// Arquivos citados por um `.cue` ou `.gdi`: viajam junto e não contam como jogos separados.
    public static func referencedFiles(cueSheet text: String, extension ext: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let s = line.trimmingCharacters(in: .whitespaces)
            if ext.lowercased() == "cue" {
                guard s.uppercased().hasPrefix("FILE ") else { return nil }
                if let first = s.firstIndex(of: "\""), let last = s.lastIndex(of: "\""), first != last {
                    return String(s[s.index(after: first)..<last])
                }
                return s.split(separator: " ").dropFirst().first.map(String.init)
            }
            // GDI: `<faixa> <lba> <tipo> <tamanho> <arquivo> 0`; o arquivo pode vir entre aspas.
            let fields = s.split(separator: " ", maxSplits: 4).map(String.init)
            guard fields.count == 5, Int(fields[0]) != nil else { return nil }
            let rest = fields[4]
            if rest.hasPrefix("\""), let end = rest.dropFirst().firstIndex(of: "\"") { return String(rest[rest.index(after: rest.startIndex)..<end]) }
            return rest.split(separator: " ").first.map(String.init)
        }
    }

    /// "Game (Disc 2).chd" vira "Game" + 2. `nil` quando o nome não indica disco.
    public static func discInfo(_ fileName: String) -> (base: String, number: Int)? {
        let stem = (fileName as NSString).deletingPathExtension
        let pattern = #"[ _-]*[\(\[]?(?:disc|disk|cd)[ _-]*([0-9]+|[a-d])(?: of [0-9]+)?[\)\]]?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let matches = regex.matches(in: stem, range: NSRange(stem.startIndex..., in: stem))
        guard let m = matches.last, let r = Range(m.range, in: stem), let g = Range(m.range(at: 1), in: stem) else { return nil }
        let token = stem[g].lowercased()
        let number = Int(token) ?? Int(token.unicodeScalars.first!.value) - 96
        let base = (String(stem[..<r.lowerBound]) + String(stem[r.upperBound...])).trimmingCharacters(in: .whitespaces)
        return base.isEmpty ? nil : (base, number)
    }

    /// Agrupa discos do mesmo jogo. Só conjuntos com 2+ discos ganham `.m3u`, com nomes relativos.
    public static func playlists(for fileNames: [String]) -> [(name: String, contents: String)] {
        var groups: [String: [(Int, String)]] = [:]
        for name in fileNames {
            if let info = discInfo(name) { groups[info.base, default: []].append((info.number, name)) }
        }
        return groups.filter { $0.value.count > 1 }.sorted { $0.key < $1.key }.map { base, discs in
            (base + ".m3u", discs.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: "\n") + "\n")
        }
    }

    /// Nome do jogo na biblioteca do Steam: tira extensão, marcações de disco e as do dump do Switch.
    public static func displayName(_ fileName: String) -> String {
        let name = discInfo(fileName)?.base ?? (fileName as NSString).deletingPathExtension
        return name.replacingOccurrences(of: #"\s*(\[[0-9A-Fa-f]{16}\]|\[[A-Z]{4}[0-9]{5}\]|\[v[0-9]+\]|\([0-9.]+ [GM]B\))"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Nome de capa: sem região/idioma/revisão do nome de ROM e com o artigo de volta à frente
    /// ("Legend of Zelda, The - The Wind Waker (USA)" → "The Legend of Zelda - The Wind Waker").
    public static func coverTitle(_ title: String) -> String {
        let tags = #"\s*\((USA|Europe|Japan|World|Brazil|Korea|Asia|En|Fr|De|Es|It|Pt|Rev [0-9A-Z]+|v[0-9.]+|[A-Z][a-z](,[A-Z][a-z])+)[^)]*\)"#
        var t = title.replacingOccurrences(of: tags, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if let m = t.range(of: #"^(.+?), (The|A|An)(\b.*)$"#, options: .regularExpression) {
            let parts = t[m].split(separator: ",", maxSplits: 1)
            let rest = parts[1].trimmingCharacters(in: .whitespaces)
            let article = rest.split(separator: " ", maxSplits: 1)
            t = "\(article[0]) \(parts[0])" + (article.count > 1 ? " " + article[1] : "")
        }
        return t
    }

    /// Nome do atalho no Steam: o da capa sem etiqueta de mod, tradução ou dump (`[…]`).
    /// Quem chama mantém o nome longo quando dois jogos ficariam com o mesmo nome curto.
    public static func shortcutName(_ title: String) -> String {
        let tags = #"(?i)\s*(\([^)]*\b(mod|mods|translation|translated|tradu[cç][aã]o|traduzido|patch|patched|hack|dub|dubbed|dublado)\b[^)]*\)|\[[^\]]*\])"#
        let clean = coverTitle(title).replacingOccurrences(of: tags, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return clean.isEmpty ? title : clean
    }

    /// Title ID do Switch: jogo base termina em `000`; update (`800`) e DLC não abrem sozinhos.
    public static func isSwitchAddon(_ fileName: String) -> Bool {
        guard let id = fileName.range(of: #"\[[0-9A-Fa-f]{16}\]"#, options: .regularExpression) else { return false }
        return !fileName[id].lowercased().hasSuffix("000]")
    }
}
