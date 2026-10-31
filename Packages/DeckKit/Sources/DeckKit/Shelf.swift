import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Onde mora o acervo. Sempre um servidor do próprio usuário: não existe lista remota de fontes.
public enum ShelfSource: Codable, Hashable, Sendable {
    case folder(path: String)
    /// Montados pelo macOS em `mounts/<id>`, e daí em diante são uma pasta.
    case smb(url: String)
    case nfs(url: String)
    case ssh(host: String, user: String, port: Int, path: String)
    case webdav(url: String)
    case s3(endpoint: String, region: String, bucket: String, prefix: String, accessKey: String)
    case romm(url: String)
    case service(url: String)

    public var label: String {
        switch self {
        case let .folder(path): path
        case let .smb(url), let .nfs(url), let .webdav(url), let .romm(url), let .service(url): url
        case let .ssh(host, user, _, path): "\(user)@\(host):\(path)"
        case let .s3(endpoint, _, bucket, prefix, _): "\(endpoint)/\(bucket)/\(prefix)"
        }
    }
}

/// Fonte cadastrada. O segredo fica no Keychain, nunca aqui.
public struct LibrarySource: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Menor vem primeiro.
    public var priority: Int
    public var kind: ShelfSource
    /// Pasta do usuário → sistema, para acervos fora do formato `<fonte>/<sistema>/<arquivos>`.
    public var folderMap: [String: String]

    public init(id: UUID = UUID(), name: String, priority: Int, kind: ShelfSource, folderMap: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.priority = priority
        self.kind = kind
        self.folderMap = folderMap
    }
}

public enum SourceState: String, Codable, Sendable {
    case online, offline, badCredentials
}

/// Arquivo de um jogo no RomM: cada faixa tem o próprio id de download.
public struct RemoteFile: Codable, Hashable, Sendable {
    public var id: Int
    public var name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}

/// Onde o jogo pode ser buscado.
public struct ShelfOrigin: Codable, Hashable, Sendable {
    public var sourceID: UUID
    public var entry: String
    public var members: [String]
    public var files: [RemoteFile]

    public init(sourceID: UUID, entry: String, members: [String], files: [RemoteFile] = []) {
        self.sourceID = sourceID
        self.entry = entry
        self.members = members
        self.files = files
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
    /// SHA1 sem os 16 bytes do cabeçalho iNES: há DATs de NES que só listam a ROM crua.
    public var headerless: String?
    /// Só RomM: o servidor já organizou e identificou o jogo.
    public var systemID: String?
    public var title: String?
    public var meta: ShelfMeta?
    public var cover: String?
    public var files: [RemoteFile]?

    public init(path: String, size: Int64, mtime: Int64, crc: String, sha1: String, head: String? = nil, text: String? = nil, headerless: String? = nil) {
        self.path = path
        self.size = size
        self.mtime = mtime
        self.crc = crc
        self.sha1 = sha1
        self.head = head
        self.text = text
        self.headerless = headerless
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
    /// Em ordem de prioridade; a primeira é `entry`.
    public var origins: [ShelfOrigin] = []
    public var cover: String?
    /// Metadados que a própria fonte já traz.
    public var meta: ShelfMeta?

    /// Nome que a Biblioteca e o atalho usam: vem do arquivo no Deck, não do DAT.
    public var deckTitle: String { ROMPlan.displayName((entry as NSString).lastPathComponent) }
}

/// Item do catálogo "Grátis e legal". Regras de entrada em CATALOG.md.
public struct FreeGame: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var system: String
    public var year: Int
    public var author: String
    public var version: String
    public var license: String
    public var licenseURL: String
    public var homepage: String
    public var download: String
    public var sha256: String
    public var size: Int64
    /// Arquivo principal dentro do `.zip`.
    public var inner: String?

    public var fileName: String { (download as NSString).lastPathComponent }

    /// Instalar e remover seguem o caminho da Estante. O prefixo evita colidir com um hash do acervo.
    public var item: ShelfItem {
        ShelfItem(id: "free:" + id, title: title, systemID: system, entry: inner ?? fileName, members: [], size: size, crc: "", verified: true, duplicates: [], origins: [])
    }
}

/// Metadados para a vitrine. Sem URLs: as do ScreenScraper carregam as credenciais do usuário.
public struct ShelfMeta: Codable, Hashable, Sendable {
    public var title: String?
    public var summary: String?
    public var year: Int?
    public var developer: String?
    public var players: String?
    public var genres: [String] = []

    public init() {}
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

    /// Só WebDAV e S3 ficam sem hash: calcular exigiria baixar o acervo inteiro. Identidade por nome e tamanho.
    private static func weakKey(_ path: String, _ size: Int64) -> String {
        "name:\((path as NSString).lastPathComponent.lowercased()):\(size)"
    }

    /// Fontes em ordem de prioridade: a primeira que tem o jogo vira o `entry`, as outras viram alternativas.
    public static func build(_ sources: [(source: LibrarySource, records: [ScanRecord])], systems: [GameSystem], dats: DatIndex) -> (items: [ShelfItem], undecided: [ScanRecord]) {
        let detector = ROMDetector(systems: systems)
        var items: [String: ShelfItem] = [:]
        var weak: [String: String] = [:]
        var undecided: [ScanRecord] = []
        for (source, records) in sources.sorted(by: { $0.source.priority < $1.source.priority }) {
            let byPath = Dictionary(records.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
            var memberOf: [String: String] = [:]
            for r in records where ["cue", "gdi"].contains((r.path as NSString).pathExtension.lowercased()) {
                let dir = (r.path as NSString).deletingLastPathComponent
                for name in ROMPlan.referencedFiles(cueSheet: r.text ?? "", extension: (r.path as NSString).pathExtension) {
                    memberOf[(dir as NSString).appendingPathComponent(name)] = r.path
                }
            }
            for r in records.sorted(by: { $0.path < $1.path }) where memberOf[r.path] == nil {
                let members = memberOf.filter { $0.value == r.path }.keys.sorted()
                let parts = [r] + members.compactMap { byPath[$0] }
                let main = parts.max { $0.size < $1.size } ?? r
                let head = main.head.flatMap { Data(base64Encoded: $0) } ?? Data()
                let systemID: String
                let mapped = source.folderMap.first { r.path.contains("/\($0.key)/") || r.path.hasPrefix("\($0.key)/") }?.value
                switch r.systemID ?? mapped {
                case let id?: systemID = id
                case nil:
                    switch detector.detect(path: r.path, prefix: head, size: main.size) {
                    case let .system(id): systemID = id
                    case .ambiguous:
                        undecided.append(r)
                        continue
                    case .unknown: continue // Capa, manual, readme: não é jogo.
                    }
                }
                let match = dats.game(sha1: main.sha1, crc: main.crc, size: main.size)
                    ?? main.headerless.flatMap { dats.game(sha1: $0, crc: "", size: main.size - 16) }
                let origin = ShelfOrigin(sourceID: source.id, entry: r.path, members: members, files: r.files ?? [])
                let name = weakKey(main.path, main.size)
                let key = main.sha1.isEmpty ? (weak[name] ?? name) : main.sha1
                if let same = items[key] ?? weak[name].flatMap({ items[$0] }) {
                    var existing = same
                    if existing.origins.contains(where: { $0.sourceID == source.id }) {
                        existing.duplicates.append(r.path)
                    } else {
                        existing.origins.append(origin)
                    }
                    items[existing.id] = existing
                    continue
                }
                var item = ShelfItem(id: key, title: r.title ?? match ?? ROMPlan.displayName((r.path as NSString).lastPathComponent), systemID: systemID,
                                     entry: r.path, members: members, size: parts.reduce(0) { $0 + $1.size }, crc: main.crc,
                                     verified: match != nil, duplicates: [], origins: [origin])
                item.cover = r.cover
                item.meta = r.meta
                items[key] = item
                weak[name] = key
            }
        }
        return (items.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }, undecided)
    }

    /// Fonte única sem configuração.
    public static func build(_ records: [ScanRecord], systems: [GameSystem], dats: DatIndex) -> (items: [ShelfItem], undecided: [ScanRecord]) {
        build([(LibrarySource(name: "", priority: 0, kind: .folder(path: "")), records)], systems: systems, dats: dats)
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
