import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import DeckKit

/// Segredo de uma fonte, como sai do Keychain.
public struct SourceSecret: Codable, Hashable, Sendable {
    public var user: String
    public var password: String
    public var token: String

    public init(user: String = "", password: String = "", token: String = "") {
        self.user = user
        self.password = password
        self.token = token
    }
}

/// `/usr/bin/curl` em vez de `URLSession`: assina S3, serve HTTP de rede local sem exceção de ATS e retoma download.
/// Segredo vai pela entrada padrão, nunca em `argv`, onde o `ps` veria.
enum Curl {
    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    static func bearer(_ token: String) -> String { "header = " + quote("Authorization: Bearer \(token)") }
    static func basic(_ user: String, _ password: String) -> String { "user = " + quote("\(user):\(password)") }
    static func config(_ lines: [String]) -> Data { Data((lines.joined(separator: "\n") + "\n").utf8) }

    static func request(_ url: String, options: [String] = [], auth: [String]) async throws -> (status: Int, body: String) {
        let r = try await LocalProcess.run("/usr/bin/curl", ["-sS", "-L", "-m", "120", "-K", "-", "-w", "\n%{http_code}"] + options + [url], stdin: config(auth))
        // Conexão recusada ou DNS: nem chegou a haver HTTP.
        guard r.ok, let cut = r.stdout.lastIndex(of: "\n"), let status = Int(r.stdout[cut...].dropFirst()) else {
            return (0, "")
        }
        return (status, String(r.stdout[..<cut]))
    }

    /// Retoma de onde parou; servidor sem Range começa de novo.
    static func download(_ url: String, to path: String, options: [String] = [], auth: [String]) async throws {
        var r = try await LocalProcess.run("/usr/bin/curl", ["-fsS", "-L", "-K", "-", "-C", "-", "-o", path] + options + [url], stdin: config(auth))
        if r.exitCode == 33 {
            try? FileManager.default.removeItem(atPath: path)
            r = try await LocalProcess.run("/usr/bin/curl", ["-fsS", "-L", "-K", "-", "-o", path] + options + [url], stdin: config(auth))
        }
        // O comando do erro nunca leva a URL completa: uma fonte pode tê-la assinada.
        guard r.ok else { throw DeckError.unexpectedState("Couldn't download %@.", (path as NSString).lastPathComponent) }
    }
}

/// Cada tipo de fonte fala seu protocolo aqui; o resto da Estante só vê `ScanRecord`.
public struct SourceClient: Sendable {
    public let source: LibrarySource
    public let secret: SourceSecret
    let sshKey: String
    let knownHosts: String
    /// Pasta real de uma fonte montada pelo macOS.
    let mountPath: String?

    public init(source: LibrarySource, secret: SourceSecret, sshKey: String, knownHosts: String, mountPath: String? = nil) {
        self.source = source
        self.secret = secret
        self.sshKey = sshKey
        self.knownHosts = knownHosts
        self.mountPath = mountPath
    }

    static func trimmed(_ url: String) -> String { url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }

    private var ssh: SSHConfig? {
        guard case let .ssh(host, user, port, _) = source.kind else { return nil }
        return SSHConfig(host: host, port: port, user: user, identityFile: sshKey, knownHostsFile: knownHosts)
    }

    private static func state(_ status: Int) -> SourceState {
        switch status {
        case 200..<300, 207: .online
        case 401, 403: .badCredentials
        default: .offline
        }
    }

    // MARK: Teste de conexão

    public func probe() async -> SourceState {
        switch source.kind {
        case let .folder(path):
            return FileManager.default.fileExists(atPath: path) ? .online : .offline
        case .smb, .nfs:
            return mountPath.map { FileManager.default.fileExists(atPath: $0) } == true ? .online : .offline
        case .ssh:
            guard let ssh, let r = try? await SSHRunner(config: ssh).run("true") else { return .offline }
            return r.ok ? .online : (r.stderr.contains("Permission denied") ? .badCredentials : .offline)
        case let .webdav(url):
            let r = try? await Curl.request(url, options: Self.propfind, auth: davAuth)
            return Self.state(r?.status ?? 0)
        case .s3:
            let r = try? await list(token: nil, keys: 1)
            return Self.state(r?.status ?? 0)
        case let .romm(url):
            let beat = try? await Curl.request(Self.trimmed(url) + "/api/heartbeat", auth: [])
            guard beat?.status == 200 else { return .offline }
            let r = try? await Curl.request(Self.trimmed(url) + "/api/platforms", auth: [Curl.bearer(secret.token)])
            return Self.state(r?.status ?? 0)
        case let .service(url):
            let r = try? await Curl.request(Self.trimmed(url) + "/index", options: ["-o", "/dev/null"], auth: [Curl.bearer(secret.token)])
            return Self.state(r?.status ?? 0)
        }
    }

    // MARK: Varredura

    public func scan(systems: [GameSystem], cache: ShelfScanner.Cache) async throws -> [ScanRecord] {
        switch source.kind {
        case let .folder(path):
            return try await ShelfScanner.scanFolder(URL(fileURLWithPath: path), systems: systems, cache: cache)
        case .smb, .nfs:
            guard let mountPath else { throw DeckError.unexpectedState("%@ isn't available.", source.name) }
            return try await ShelfScanner.scanFolder(URL(fileURLWithPath: mountPath), systems: systems, cache: cache)
        case let .ssh(_, _, _, path):
            guard let ssh else { return [] }
            return try await ShelfScanner.scanRemote(SSHRunner(config: ssh), root: path, systems: systems, cache: cache)
        case let .service(url):
            let r = try await Curl.request(Self.trimmed(url) + "/index", auth: [Curl.bearer(secret.token)])
            try check(r.status)
            return try JSONDecoder().decode([ScanRecord].self, from: Data(r.body.utf8))
        case .webdav: return try await scanWebDAV()
        case .s3: return try await scanS3()
        case .romm: return try await scanRomM()
        }
    }

    private func check(_ status: Int) throws {
        switch Self.state(status) {
        case .online: return
        case .badCredentials: throw DeckError.unexpectedState("%@ refused your credentials.", source.name)
        case .offline: throw DeckError.unexpectedState("Couldn't reach %@.", source.name)
        }
    }

    // MARK: WebDAV

    private var davAuth: [String] { secret.user.isEmpty ? [] : [Curl.basic(secret.user, secret.password)] }
    private static let propfind = ["-X", "PROPFIND", "-H", "Depth: 1", "-H", "Content-Type: application/xml", "--data-raw",
                                   #"<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>"#]

    /// `Depth: infinity` é recusado por muitos servidores, então a árvore é percorrida pasta a pasta.
    private func scanWebDAV() async throws -> [ScanRecord] {
        guard case let .webdav(root) = source.kind else { return [] }
        let origin = Self.origin(root)
        var pending = [Self.trimmed(root) + "/"], records: [ScanRecord] = []
        while let folder = pending.popLast() {
            let r = try await Curl.request(folder, options: Self.propfind, auth: davAuth)
            try check(r.status)
            let own = URL(string: folder)?.path ?? folder
            for entry in WebDAV.parse(Data(r.body.utf8)) where entry.href.trimmingCharacters(in: CharacterSet(charactersIn: "/")) != own.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
                if entry.isCollection {
                    pending.append(origin + Self.encode(entry.href, trailingSlash: true))
                } else if !(entry.href as NSString).lastPathComponent.hasPrefix(".") {
                    var record = ScanRecord(path: entry.href, size: entry.size, mtime: entry.modified, crc: "", sha1: "")
                    record.text = try await sheet(origin + Self.encode(entry.href), name: entry.href, size: entry.size, auth: davAuth)
                    records.append(record)
                }
            }
        }
        return records
    }

    /// `.cue` é pequeno e diz quais faixas são do mesmo jogo.
    private func sheet(_ url: String, name: String, size: Int64, auth: [String], options: [String] = []) async throws -> String? {
        guard ["cue", "gdi"].contains((name as NSString).pathExtension.lowercased()), size < 65536 else { return nil }
        return try await Curl.request(url, options: options, auth: auth).body
    }

    static func origin(_ url: String) -> String {
        guard let u = URLComponents(string: url), let scheme = u.scheme, let host = u.host else { return url }
        return "\(scheme)://\(host)" + (u.port.map { ":\($0)" } ?? "")
    }

    static func encode(_ path: String, trailingSlash: Bool = false) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~/")
        let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        return trailingSlash && !encoded.hasSuffix("/") ? encoded + "/" : encoded
    }

    // MARK: S3

    private var s3Options: [String] { ["-H", "x-amz-content-sha256: UNSIGNED-PAYLOAD"] }

    private var s3Auth: [String] {
        guard case let .s3(_, region, _, _, accessKey) = source.kind else { return [] }
        return [Curl.basic(accessKey, secret.password), "aws-sigv4 = " + Curl.quote("aws:amz:\(region):s3")]
    }

    private func list(token: String?, keys: Int) async throws -> (status: Int, body: String) {
        guard case let .s3(endpoint, _, bucket, prefix, _) = source.kind else { return (0, "") }
        var u = URLComponents(string: Self.trimmed(endpoint) + "/" + bucket)
        u?.queryItems = [.init(name: "list-type", value: "2"), .init(name: "max-keys", value: String(keys)), .init(name: "prefix", value: prefix)]
            + (token.map { [.init(name: "continuation-token", value: $0)] } ?? [])
        // A assinatura exige `+` e `/` codificados na query.
        let query = u?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").replacingOccurrences(of: "/", with: "%2F")
        u?.percentEncodedQuery = query
        guard let url = u?.string else { return (0, "") }
        return try await Curl.request(url, options: s3Options, auth: s3Auth)
    }

    private func objectURL(_ key: String) -> String? {
        guard case let .s3(endpoint, _, bucket, _, _) = source.kind else { return nil }
        return Self.trimmed(endpoint) + "/" + bucket + "/" + Self.encode(key)
    }

    private func scanS3() async throws -> [ScanRecord] {
        var token: String?, records: [ScanRecord] = []
        repeat {
            let r = try await list(token: token, keys: 1000)
            try check(r.status)
            let page = S3.parse(Data(r.body.utf8))
            if let code = page.error { throw DeckError.unexpectedState("%@ answered %@. Check the API key in Settings.", source.name, code) }
            for object in page.objects where !object.key.hasSuffix("/") {
                var record = ScanRecord(path: object.key, size: object.size, mtime: object.modified, crc: "", sha1: "")
                if let url = objectURL(object.key) {
                    record.text = try await sheet(url, name: object.key, size: object.size, auth: s3Auth, options: s3Options)
                }
                records.append(record)
            }
            token = page.next
        } while token != nil
        return records
    }

    // MARK: RomM

    /// Slug do RomM → sistema do QuietDeck, quando diferem do id (`platform_slugs.py`, rommapp/romm@78a634e).
    static let rommSlugs = ["dc": "dreamcast", "ngc": "gc", "sms": "mastersystem", "tg16": "pcengine", "neogeoaes": "neogeo", "neogeomvs": "neogeo",
                            "sega32": "sega32x", "famicom": "nes", "sfam": "snes"]

    struct RomMPage: Decodable {
        var items: [RomMGame]
        var total: Int?
    }

    struct RomMFile: Decodable {
        var id: Int
        var file_name: String
        var sha1_hash: String?
        var crc_hash: String?
        var file_size_bytes: Int64
    }

    struct RomMMeta: Decodable {
        var genres: [String]?
        var companies: [String]?
        var game_modes: [String]?
        var player_count: String?
        var first_release_date: Double?
    }

    struct RomMGame: Decodable {
        var id: Int
        var name: String?
        var fs_name: String
        var platform_slug: String
        var fs_size_bytes: Int64
        var summary: String?
        var crc_hash: String?
        var sha1_hash: String?
        var path_cover_large: String?
        var has_file_on_disk: Bool?
        var metadatum: RomMMeta?
        var files: [RomMFile]?
    }

    /// `first_release_date` vem em milissegundos em algumas fontes: acima de 1e11 não cabe em segundos.
    static func year(_ stamp: Double?) -> Int? {
        guard let stamp, stamp > 0 else { return nil }
        let seconds = stamp > 1e11 ? stamp / 1000 : stamp
        return Calendar(identifier: .gregorian).component(.year, from: Date(timeIntervalSince1970: seconds))
    }

    static func record(_ game: RomMGame, base: String) -> ScanRecord {
        let main = game.files?.max { $0.file_size_bytes < $1.file_size_bytes }
        var r = ScanRecord(path: "romm/\(game.id)/\(game.fs_name)", size: game.fs_size_bytes, mtime: 0,
                           crc: game.crc_hash ?? main?.crc_hash ?? "", sha1: game.sha1_hash ?? main?.sha1_hash ?? "")
        r.systemID = rommSlugs[game.platform_slug] ?? game.platform_slug
        r.title = game.name
        var meta = ShelfMeta()
        meta.title = game.name
        meta.summary = game.summary
        meta.year = year(game.metadatum?.first_release_date)
        meta.developer = game.metadatum?.companies?.first
        meta.players = game.metadatum?.player_count ?? game.metadatum?.game_modes?.joined(separator: ", ")
        meta.genres = game.metadatum?.genres ?? []
        r.meta = meta
        // Sem capa, o RomM manda texto vazio, não `null`.
        r.cover = game.path_cover_large.flatMap { $0.isEmpty ? nil : $0 }.map { path in
            path.hasPrefix("http") ? path : base + (path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path)
        }
        r.files = game.files?.map { RemoteFile(id: $0.id, name: $0.file_name) }
        return r
    }

    private func scanRomM() async throws -> [ScanRecord] {
        guard case let .romm(url) = source.kind else { return [] }
        let base = Self.trimmed(url)
        var offset = 0, records: [ScanRecord] = []
        while true {
            // Sem os índices auxiliares: por padrão cada página percorreria a biblioteca inteira.
            let query = "limit=500&offset=\(offset)&with_files=true&with_char_index=false&with_filter_values=false&with_rom_id_index=false&with_provider_metadata=false&order_by=id"
            let r = try await Curl.request("\(base)/api/roms?\(query)", auth: [Curl.bearer(secret.token)])
            try check(r.status)
            let page = try JSONDecoder().decode(RomMPage.self, from: Data(r.body.utf8))
            records += page.items.filter { $0.has_file_on_disk != false }.map { Self.record($0, base: base) }
            offset += page.items.count
            if page.items.isEmpty || offset >= (page.total ?? .max) { return records }
        }
    }

    // MARK: Download

    /// Baixa o jogo para `directory` e devolve o arquivo principal.
    func download(_ origin: ShelfOrigin, to directory: URL) async throws -> String {
        func target(_ path: String) -> String { directory.appendingPathComponent((path as NSString).lastPathComponent).path }
        let names = [origin.entry] + origin.members
        switch source.kind {
        case let .ssh(_, _, _, _):
            guard let ssh else { break }
            for path in names {
                let spec = Transfer.remoteSpec(ssh, path: path, clientQuotes: await Transfer.clientQuotes())
                try await Transfer.run(Transfer.rsyncArguments(config: ssh, source: spec, destination: directory.path + "/"))
            }
        case let .service(url):
            for path in names { try await Curl.download(ShelfInstaller.fileURL(service: url, path: path), to: target(path), auth: [Curl.bearer(secret.token)]) }
        case let .webdav(root):
            for path in names { try await Curl.download(Self.origin(root) + Self.encode(path), to: target(path), auth: davAuth) }
        case .s3:
            for path in names {
                guard let url = objectURL(path) else { continue }
                try await Curl.download(url, to: target(path), options: s3Options, auth: s3Auth)
            }
        case let .romm(url):
            let base = Self.trimmed(url)
            for file in origin.files {
                try await Curl.download("\(base)/api/roms/\(file.id)/files/content/\(Self.encode(file.name))", to: directory.appendingPathComponent(file.name).path, auth: [Curl.bearer(secret.token)])
            }
            // Um `.cue` ou `.m3u` é a porta de entrada; sem eles, o maior arquivo.
            let entry = origin.files.first { ["cue", "m3u", "gdi"].contains(($0.name as NSString).pathExtension.lowercased()) } ?? origin.files.first
            return directory.appendingPathComponent(entry?.name ?? (origin.entry as NSString).lastPathComponent).path
        case .folder, .smb, .nfs: return origin.entry
        }
        return target(origin.entry)
    }
}

enum WebDAV {
    struct Entry {
        var href: String
        var isCollection = false
        var size: Int64 = 0
        var modified: Int64 = 0
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var entries: [Entry] = []
        private var current: Entry?
        private var text = ""
        private var propOK = true
        private var pending = Entry(href: "")
        private static let date: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "GMT")
            f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            return f
        }()

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            switch name {
            case "response": current = Entry(href: "")
            case "propstat": pending = Entry(href: "")
            case "collection": pending.isCollection = true
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "href":
                // O servidor pode responder com URL absoluta ou só o caminho.
                let path = URLComponents(string: value)?.percentEncodedPath ?? value
                current?.href = path.removingPercentEncoding ?? path
            case "getcontentlength": pending.size = Int64(value) ?? 0
            case "getlastmodified": pending.modified = Self.date.date(from: value).map { Int64($0.timeIntervalSince1970) } ?? 0
            case "status": propOK = value.contains(" 200 ")
            case "propstat":
                // Propriedade ausente volta num `propstat` 404, que não diz nada do arquivo.
                if propOK {
                    let collection = current?.isCollection == true || pending.isCollection
                    current?.isCollection = collection
                    current?.size = pending.size
                    current?.modified = pending.modified
                }
            case "response":
                if let current { entries.append(current) }
                current = nil
            default: break
            }
        }
    }

    static func parse(_ data: Data) -> [Entry] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.parse()
        return delegate.entries
    }
}

enum S3 {
    struct Object {
        var key = ""
        var size: Int64 = 0
        var modified: Int64 = 0
    }

    struct Page {
        var objects: [Object] = []
        var next: String?
        var error: String?
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var page = Page()
        private var object: Object?
        private var text = ""
        private var truncated = false
        private var token: String?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            if name == "Contents" { object = Object() }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "Key": object?.key = text
            case "Size": object?.size = Int64(text) ?? 0
            case "LastModified":
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                object?.modified = f.date(from: text).map { Int64($0.timeIntervalSince1970) } ?? 0
            case "Contents":
                if let object { page.objects.append(object) }
                object = nil
            case "IsTruncated": truncated = text == "true"
            case "NextContinuationToken": token = text
            case "Code": page.error = text // Erro pode vir num 200.
            case "ListBucketResult": page.next = truncated ? token : nil
            default: break
            }
        }
    }

    static func parse(_ data: Data) -> Page {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.page
    }
}
