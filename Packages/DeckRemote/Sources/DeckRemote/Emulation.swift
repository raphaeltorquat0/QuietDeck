import Foundation
import DeckKit

public struct InstalledFlatpak: Equatable, Sendable {
    public var appID: String
    public var version: String
    public var installation: String
}

public enum Flatpaks {
    static let flathubURL = "https://dl.flathub.org/repo/flathub.flatpakrepo"
    public static let list = "flatpak list --app --columns=application,version,branch,installation"
    public static let updates = "flatpak remote-ls --user --updates --columns=application,version flathub 2>/dev/null"
    public static let userRemotes = "flatpak remotes --user --columns=name"

    public static func parseList(_ text: String) -> [InstalledFlatpak] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 4, !f[0].isEmpty else { return nil }
            return InstalledFlatpak(appID: f[0], version: f[1], installation: f[3])
        }
    }

    public static func parseUpdates(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if let id = f.first, !id.isEmpty { result[id] = f.count > 1 ? f[1] : "" }
        }
        return result
    }

    public static func installed(_ runner: any CommandRunner) async throws -> [InstalledFlatpak] {
        parseList(try await runner.check(list).stdout)
    }

    /// O SteamOS só traz o remote em nível de sistema; `--user` precisa do próprio.
    static func ensureRemote(_ runner: any CommandRunner) async throws {
        let remotes = try await runner.check(userRemotes).stdout
        if remotes.split(whereSeparator: \.isNewline).contains("flathub") { return }
        try await runner.check("flatpak remote-add --user --if-not-exists flathub \(flathubURL)", timeout: 60)
    }

    public enum Outcome: Equatable, Sendable { case done, alreadyInstalled, notInstalled, systemInstall }

    public static func install(_ appID: String, runner: any CommandRunner, onOutput: LocalProcess.Output? = nil) async throws -> Outcome {
        let current = try await installed(runner).first { $0.appID == appID }
        if let current { return current.installation == "user" ? .alreadyInstalled : .systemInstall }
        try await ensureRemote(runner)
        try await runner.check(RemoteCommand("flatpak install --user --noninteractive -y flathub \(Shell.quote(appID))", timeout: 3600), onOutput: onOutput)
        return try await verify(appID, runner, present: true)
    }

    public static func update(_ appID: String, runner: any CommandRunner, onOutput: LocalProcess.Output? = nil) async throws -> Outcome {
        let current = try await installed(runner).first { $0.appID == appID }
        guard let current else { return .notInstalled }
        guard current.installation == "user" else { return .systemInstall }
        try await runner.check(RemoteCommand("flatpak update --user --noninteractive -y \(Shell.quote(appID))", timeout: 3600), onOutput: onOutput)
        return .done
    }

    public static func remove(_ appID: String, runner: any CommandRunner) async throws -> Outcome {
        let current = try await installed(runner).first { $0.appID == appID }
        guard let current else { return .notInstalled }
        guard current.installation == "user" else { return .systemInstall }
        try await runner.check(RemoteCommand("flatpak uninstall --user --noninteractive -y \(Shell.quote(appID))", timeout: 300))
        return try await verify(appID, runner, present: false)
    }

    private static func verify(_ appID: String, _ runner: any CommandRunner, present: Bool) async throws -> Outcome {
        let isThere = try await installed(runner).contains { $0.appID == appID }
        guard isThere == present else { throw DeckError.unexpectedState("Flatpak finished, but the app state didn't change: %@", appID) }
        return .done
    }
}

/// Onde ficam as pastas de emulação neste Deck, lidas do próprio Deck a cada operação.
public struct EmulationPaths: Equatable, Sendable, Codable {
    public var root: String
    public var roms: String
    public var bios: String
    public var saves: String
    public var storage: String
    public var isEmuDeck: Bool

    public init(root: String) {
        self.root = root
        roms = root + "/roms"
        bios = root + "/bios"
        saves = root + "/saves"
        storage = root + "/storage"
        isEmuDeck = false
    }

    public func expand(_ template: String) -> String {
        template.replacingOccurrences(of: "{roms}", with: roms).replacingOccurrences(of: "{bios}", with: bios)
            .replacingOccurrences(of: "{saves}", with: saves).replacingOccurrences(of: "{storage}", with: storage)
    }
}

public enum Emulation {
    public static let emuDeckSettings = "cat ~/.config/EmuDeck/settings.sh 2>/dev/null || cat ~/emudeck/settings.sh 2>/dev/null"

    /// Lê as linhas `chave=valor` sem nunca executar o arquivo.
    public static func parseEmuDeck(_ text: String, home: String) -> EmulationPaths? {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            values[key] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                .replacingOccurrences(of: "$HOME", with: home).replacingOccurrences(of: "${HOME}", with: home)
        }
        guard let root = values["emulationPath"], !root.isEmpty else { return nil }
        func expand(_ key: String, _ fallback: String) -> String {
            guard let v = values[key], !v.isEmpty else { return fallback }
            return v.replacingOccurrences(of: "$emulationPath", with: root).replacingOccurrences(of: "${emulationPath}", with: root)
        }
        var paths = EmulationPaths(root: root)
        paths.roms = expand("romsPath", paths.roms)
        paths.bios = expand("biosPath", paths.bios)
        paths.saves = expand("savesPath", paths.saves)
        paths.storage = expand("storagePath", paths.storage)
        paths.isEmuDeck = true
        return paths
    }

    /// EmuDeck manda quando existe. Sem ele, `sdMount` escolhe o microSD.
    public static func paths(_ runner: any CommandRunner, sdMount: String? = nil) async throws -> EmulationPaths {
        let home = try await RemoteFiles(runner: runner).home()
        let settings = try await runner.run(emuDeckSettings)
        if settings.ok, let paths = parseEmuDeck(settings.stdout, home: home) { return paths }
        return EmulationPaths(root: (sdMount ?? home) + "/Emulation")
    }

    public static func directories(_ paths: EmulationPaths, systems: [GameSystem]) -> [String] {
        var dirs = systems.map { "\(paths.roms)/\($0.folder)" }
        if !paths.isEmuDeck {
            // Com EmuDeck, `bios/` é plano e `saves/` é por emulador: não criamos a variação por sistema.
            for s in systems { dirs += ["\(paths.bios)/\(s.id)", "\(paths.saves)/\(s.id)", "\(paths.storage)/\(s.id)"] }
        }
        return dirs
    }

    @discardableResult
    public static func prepare(_ runner: any CommandRunner, paths: EmulationPaths, systems: [GameSystem]) async throws -> Int {
        let dirs = directories(paths, systems: systems)
        // Lê antes para contar o que faltava; `mkdir -p` nunca toca no que existe.
        let script = dirs.map { "test -d \(Shell.quote($0)) || { mkdir -p \(Shell.quote($0)) && echo created; }" }.joined(separator: "; ")
        return try await runner.check(RemoteCommand(script, timeout: 60)).stdout.split(whereSeparator: \.isNewline).count
    }
}

public enum ConfigPatcher {
    /// Só muda as chaves pedidas; todo o resto do arquivo fica como estava.
    public static func apply(_ text: String, format: String, entries: [ConfigEntry]) -> String {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        for entry in entries {
            let rendered = render(entry, format: format)
            let (start, end) = sectionRange(entry.section, lines: lines)
            if let start, let i = (start..<end).first(where: { keyOf(lines[$0]) == entry.key }) {
                lines[i] = rendered
            } else if let start {
                lines.insert(rendered, at: end)
            } else {
                if let s = entry.section { lines.append("[\(s)]") }
                lines.append(rendered)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func render(_ e: ConfigEntry, format: String) -> String {
        switch format {
        case "cfg": "\(e.key) = \"\(e.value)\""
        case "toml": "\(e.key) = '\(e.value)'"
        default: "\(e.key) = \(e.value)"
        }
    }

    private static func keyOf(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.hasPrefix("#"), !t.hasPrefix(";"), let eq = t.firstIndex(of: "=") else { return nil }
        return t[..<eq].trimmingCharacters(in: .whitespaces)
    }

    private static func sectionRange(_ section: String?, lines: [String]) -> (Int?, Int) {
        guard let section else { return (0, lines.count) }
        guard let header = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[\(section)]" }) else { return (nil, lines.count) }
        let next = lines[(header + 1)...].firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count
        return (header + 1, next)
    }
}

public enum EmulatorSetup {
    public enum Outcome: Equatable, Sendable {
        case written, unchanged, notConfigurable
        case skippedEmuDeck
        /// O arquivo existe: só com confirmação na UI (`overwrite: true`).
        case needsConfirmation(path: String)
    }

    public static func configure(_ emulator: Emulator, paths: EmulationPaths, overwrite: Bool, runner: any CommandRunner) async throws -> Outcome {
        guard let config = emulator.config else { return .notConfigurable }
        if paths.isEmuDeck { return .skippedEmuDeck }
        let files = RemoteFiles(runner: runner)
        let path = try await files.home() + "/" + config.path
        let current = try await files.read(path)
        if current != nil, !overwrite { return .needsConfirmation(path: path) }
        let entries = config.entries.map { ConfigEntry(section: $0.section, key: $0.key, value: paths.expand($0.value)) }
        let before = current.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let after = ConfigPatcher.apply(before, format: config.format, entries: entries)
        if after == before { return .unchanged }
        if current != nil {
            try await runner.check("cp -n \(Shell.quote(path)) \(Shell.quote(path + ".quietdeck-backup"))")
        }
        try await files.write(Data(after.utf8), to: path)
        return .written
    }

    /// Mapeamento feito à mão não é tocado. Devolve se gravou.
    public static func applyController(_ emulator: Emulator, runner: any CommandRunner) async throws -> Bool {
        guard let config = emulator.controller else { return false }
        let files = RemoteFiles(runner: runner)
        let path = try await files.home() + "/" + config.path
        let current = try await files.read(path).map { String(decoding: $0, as: UTF8.self) }
        guard let after = patchedController(config, current: current) else { return false }
        if current != nil {
            try await runner.check("cp -n \(Shell.quote(path)) \(Shell.quote(path + ".quietdeck-backup"))")
        }
        try await files.write(Data(after.utf8), to: path)
        return true
    }

    static func patchedController(_ config: EmulatorConfig, current: String?) -> String? {
        if let current, let marker = config.untouched, !current.contains(marker) { return nil }
        let after = ConfigPatcher.apply(current ?? "", format: config.format, entries: config.entries)
        return after == current ? nil : after
    }

    static func coresDirectory(home: String) -> String { home + "/.var/app/org.libretro.RetroArch/config/retroarch/cores" }

    /// Cores são software do RetroArch, não ROM/BIOS. Vêm do buildbot oficial, só o que faltar.
    public static func ensureCore(_ core: String, runner: any CommandRunner) async throws -> String {
        let home = try await RemoteFiles(runner: runner).home()
        let dir = coresDirectory(home: home)
        let path = "\(dir)/\(core)_libretro.so"
        if try await runner.run("test -s \(Shell.quote(path))").ok { return path }
        let q = Shell.quote(dir), name = Shell.quote(core + "_libretro.so.zip")
        let url = "https://buildbot.libretro.com/nightly/linux/x86_64/latest/\(core)_libretro.so.zip"
        try await runner.check(RemoteCommand("mkdir -p \(q) && cd \(q) && curl -fsSL -o \(name) \(Shell.quote(url)) && python3 -m zipfile -e \(name) . && rm -f \(name)", timeout: 300))
        return path
    }
}

public enum BIOSStatus: Equatable, Sendable { case ok, missing, invalid }

public enum BIOS {
    public static func scan(paths: EmulationPaths) -> String {
        "cd \(Shell.quote(paths.bios)) 2>/dev/null && find . -maxdepth 2 -type f -size -8M -print0 | xargs -0 -r sha1sum"
    }

    /// `ok` se algum arquivo do sistema bate. `invalid` se existe o nome certo com hash errado.
    public static func status(scanOutput: String, table: [BIOSEntry]) -> [String: BIOSStatus] {
        var hashes = Set<String>(), names = Set<String>()
        for line in scanOutput.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
            guard parts.count == 2 else { continue }
            hashes.insert(parts[0].lowercased())
            names.insert(parts[1].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "./", with: ""))
        }
        var result: [String: BIOSStatus] = [:]
        for system in Set(table.map(\.system)) {
            let entries = table.filter { $0.system == system }
            if entries.contains(where: { hashes.contains($0.sha1) }) { result[system] = .ok }
            else if entries.contains(where: { names.contains($0.file) }) { result[system] = .invalid }
            else { result[system] = .missing }
        }
        return result
    }

    public static func match(sha1: String, table: [BIOSEntry]) -> BIOSEntry? {
        table.first { $0.sha1 == sha1.lowercased() }
    }
}

public enum LocalHash {
    /// `shasum` lê em streaming: ISOs de vários GB não passam pela memória do app.
    public static func compute(_ path: String, algorithm: Int) async throws -> String {
        let r = try await LocalProcess.run("/usr/bin/shasum", ["-a", String(algorithm), path])
        guard r.ok, let hash = r.stdout.split(separator: " ").first else { throw DeckError.commandFailed(command: "shasum", result: r) }
        return String(hash)
    }
}
