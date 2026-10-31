import Foundation

/// Atalho não-Steam. `appID` é o id de 32 bits sem sinal, o mesmo dos nomes de arquivo em `grid/`.
public struct Shortcut: Codable, Hashable, Identifiable, Sendable {
    public var appID: UInt32
    public var name: String
    public var exe: String
    public var startDir: String
    public var launchOptions: String
    public var tags: [String]
    public var id: UInt32 { appID }

    public init(name: String, exe: String, startDir: String, launchOptions: String = "", tags: [String] = []) {
        let quoted = exe.hasPrefix("\"") ? exe : "\"\(exe)\""
        self.name = name
        self.exe = quoted
        self.startDir = startDir.hasPrefix("\"") ? startDir : "\"\(startDir)\""
        self.launchOptions = launchOptions
        self.tags = tags
        appID = Self.generateID(exe: quoted, name: name)
    }

    /// Mesmo cálculo do Steam ROM Manager: CRC-32 de `exe + nome`, com as aspas de `Exe`, e o bit alto ligado.
    public static func generateID(exe: String, name: String) -> UInt32 {
        CRC32.checksum(Data((exe + name).utf8)) | 0x8000_0000
    }

    var vdf: [(key: String, value: VDFValue)] {
        [("appid", .int32(Int32(bitPattern: appID))), ("AppName", .string(name)), ("Exe", .string(exe)),
         ("StartDir", .string(startDir)), ("icon", .string("")), ("ShortcutPath", .string("")),
         ("LaunchOptions", .string(launchOptions)), ("IsHidden", .int32(0)), ("AllowDesktopConfig", .int32(1)),
         ("AllowOverlay", .int32(1)), ("OpenVR", .int32(0)), ("Devkit", .int32(0)), ("DevkitGameID", .string("")),
         ("DevkitOverrideAppID", .int32(0)), ("LastPlayTime", .int32(0)), ("FlatpakAppID", .string("")),
         ("tags", .map(tags.enumerated().map { (String($0.offset), .string($0.element)) }))]
    }
}

public enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i in
        (0..<8).reduce(UInt32(i)) { c, _ in c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }

    public static func checksum(_ data: Data) -> UInt32 { ~update(~0, data) }

    /// Em blocos: ROMs de vários GB não cabem numa `Data` só.
    public static func update(_ crc: UInt32, _ data: Data) -> UInt32 {
        var c = crc
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            table.withUnsafeBufferPointer { t in
                for b in bytes { c = t[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
            }
        }
        return c
    }
}

/// Lê e altera `shortcuts.vdf` sem tocar nas entradas existentes: campos que não conhecemos ficam intactos.
public enum ShortcutsFile {
    public struct Existing: Equatable, Sendable {
        public var appID: UInt32?
        public var name: String
        public var exe: String
        /// Epoch do último jogo; `0` nunca jogado.
        public var lastPlayed: Int64 = 0
    }

    public static let emptyFile = VDFValue.map([("shortcuts", .map([]))])

    public static func parse(_ data: Data) throws -> VDFValue {
        data.isEmpty ? emptyFile : try VDF.parse(data)
    }

    public static func existing(in root: VDFValue) -> [Existing] {
        guard case let .map(entries)? = root["shortcuts"] else { return [] }
        return entries.map { entry in
            var id: UInt32?
            // O id é sempre lido do arquivo: entradas criadas pelo Steam não seguem o CRC.
            if case let .int32(v)? = entry.value["appid"] { id = UInt32(bitPattern: v) }
            func text(_ key: String) -> String {
                if case let .string(s)? = entry.value[key] { s } else { "" }
            }
            var played: Int64 = 0
            if case let .int32(v)? = entry.value["LastPlayTime"] { played = Int64(UInt32(bitPattern: v)) }
            return Existing(appID: id, name: text("AppName"), exe: text("Exe"), lastPlayed: played)
        }
    }

    /// Acrescenta o que falta. Repetir com os mesmos atalhos não muda nada.
    public static func merge(_ shortcuts: [Shortcut], into root: VDFValue) throws -> (root: VDFValue, added: [Shortcut]) {
        guard case let .map(top) = root else { throw VDFError.truncated(offset: 0) }
        var pairs = top
        var entries: [(key: String, value: VDFValue)] = []
        var slot = pairs.firstIndex { $0.key.caseInsensitiveCompare("shortcuts") == .orderedSame }
        if let i = slot, case let .map(current) = pairs[i].value { entries = current }
        var known = Set(existing(in: root).map { key($0.name, $0.exe) })
        var nextIndex = (entries.compactMap { Int($0.key) }.max() ?? -1) + 1
        var added: [Shortcut] = []
        for shortcut in shortcuts where known.insert(key(shortcut.name, shortcut.exe)).inserted {
            entries.append((String(nextIndex), .map(shortcut.vdf)))
            nextIndex += 1
            added.append(shortcut)
        }
        if slot == nil {
            pairs.append(("shortcuts", .map([])))
            slot = pairs.count - 1
        }
        pairs[slot!].value = .map(entries)
        return (.map(pairs), added)
    }

    /// Tira pelo nome e renumera, como o Steam espera. Quem não bate fica intacto.
    public static func remove(names: [String], from root: VDFValue) -> (root: VDFValue, removed: Int) {
        guard case let .map(top) = root else { return (root, 0) }
        var removed = 0
        let pairs = top.map { pair -> (key: String, value: VDFValue) in
            guard pair.key.caseInsensitiveCompare("shortcuts") == .orderedSame, case let .map(entries) = pair.value else { return pair }
            let kept = entries.filter { entry in
                guard case let .string(name)? = entry.value["AppName"], names.contains(name) else { return true }
                removed += 1
                return false
            }
            return (pair.key, .map(kept.enumerated().map { (String($0.offset), $0.element.value) }))
        }
        return (.map(pairs), removed)
    }

    private static func key(_ name: String, _ exe: String) -> String { name.lowercased() + "\u{0}" + exe }
}

public enum ArtKind: String, CaseIterable, Codable, Sendable {
    case portrait, wide, hero, logo, icon

    /// Sufixos do Steam ROM Manager; todos usam o id curto de 32 bits.
    public func fileName(appID: UInt32, extension ext: String = "png") -> String {
        switch self {
        case .portrait: "\(appID)p.\(ext)"
        case .wide: "\(appID).\(ext)"
        case .hero: "\(appID)_hero.\(ext)"
        case .logo: "\(appID)_logo.\(ext)"
        case .icon: "\(appID)_icon.\(ext)"
        }
    }

    /// Caminho na API do SteamGridDB e filtro de dimensões.
    public var api: (path: String, dimensions: String?) {
        switch self {
        case .portrait: ("grids", "600x900")
        case .wide: ("grids", "920x430")
        case .hero: ("heroes", nil)
        case .logo: ("logos", nil)
        case .icon: ("icons", nil)
        }
    }
}
