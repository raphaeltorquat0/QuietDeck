import Foundation

public struct GameSystem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// Pasta sob `roms/`, no layout do EmuDeck/ES-DE. Wii U usa `wiiu/roms`.
    public var folder: String
    public var aliases: [String]
    public var extensions: [String]
    public var readsArchives: Bool
    /// `cd`, `auto` (CD ou DVD pelo tamanho) ou ausente quando o emulador não lê CHD.
    public var chd: String?
    public var emulator: String
    public var core: String?
}

public struct ConfigEntry: Codable, Hashable, Sendable {
    public var section: String?
    public var key: String
    public var value: String

    public init(section: String?, key: String, value: String) {
        self.section = section
        self.key = key
        self.value = value
    }
}

public struct EmulatorConfig: Codable, Hashable, Sendable {
    public var untouched: String?
    public var path: String
    public var format: String
    public var entries: [ConfigEntry]
}

public struct Emulator: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var flatpak: String
    public var systems: [String]
    public var available: Bool?
    public var note: String?
    public var launch: String?
    public var config: EmulatorConfig?
    /// Perfil do controle do Deck. Só entra enquanto o arquivo tiver `untouched`, o padrão de fábrica.
    public var controller: EmulatorConfig?
    public var saves: [String]?

    public var isAvailable: Bool { available ?? true }
}

public struct BIOSEntry: Codable, Hashable, Sendable {
    public var system: String
    public var file: String
    public var size: Int
    public var md5: String
    public var sha1: String

    public init(system: String, file: String, size: Int, md5: String, sha1: String) {
        self.system = system
        self.file = file
        self.size = size
        self.md5 = md5
        self.sha1 = sha1
    }
}

public struct BIOSTable: Codable, Sendable {
    public var source: String
    public var commit: String
    public var entries: [BIOSEntry]
}

public struct CompatToolSource: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var repo: String
    public var assetSuffix: String
    public var checksumSuffix: String
}

extension Bundle {
    /// Pasta `Resources/` do pacote, para quem lê arquivos que não são catálogos.
    public static var deckKitResources: URL? { Bundle.module.url(forResource: "Resources", withExtension: nil) }
}

/// Dados versionados em `Resources/`. Um `emulators.json` em `overrideDirectory` substitui o embutido.
public struct Catalog: Sendable {
    public var systems: [GameSystem]
    public var emulators: [Emulator]
    public var bios: BIOSTable
    public var compatTools: [CompatToolSource]
    public var free: [FreeGame]

    public static func load(overrideDirectory: URL? = nil) throws -> Catalog {
        func decode<T: Decodable>(_ name: String) throws -> T {
            if let url = overrideDirectory?.appendingPathComponent(name + ".json"),
               let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(T.self, from: data) { return value }
            guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Resources") else {
                throw CocoaError(.fileNoSuchFile)
            }
            return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
        }
        return Catalog(systems: try decode("systems"), emulators: try decode("emulators"),
                       bios: try decode("bios"), compatTools: try decode("compat-tools"), free: try decode("free-catalog"))
    }

    public func system(_ id: String) -> GameSystem? { systems.first { $0.id == id } }
    public func emulator(_ id: String) -> Emulator? { emulators.first { $0.id == id } }
}
