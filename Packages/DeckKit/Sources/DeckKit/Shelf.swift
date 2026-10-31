import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Onde mora o acervo. Compartilhamentos SMB/NFS entram como `folder`, já montados pelo macOS.
public enum ShelfSource: Codable, Hashable, Sendable {
    case folder(path: String)
    case ssh(host: String, user: String, port: Int, path: String)
    case service(url: String)

    public var label: String {
        switch self {
        case let .folder(path): path
        case let .ssh(host, user, _, path): "\(user)@\(host):\(path)"
        case let .service(url): url
        }
    }
}

/// Um arquivo do acervo, como a varredura o encontrou.
public struct ScanRecord: Codable, Hashable, Sendable {
    public var path: String
    public var size: Int64
    public var mtime: Int64
    public var crc: String
    public var sha1: String
    /// Início do arquivo em base64, só quando a pasta não diz o sistema.
    public var head: String?
    /// Conteúdo de `.cue`/`.gdi`, para achar as faixas sem baixar nada.
    public var text: String?

    public init(path: String, size: Int64, mtime: Int64, crc: String, sha1: String, head: String? = nil, text: String? = nil) {
        self.path = path
        self.size = size
        self.mtime = mtime
        self.crc = crc
        self.sha1 = sha1
        self.head = head
        self.text = text
    }
}

public struct ShelfItem: Codable, Hashable, Identifiable, Sendable {
    /// Hash do maior arquivo do jogo: igual em cópias da mesma ROM, em qualquer pasta.
    public var id: String
    public var title: String
    public var systemID: String
    public var entry: String
    public var members: [String]
    public var size: Int64
    public var crc: String
    /// Achado num DAT do usuário.
    public var verified: Bool
    public var duplicates: [String]

    /// Nome que a Biblioteca e o atalho usam: vem do arquivo no Deck, não do DAT.
    public var deckTitle: String { ROMPlan.displayName((entry as NSString).lastPathComponent) }
}

/// Base de hashes dos DATs No-Intro/Redump que o usuário fornece.
public struct DatIndex: Sendable {
    private var bySHA1: [String: String] = [:]
    private var byCRC: [String: String] = [:]

    public init() {}

    public mutating func add(game: String, sha1: String?, crc: String?, size: Int64?) {
        if let sha1, !sha1.isEmpty { bySHA1[sha1.lowercased()] = game }
        if let crc, !crc.isEmpty { byCRC[crc.lowercased() + ":" + String(size ?? -1)] = game }
    }

    /// SHA1 primeiro; CRC só vale junto com o tamanho, porque 32 bits colidem em acervos grandes.
    public func game(sha1: String, crc: String, size: Int64) -> String? {
        bySHA1[sha1.lowercased()] ?? byCRC[crc.lowercased() + ":" + String(size)]
    }

    public var count: Int { bySHA1.count }

    /// Logiqx XML ou clrmamepro, pelo primeiro caractere útil.
    public mutating func load(_ data: Data) {
        let start = data.prefix(64).first { ![0x20, 0x0A, 0x0D, 0x09, 0xEF, 0xBB, 0xBF].contains($0) }
        if start == UInt8(ascii: "<") {
            let delegate = LogiqxDelegate()
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            parser.parse()
            for r in delegate.roms { add(game: r.game, sha1: r.sha1, crc: r.crc, size: r.size) }
        } else {
            loadClrMamePro(String(decoding: data, as: UTF8.self))
        }
    }

    private mutating func loadClrMamePro(_ text: String) {
        var game: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("name "), game == nil || !line.contains(" size ") {
                game = Self.quoted(String(line.dropFirst(5)))
            } else if line.hasPrefix("rom ("), let game {
                add(game: game, sha1: Self.field("sha1", line), crc: Self.field("crc", line), size: Self.field("size", line).flatMap { Int64($0) })
            }
        }
    }

    private static func quoted(_ s: String) -> String { s.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }

    private static func field(_ key: String, _ line: String) -> String? {
        let parts = line.replacingOccurrences(of: "(", with: " ").replacingOccurrences(of: ")", with: " ").split(separator: " ").map(String.init)
        guard let i = parts.firstIndex(of: key), i + 1 < parts.count else { return nil }
        return parts[i + 1]
    }
}

private final class LogiqxDelegate: NSObject, XMLParserDelegate {
    struct ROM { var game: String; var sha1: String?; var crc: String?; var size: Int64? }
    var roms: [ROM] = []
    private var game: String?

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        if name == "game" || name == "machine" { game = a["name"] }
        if name == "rom", let game { roms.append(ROM(game: game, sha1: a["sha1"], crc: a["crc"], size: a["size"].flatMap { Int64($0) })) }
    }
}

public enum ShelfIndex {
    private static func stem(_ path: String) -> String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }

    /// Junta faixas ao índice, detecta o sistema e funde cópias. Devolve à parte o que serve em mais de um sistema.
    public static func build(_ records: [ScanRecord], systems: [GameSystem], dats: DatIndex) -> (items: [ShelfItem], undecided: [ScanRecord]) {
        let detector = ROMDetector(systems: systems)
        let byPath = Dictionary(records.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var memberOf: [String: String] = [:]
        for r in records where ["cue", "gdi"].contains((r.path as NSString).pathExtension.lowercased()) {
            let dir = (r.path as NSString).deletingLastPathComponent
            for name in ROMPlan.referencedFiles(cueSheet: r.text ?? "", extension: (r.path as NSString).pathExtension) {
                memberOf[(dir as NSString).appendingPathComponent(name)] = r.path
            }
        }

        var items: [String: ShelfItem] = [:]
        var undecided: [ScanRecord] = []
        for r in records.sorted(by: { $0.path < $1.path }) where memberOf[r.path] == nil {
            let members = memberOf.filter { $0.value == r.path }.keys.sorted()
            let parts = ([r] + members.compactMap { byPath[$0] })
            let main = parts.max { $0.size < $1.size } ?? r
            let head = main.head.flatMap { Data(base64Encoded: $0) } ?? Data()
            let systemID: String
            switch detector.detect(path: r.path, prefix: head, size: main.size) {
            case let .system(id): systemID = id
            case .ambiguous:
                undecided.append(r)
                continue
            case .unknown: continue // Capa, manual, readme: não é jogo.
            }
            let match = dats.game(sha1: main.sha1, crc: main.crc, size: main.size)
            let key = main.sha1
            if var existing = items[key] {
                existing.duplicates.append(r.path)
                items[key] = existing
                continue
            }
            items[key] = ShelfItem(id: key, title: match ?? ROMPlan.displayName((r.path as NSString).lastPathComponent), systemID: systemID,
                                   entry: r.path, members: members, size: parts.reduce(0) { $0 + $1.size }, crc: main.crc,
                                   verified: match != nil, duplicates: [])
        }
        return (items.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }, undecided)
    }
}

/// O que remover quando o jogo não cabe.
public enum SpaceAdvisor {
    public struct Installed: Equatable, Sendable {
        public var title: String
        public var size: Int64
        public var lastPlayed: Int64

        public init(title: String, size: Int64, lastPlayed: Int64) {
            self.title = title
            self.size = size
            self.lastPlayed = lastPlayed
        }
    }

    /// Margem para o sistema de arquivos não ficar cheio depois de instalar.
    public static let reserve: Int64 = 1_073_741_824

    public static func fits(size: Int64, free: Int64) -> Bool { free - size >= reserve }

    /// Os jogados há mais tempo primeiro, até caber. Vazio quando já cabe ou não há como caber.
    public static func suggest(size: Int64, free: Int64, installed: [Installed]) -> [Installed] {
        var missing = size + reserve - free
        guard missing > 0 else { return [] }
        var chosen: [Installed] = []
        for game in installed.sorted(by: { ($0.lastPlayed, -$0.size) < ($1.lastPlayed, -$1.size) }) {
            chosen.append(game)
            missing -= game.size
            if missing <= 0 { return chosen }
        }
        return []
    }
}
