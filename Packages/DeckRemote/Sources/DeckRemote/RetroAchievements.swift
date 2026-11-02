import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import DeckKit

/// Conta do RetroAchievements. A senha só vai ao servidor no login; o que fica é o token, como nos emuladores.
public struct RetroAchievementsAccount: Codable, Equatable, Sendable {
    public var username: String
    public var token: String

    public init(username: String, token: String) {
        self.username = username
        self.token = token
    }
}

public enum RetroAchievements {
    static let endpoint = URL(string: "https://retroachievements.org/dorequest.php")!

    /// Mesmo pedido `login2` do rcheevos, por POST: a senha não aparece em URL nem em log de servidor.
    public static func login(username: String, password: String, session: URLSession = .shared) async throws -> RetroAchievementsAccount {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("QuietDeck", forHTTPHeaderField: "User-Agent")
        request.httpBody = form(["r": "login2", "u": username, "p": password])
        let (data, _) = try await session.data(for: request)
        return try parseLogin(data)
    }

    static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    static func parseLogin(_ data: Data) throws -> RetroAchievementsAccount {
        struct Response: Decodable {
            var Success: Bool
            var User: String?
            var Token: String?
            var Error: String?
        }
        guard let r = try? JSONDecoder().decode(Response.self, from: data) else {
            throw DeckError.unexpectedState("RetroAchievements sent an unexpected answer. Try again later.")
        }
        guard r.Success, let user = r.User, let token = r.Token, !token.isEmpty else {
            throw DeckError.unexpectedState("RetroAchievements refused the login: %@", r.Error ?? "")
        }
        return RetroAchievementsAccount(username: user, token: token)
    }

    /// Chaves de cada emulador, conferidas no código de cada um: RetroArch (`configuration.c`) e Dolphin
    /// (`AchievementSettings.cpp`). Sem conta, desliga e apaga o token. A senha nunca vai ao Deck.
    public static func profiles(for emulator: Emulator, account: RetroAchievementsAccount?) -> [EmulatorConfig] {
        switch emulator.id {
        case "retroarch":
            return [EmulatorConfig(path: ".var/app/org.libretro.RetroArch/config/retroarch/retroarch.cfg", format: "cfg", entries: [
                ConfigEntry(section: nil, key: "cheevos_enable", value: account == nil ? "false" : "true"),
                ConfigEntry(section: nil, key: "cheevos_username", value: account?.username ?? ""),
                ConfigEntry(section: nil, key: "cheevos_token", value: account?.token ?? ""),
                ConfigEntry(section: nil, key: "cheevos_password", value: ""),
            ])]
        case "dolphin":
            return [EmulatorConfig(path: ".var/app/org.DolphinEmu.dolphin-emu/config/dolphin-emu/RetroAchievements.ini", format: "ini", entries: [
                ConfigEntry(section: "Achievements", key: "Enabled", value: account == nil ? "False" : "True"),
                ConfigEntry(section: "Achievements", key: "Username", value: account?.username ?? ""),
                ConfigEntry(section: "Achievements", key: "ApiToken", value: account?.token ?? ""),
            ])]
        default:
            return []
        }
    }
}
