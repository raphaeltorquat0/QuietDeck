import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import DeckKit

/// Chamadas feitas pelo Mac. Só leem APIs públicas: nenhuma baixa jogo ou BIOS.
enum PublicAPI {
    static func get<T: Decodable>(_ url: String, headers: [String: String] = [:]) async throws -> T {
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        var request = URLRequest(url: u)
        request.setValue("QuietDeck", forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DeckError.unexpectedState("%@ answered %@. Check the API key in Settings.", u.host ?? "server", String(http.statusCode))
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

public struct SteamGridDB: Sendable {
    public struct Game: Codable, Hashable, Identifiable, Sendable {
        public var id: Int
        public var name: String
    }

    public struct Image: Codable, Equatable, Identifiable, Sendable {
        public var id: Int
        public var url: String
        public var thumb: String
    }

    struct Envelope<T: Decodable>: Decodable { var data: T }

    let key: String
    static let base = "https://www.steamgriddb.com/api/v2"

    public init(key: String) { self.key = key }

    private var auth: [String: String] { ["Authorization": "Bearer \(key)"] }

    static func encode(_ term: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        return term.addingPercentEncoding(withAllowedCharacters: allowed) ?? term
    }

    public func search(_ term: String) async throws -> [Game] {
        let e: Envelope<[Game]> = try await PublicAPI.get("\(Self.base)/search/autocomplete/\(Self.encode(term))", headers: auth)
        return e.data
    }

    public static func imagesURL(kind: ArtKind, gameID: Int) -> String {
        let api = kind.api
        return "\(base)/\(api.path)/game/\(gameID)" + (api.dimensions.map { "?dimensions=\($0)" } ?? "")
    }

    public func images(_ kind: ArtKind, gameID: Int) async throws -> [Image] {
        let e: Envelope<[Image]> = try await PublicAPI.get(Self.imagesURL(kind: kind, gameID: gameID), headers: auth)
        return e.data
    }
}
