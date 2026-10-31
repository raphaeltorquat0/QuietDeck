import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import DeckKit

/// Só texto e imagens: nenhuma destas fontes é usada para obter arquivos de jogo.
public struct MetadataResult: Sendable {
    public var meta: ShelfMeta
    public var cover: URL?
    public var hero: URL?
}

public struct ScreenScraper: Sendable {
    public struct Credentials: Codable, Hashable, Sendable {
        public var devID: String
        public var devPassword: String
        public var user: String
        public var password: String

        public init(devID: String, devPassword: String, user: String, password: String) {
            self.devID = devID
            self.devPassword = devPassword
            self.user = user
            self.password = password
        }
    }

    /// Ids iguais em RomM e ES-DE. `systemesListe.php` exige credenciais de dev.
    static let systems: [String: Int] = [
        "nes": 3, "snes": 4, "n64": 14, "gb": 9, "gbc": 10, "gba": 12, "genesis": 1, "mastersystem": 2, "gamegear": 21,
        "sega32x": 19, "segacd": 20, "saturn": 22, "dreamcast": 23, "psx": 57, "ps2": 58, "psp": 61, "gc": 13, "wii": 16,
        "pcengine": 31, "neogeo": 142,
    ]

    let credentials: Credentials

    public init(credentials: Credentials) { self.credentials = credentials }

    static func url(_ c: Credentials, item: ShelfItem, sha1: String) -> URL? {
        var u = URLComponents(string: "https://api.screenscraper.fr/api2/jeuInfos.php")
        var query: [(String, String)] = [
            ("devid", c.devID), ("devpassword", c.devPassword), ("softname", "QuietDeck"), ("output", "json"),
            ("romtype", "rom"), ("romnom", (item.entry as NSString).lastPathComponent), ("romtaille", String(item.size)),
            ("crc", item.crc), ("sha1", sha1),
        ]
        if !c.user.isEmpty { query += [("ssid", c.user), ("sspassword", c.password)] }
        if let system = systems[item.systemID] { query.append(("systemeid", String(system))) }
        u?.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        return u?.url
    }

    public func lookup(_ item: ShelfItem) async throws -> MetadataResult? {
        guard let url = Self.url(credentials, item: item, sha1: item.id) else { return nil }
        // O erro nunca cita a URL: ela leva as senhas.
        guard let (data, response) = try? await URLSession.shared.data(from: url), let http = response as? HTTPURLResponse else {
            throw DeckError.unexpectedState("Couldn't reach %@.", "ScreenScraper")
        }
        switch http.statusCode {
        case 200: return Self.parse(data, language: Locale.current.language.languageCode?.identifier)
        case 404: return nil
        case 403: throw DeckError.unexpectedState("%@ refused your credentials.", "ScreenScraper")
        case 429, 430, 431: throw DeckError.unexpectedState("%@ quota reached. Try again later.", "ScreenScraper")
        default: throw DeckError.unexpectedState("%@ answered %@. Check the API key in Settings.", "ScreenScraper", String(http.statusCode))
        }
    }

    struct Reply: Decodable { var response: Body }
    struct Body: Decodable { var jeu: Game }
    struct Text: Decodable {
        var region: String?
        var langue: String?
        var text: String
    }
    struct Genre: Decodable { var noms: [Text]? }
    struct Media: Decodable {
        var type: String
        var url: String
        var region: String?
    }
    struct Game: Decodable {
        var noms: [Text]?
        var synopsis: [Text]?
        var dates: [Text]?
        var developpeur: Text?
        var joueurs: Text?
        var genres: [Genre]?
        var medias: [Media]?
    }

    /// A API devolve todas as regiões e idiomas; a escolha é do cliente.
    static func parse(_ data: Data, language: String?) -> MetadataResult? {
        guard let game = (try? JSONDecoder().decode(Reply.self, from: data))?.response.jeu else { return nil }
        let regions = (language == "pt" ? ["br"] : []) + ["us", "wor", "ss", "eu", "jp"]
        let languages = (language.map { [$0] } ?? []) + ["en", "fr"]
        func byRegion(_ list: [Text]?) -> String? {
            regions.lazy.compactMap { r in list?.first { $0.region == r }?.text }.first ?? list?.first?.text
        }
        func byLanguage(_ list: [Text]?) -> String? {
            languages.lazy.compactMap { l in list?.first { $0.langue == l }?.text }.first ?? list?.first?.text
        }
        func media(_ type: String) -> URL? {
            let found = game.medias?.filter { $0.type == type } ?? []
            let pick = regions.lazy.compactMap { r in found.first { $0.region == r } }.first ?? found.first
            return pick.flatMap { URL(string: $0.url) }
        }
        var meta = ShelfMeta()
        meta.title = byRegion(game.noms)
        meta.summary = byLanguage(game.synopsis)
        meta.year = byRegion(game.dates).flatMap { Int($0.prefix(4)) }
        meta.developer = game.developpeur?.text
        meta.players = game.joueurs?.text
        meta.genres = game.genres?.compactMap { byLanguage($0.noms) } ?? []
        return MetadataResult(meta: meta, cover: media("box-2D"), hero: media("fanart"))
    }
}

public actor IGDB {
    public struct Credentials: Codable, Hashable, Sendable {
        public var clientID: String
        public var secret: String

        public init(clientID: String, secret: String) {
            self.clientID = clientID
            self.secret = secret
        }
    }

    /// Uma fonte só (RomM): confirmar com `POST /v4/platforms` se algum sistema vier errado.
    static let platforms: [String: Int] = [
        "nes": 18, "snes": 19, "n64": 4, "gb": 33, "gbc": 22, "gba": 24, "genesis": 29, "mastersystem": 64, "gamegear": 35,
        "sega32x": 30, "segacd": 78, "saturn": 32, "dreamcast": 23, "psx": 7, "ps2": 8, "psp": 38, "gc": 21, "wii": 5,
        "pcengine": 86, "neogeo": 80,
    ]

    let credentials: Credentials
    private var token: (value: String, expires: Date)?

    public init(credentials: Credentials) { self.credentials = credentials }

    struct Token: Decodable {
        var access_token: String
        var expires_in: Double
    }

    private func bearer() async throws -> String {
        if let token, token.expires > Date() { return token.value }
        var u = URLComponents(string: "https://id.twitch.tv/oauth2/token")
        u?.queryItems = [.init(name: "client_id", value: credentials.clientID), .init(name: "client_secret", value: credentials.secret),
                         .init(name: "grant_type", value: "client_credentials")]
        guard let url = u?.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // O erro nunca cita a URL: ela leva o segredo.
        guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let reply = try? JSONDecoder().decode(Token.self, from: data) else {
            throw DeckError.unexpectedState("%@ refused your credentials.", "IGDB")
        }
        token = (reply.access_token, Date().addingTimeInterval(reply.expires_in - 60))
        return reply.access_token
    }

    static func query(title: String, systemID: String) -> String {
        let name = title.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "")
        let platform = platforms[systemID].map { "where platforms = (\($0));\n" } ?? ""
        return """
        search "\(name)";
        fields name,summary,first_release_date,involved_companies.company.name,involved_companies.developer,genres.name,cover.image_id,artworks.image_id,game_modes.name;
        \(platform)limit 1;
        """
    }

    public func lookup(title: String, systemID: String) async throws -> MetadataResult? {
        var request = URLRequest(url: URL(string: "https://api.igdb.com/v4/games")!)
        request.httpMethod = "POST"
        request.setValue(credentials.clientID, forHTTPHeaderField: "Client-ID")
        request.setValue("Bearer \(try await bearer())", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(Self.query(title: title, systemID: systemID).utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
            throw DeckError.unexpectedState("%@ answered %@. Check the API key in Settings.", "IGDB", String((response as? HTTPURLResponse)?.statusCode ?? 0))
        }
        return Self.parse(data)
    }

    struct Name: Decodable { var name: String }
    struct Image: Decodable { var image_id: String }
    struct Company: Decodable {
        var company: Name?
        var developer: Bool?
    }
    struct Game: Decodable {
        var name: String?
        var summary: String?
        var first_release_date: Double?
        var involved_companies: [Company]?
        var genres: [Name]?
        var cover: Image?
        var artworks: [Image]?
        var game_modes: [Name]?
    }

    static func image(_ id: String?, size: String) -> URL? {
        id.flatMap { URL(string: "https://images.igdb.com/igdb/image/upload/t_\(size)/\($0).jpg") }
    }

    static func parse(_ data: Data) -> MetadataResult? {
        guard let game = (try? JSONDecoder().decode([Game].self, from: data))?.first else { return nil }
        var meta = ShelfMeta()
        meta.title = game.name
        meta.summary = game.summary
        meta.year = game.first_release_date.map { Calendar(identifier: .gregorian).component(.year, from: Date(timeIntervalSince1970: $0)) }
        meta.developer = game.involved_companies?.first { $0.developer == true }?.company?.name
        meta.players = game.game_modes?.map(\.name).joined(separator: ", ")
        meta.genres = game.genres?.map(\.name) ?? []
        return MetadataResult(meta: meta, cover: image(game.cover?.image_id, size: "cover_big_2x"), hero: image(game.artworks?.first?.image_id, size: "1080p"))
    }
}
