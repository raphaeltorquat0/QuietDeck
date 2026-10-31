import Foundation
import DeckKit

/// Ferramentas do Mac usadas pelo pipeline. Apps abertos pelo Finder não herdam o PATH do Homebrew.
public enum LocalTools {
    static let prefixes = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    public static func find(_ names: String...) -> String? {
        for prefix in prefixes {
            for name in names where FileManager.default.isExecutableFile(atPath: "\(prefix)/\(name)") { return "\(prefix)/\(name)" }
        }
        return nil
    }

    /// `chdman` vem na fórmula `rom-tools`; `7zz` na `sevenzip`.
    public static func require(_ names: [String], formula: String, onOutput: LocalProcess.Output? = nil) async throws -> String {
        func found() -> String? { names.lazy.compactMap { find($0) }.first }
        if let path = found() { return path }
        guard let brew = find("brew") else {
            throw DeckError.unexpectedState("\(names[0]) is missing and Homebrew isn't installed. Install Homebrew from brew.sh, then try again.")
        }
        let r = try await LocalProcess.run(brew, ["install", formula], onOutput: onOutput)
        guard r.ok, let path = found() else { throw DeckError.commandFailed(command: "brew install \(formula)", result: r) }
        return path
    }
}

public struct ROMCandidate: Equatable, Sendable {
    public var path: String
    public var size: Int64
    public var detection: ROMDetection
}

public enum ROMScanner {
    static func prefix(_ path: String) -> Data {
        guard let h = FileHandle(forReadingAtPath: path) else { return Data() }
        defer { try? h.close() }
        return (try? h.read(upToCount: ROMDetector.prefixLength)) ?? Data()
    }

    /// Aceita arquivos e pastas (Finder, seletor, pasta sincronizada, SMB/NFS montado).
    /// Faixas citadas por um `.cue`/`.gdi` viajam com ele e não viram jogos separados.
    public static func scan(_ urls: [URL], catalog: Catalog) -> [ROMCandidate] {
        let detector = ROMDetector(systems: catalog.systems)
        var files: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
                while let item = walker?.nextObject() as? URL {
                    if (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { files.append(item) }
                }
            } else {
                files.append(url)
            }
        }
        var members = Set<String>()
        for file in files where ["cue", "gdi"].contains(file.pathExtension.lowercased()) {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            for name in ROMPlan.referencedFiles(cueSheet: text, extension: file.pathExtension) {
                members.insert(file.deletingLastPathComponent().appendingPathComponent(name).standardizedFileURL.path)
            }
        }
        return files.compactMap { file in
            guard !members.contains(file.standardizedFileURL.path) else { return nil }
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
            var head = prefix(file.path)
            if ["cue", "gdi"].contains(file.pathExtension.lowercased()) {
                // O cabeçalho de um disco está na primeira faixa, não no índice.
                let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                if let first = ROMPlan.referencedFiles(cueSheet: text, extension: file.pathExtension).first {
                    head = prefix(file.deletingLastPathComponent().appendingPathComponent(first).path)
                }
            }
            let result = detector.detect(path: file.path, prefix: head, size: size)
            return result == .unknown ? nil : ROMCandidate(path: file.path, size: size, detection: result)
        }
    }
}

extension ROMScanner {
    /// Separa o que é BIOS conhecida pelo hash; o tamanho evita ler jogos inteiros à toa.
    public static func biosFiles(_ urls: [URL], table: [BIOSEntry]) async -> [String] {
        let sizes = Set(table.map { Int64($0.size) })
        var files: [URL] = []
        for url in urls {
            if let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                while let item = walker.nextObject() as? URL { files.append(item) }
            } else {
                files.append(url)
            }
        }
        var found: [String] = []
        for file in files {
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? -1
            guard sizes.contains(size), let sha1 = try? await LocalHash.compute(file.path, algorithm: 1) else { continue }
            if BIOS.match(sha1: sha1, table: table) != nil { found.append(file.path) }
        }
        return found
    }
}

public struct ROMImportResult: Equatable, Sendable {
    public var remotePath: String
    public var skippedAsDuplicate: Bool
}

public struct RomImporter: Sendable {
    public let runner: any CommandRunner
    public let config: SSHConfig
    public let catalog: Catalog
    public let workRoot: URL

    public init(runner: any CommandRunner, config: SSHConfig, catalog: Catalog, workRoot: URL) {
        self.runner = runner
        self.config = config
        self.catalog = catalog
        self.workRoot = workRoot
    }

    public typealias Progress = @Sendable (Int?, String?) -> Void
    static let indexPath = ".local/share/quietdeck/rom-index.tsv"

    /// Mapa `hash da origem → arquivo no Deck`. Conferido no Deck: um arquivo apagado à mão reenvia.
    func duplicate(of hash: String, files: RemoteFiles, home: String) async throws -> String? {
        guard let data = try await files.read(home + "/" + Self.indexPath) else { return nil }
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let f = line.split(separator: "\t").map(String.init)
            guard f.count == 3, f[0] == hash else { continue }
            let size = try await runner.run("stat -c %s \(Shell.quote(f[1])) 2>/dev/null")
            if size.trimmed == f[2] { return f[1] }
        }
        return nil
    }

    func record(hash: String, path: String, size: Int64, home: String) async throws {
        let index = Shell.quote(home + "/" + Self.indexPath)
        let line = Shell.quote("\(hash)\t\(path)\t\(size)")
        try await runner.check("mkdir -p \"$(dirname \(index))\" && printf '%s\\n' \(line) >> \(index)")
    }

    private func checkFreeSpace(_ needed: Int64, directory: String) async throws {
        let r = try await runner.check("df -B1 --output=avail \(Shell.quote(directory)) | tail -1")
        if let free = Int64(r.trimmed), free < needed {
            throw DeckError.unexpectedState("Not enough space on the Deck: \(needed / 1_048_576) MB needed, \(free / 1_048_576) MB free.")
        }
    }

    private func run(_ tool: String, _ args: [String], _ label: String) async throws {
        let r = try await LocalProcess.run(tool, args)
        guard r.ok else { throw DeckError.commandFailed(command: label, result: r) }
    }

    /// Pasta de trabalho por hash: repetir aproveita a extração e o CHD já prontos.
    private func extract(_ source: URL, to dir: URL) async throws {
        let marker = dir.appendingPathComponent(".done")
        if FileManager.default.fileExists(atPath: marker.path) { return }
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if source.pathExtension.lowercased() == "zip" {
            try await run("/usr/bin/unzip", ["-o", "-q", source.path, "-d", dir.path], "unzip")
        } else {
            let tool = try await LocalTools.require(["7zz", "7z"], formula: "sevenzip")
            try await run(tool, ["x", "-y", "-o\(dir.path)", source.path], "7z")
        }
        FileManager.default.createFile(atPath: marker.path, contents: nil)
    }

    private func convert(_ input: URL, mode: ROMPlan.Conversion, work: URL) async throws -> URL {
        let output = work.appendingPathComponent(input.deletingPathExtension().lastPathComponent + ".chd")
        if FileManager.default.fileExists(atPath: output.path) { return output }
        let tool = try await LocalTools.require(["chdman"], formula: "rom-tools")
        // Só um CHD completo ganha o nome final: chdman interrompido deixa arquivo pela metade.
        let partial = output.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)
        try await run(tool, [mode.rawValue, "-i", input.path, "-o", partial.path, "-f"], "chdman \(mode.rawValue)")
        try FileManager.default.moveItem(at: partial, to: output)
        return output
    }

    /// Arquivos que acompanham o ponto de entrada quando ele vai sem conversão.
    private func companions(of entry: URL) -> [URL] {
        guard ["cue", "gdi"].contains(entry.pathExtension.lowercased()),
              let text = try? String(contentsOf: entry, encoding: .utf8) else { return [entry] }
        let dir = entry.deletingLastPathComponent()
        return [entry] + ROMPlan.referencedFiles(cueSheet: text, extension: entry.pathExtension).map { dir.appendingPathComponent($0) }
    }

    public func importGame(path: String, systemID: String, paths: EmulationPaths, progress: @escaping Progress) async throws -> ROMImportResult {
        guard let system = catalog.system(systemID) else { throw DeckError.unexpectedState("Unknown system: \(systemID)") }
        let source = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            throw DeckError.unexpectedState("\(source.lastPathComponent) isn't there anymore. Is the network share mounted?")
        }
        let files = RemoteFiles(runner: runner)
        let home = try await files.home()

        progress(nil, "Hashing \(source.lastPathComponent)")
        let hash = try await LocalHash.compute(path, algorithm: 256)
        if let existing = try await duplicate(of: hash, files: files, home: home) {
            progress(100, "Already on the Deck")
            return ROMImportResult(remotePath: existing, skippedAsDuplicate: true)
        }

        let work = workRoot.appendingPathComponent(hash)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        var entries = [source]
        if ROMPlan.mustExtract(system: system, fileExtension: source.pathExtension) {
            progress(nil, "Extracting")
            let dir = work.appendingPathComponent("extracted")
            try await extract(source, to: dir)
            entries = ROMScanner.scan([dir], catalog: catalog).map { URL(fileURLWithPath: $0.path) }
            guard !entries.isEmpty else { throw DeckError.unexpectedState("No game found inside \(source.lastPathComponent).") }
        }

        var outputs: [URL] = []
        for entry in entries {
            let size = (try? FileManager.default.attributesOfItem(atPath: entry.path)[.size] as? Int64) ?? 0
            if let mode = ROMPlan.conversion(for: system, fileExtension: entry.pathExtension, size: size) {
                progress(nil, "Converting \(entry.lastPathComponent) to CHD")
                outputs.append(try await convert(entry, mode: mode, work: work))
            } else {
                outputs += companions(of: entry)
            }
        }

        let directory = "\(paths.roms)/\(system.folder)"
        try await runner.check("mkdir -p \(Shell.quote(directory))")
        let total = outputs.reduce(Int64(0)) { $0 + ((try? FileManager.default.attributesOfItem(atPath: $1.path)[.size] as? Int64) ?? 0) }
        try await checkFreeSpace(total, directory: directory)
        for (i, output) in outputs.enumerated() {
            let count = outputs.count
            try await Transfer.upload(output, to: directory, config: config) { p in
                progress((i * 100 + p.percent) / count, "Sending \(output.lastPathComponent) \(p.rate ?? "")")
            }
        }

        let main = directory + "/" + outputs[0].lastPathComponent
        let mainSize = (try? FileManager.default.attributesOfItem(atPath: outputs[0].path)[.size] as? Int64) ?? 0
        let verified = try await runner.run("stat -c %s \(Shell.quote(main))").trimmed
        guard verified == String(mainSize) else { throw DeckError.unexpectedState("The file on the Deck has \(verified) bytes, expected \(mainSize).") }
        try await record(hash: hash, path: main, size: mainSize, home: home)
        let playlist = try await updatePlaylist(for: outputs[0].lastPathComponent, directory: directory)
        // Pastas de trabalho crescem como as ROMs: depois de confirmar no Deck, não servem mais.
        try? FileManager.default.removeItem(at: work)
        return ROMImportResult(remotePath: playlist ?? main, skippedAsDuplicate: false)
    }

    /// Olha a pasta real: os discos podem ter chegado em trabalhos diferentes.
    func updatePlaylist(for fileName: String, directory: String) async throws -> String? {
        guard let base = ROMPlan.discInfo(fileName)?.base else { return nil }
        let listing = try await runner.check("ls -1 \(Shell.quote(directory))").stdout.split(whereSeparator: \.isNewline).map(String.init)
        let discs = listing.filter { ROMPlan.discInfo($0)?.base == base && !$0.lowercased().hasSuffix(".m3u") }
        guard let playlist = ROMPlan.playlists(for: discs).first else { return nil }
        let path = directory + "/" + playlist.name
        let files = RemoteFiles(runner: runner)
        if try await files.read(path) != Data(playlist.contents.utf8) { try await files.write(Data(playlist.contents.utf8), to: path) }
        return path
    }
}

public enum Library {
    public static func listing(paths: EmulationPaths) -> String {
        "cd \(Shell.quote(paths.roms)) 2>/dev/null && find . -mindepth 2 -maxdepth 3 -type f -printf '%s\\t%P\\n'"
    }

    public struct Game: Equatable, Identifiable, Sendable {
        public var systemID: String
        public var name: String
        public var path: String
        public var size: Int64
        public var id: String { path }
    }

    public static func parse(_ text: String, systems: [GameSystem], paths: EmulationPaths) -> [Game] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard f.count == 2, let size = Int64(f[0]) else { return nil }
            let relative = f[1], name = (relative as NSString).lastPathComponent
            guard let system = systems.first(where: { relative.hasPrefix($0.folder + "/") }),
                  system.extensions.contains((name as NSString).pathExtension.lowercased()) else { return nil }
            return Game(systemID: system.id, name: name, path: "\(paths.roms)/\(relative)", size: size)
        }
    }

    /// O `.m3u` representa o conjunto de discos; sem ele, o primeiro arquivo do título.
    public static func pick(_ ref: GameRef, in games: [Game]) -> Game? {
        let matches = games.filter { $0.systemID == ref.systemID && ROMPlan.displayName($0.name) == ref.title }
        return matches.first { $0.name.lowercased().hasSuffix(".m3u") } ?? matches.sorted { $0.name < $1.name }.first
    }

    /// Exe, diretório e argumentos do atalho. Steam interpreta aspas duplas em `LaunchOptions`.
    public static func shortcut(name: String, romPath: String, system: GameSystem, catalog: Catalog, corePath: String?) -> Shortcut? {
        guard let emulator = catalog.emulator(system.emulator), emulator.isAvailable, let template = emulator.launch else { return nil }
        func q(_ s: String) -> String { "\"\(s)\"" }
        let options = template.replacingOccurrences(of: "{rom}", with: q(romPath)).replacingOccurrences(of: "{core}", with: q(corePath ?? ""))
        return Shortcut(name: name, exe: "/usr/bin/flatpak", startDir: "/usr/bin", launchOptions: options, tags: [system.name])
    }
}
