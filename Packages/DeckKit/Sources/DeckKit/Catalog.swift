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
    /// Jogo em pasta (PS4): o arquivo dentro dela que o emulador abre.
    public var entry: String?
    /// Arquivo que o emulador abre, quando difere de `entry` (PS3: `PS3_GAME/USRDIR/EBOOT.BIN`).
    public var boot: String?
    /// Emulador por jogo, pelo Title ID no nome do arquivo: quando o padrão não roda aquele jogo.
    public var emulatorFor: [String: String]?
    /// Só a pasta de origem identifica o sistema: a extensão é a de outro (Switch 2 usa `.nsp`/`.xci` do Switch).
    public var folderOnly: Bool?

    /// Emulador deste arquivo: o do jogo, se houver, senão o do sistema.
    public func emulator(for fileName: String) -> String {
        let upper = fileName.uppercased()
        return emulatorFor?.first { upper.contains("[" + $0.key.uppercased() + "]") }?.value ?? emulator
    }
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
    /// Só grava as chaves que ainda não existem: o que o usuário escolheu no emulador fica.
    public var onlyMissing: Bool?
    /// Arquivo inteiro, gravado só quando ainda não existe (RPCS3: o perfil de controle nasce na interface dele).
    public var create: String?
    public var path: String
    public var format: String
    public var entries: [ConfigEntry]

    public init(path: String, format: String, entries: [ConfigEntry], untouched: String? = nil, onlyMissing: Bool? = nil) {
        self.path = path
        self.format = format
        self.entries = entries
        self.untouched = untouched
        self.onlyMissing = onlyMissing
    }
}

/// Emulador fora do Flathub: AppImage das releases do GitHub, instalado em `~/.local/share/quietdeck/emulators/<id>`.
public struct AppImageSource: Codable, Hashable, Sendable {
    public var repo: String
    /// Nome exato do asset na release (`lichii-linux-x86_64.AppImage`).
    public var asset: String
    /// Tags `<prefixo><número>`; a maior é a mais nova.
    public var tagPrefix: String
}

public struct Emulator: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// `nil` quando o emulador vem de `appImage`.
    public var flatpak: String?
    public var appImage: AppImageSource?
    public var systems: [String]
    public var available: Bool?
    public var note: String?
    public var launch: String?
    public var config: EmulatorConfig?
    /// Controle e vídeo para o Deck, aplicados ao criar atalho. Cada um respeita `untouched` ou `onlyMissing`.
    public var profiles: [EmulatorConfig]?
    public var saves: [String]?
    /// O flatpak não enxerga a pasta pessoal: a pasta de ROMs precisa de permissão (Eden).
    public var romAccess: Bool?

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
