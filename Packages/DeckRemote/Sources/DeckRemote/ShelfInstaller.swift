import Foundation
import DeckKit

/// O que a Estante pôs no Deck. Fica no próprio Deck: o status "instalado" não depende do Mac.
public struct ShelfManifestEntry: Codable, Equatable, Sendable {
    public var title: String
    public var systemID: String
    public var files: [String]
    public var size: Int64
}

public struct ShelfInstaller: Sendable {
    let runner: any CommandRunner
    let config: SSHConfig
    let catalog: Catalog
    let workRoot: URL
    let client: (@Sendable (LibrarySource) -> SourceClient)?
    let deckServiceURL: String?

    public init(runner: any CommandRunner, config: SSHConfig, catalog: Catalog, workRoot: URL,
                client: (@Sendable (LibrarySource) -> SourceClient)? = nil, deckServiceURL: String? = nil) {
        self.runner = runner
        self.config = config
        self.catalog = catalog
        self.workRoot = workRoot
        self.client = client
        self.deckServiceURL = deckServiceURL
    }

    static let manifestPath = ".local/share/quietdeck/shelf.json"
    public typealias Progress = @Sendable (Int?, String?) -> Void

    public static func manifest(_ runner: any CommandRunner) async throws -> [String: ShelfManifestEntry] {
        let files = RemoteFiles(runner: runner)
        guard let data = try await files.read(try await files.home() + "/" + manifestPath) else { return [:] }
        // Manifesto ilegível lança: devolver vazio faria o próximo `save` apagar o registro da Estante.
        return try JSONDecoder().decode([String: ShelfManifestEntry].self, from: data)
    }

    private func save(_ manifest: [String: ShelfManifestEntry]) async throws {
        let files = RemoteFiles(runner: runner)
        try await files.write(try JSONEncoder().encode(manifest), to: try await files.home() + "/" + Self.manifestPath)
    }

    /// Só vai direto do servidor ao Deck o que não passa pelo Mac para extrair ou converter.
    static func canGoDirect(_ item: ShelfItem, system: GameSystem) -> Bool {
        let ext = (item.entry as NSString).pathExtension
        return item.members.isEmpty && !ROMPlan.mustExtract(system: system, fileExtension: ext)
            && !ROMPlan.mustDecompress(system: system, fileExtension: ext)
            && ROMPlan.conversion(for: system, fileExtension: ext, size: item.size) == nil
    }

    static func relative(_ path: String, to root: String) -> String {
        path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
    }

    static func fileURL(service: String, path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#")
        return service.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/files/" + (path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path)
    }

    public func install(_ item: ShelfItem, from source: LibrarySource, paths: EmulationPaths, progress: @escaping Progress) async throws -> [String] {
        guard let system = catalog.system(item.systemID) else { throw DeckError.unexpectedState("Unknown system: %@", item.systemID) }
        var manifest = try await Self.manifest(runner)
        if let entry = manifest[item.id], try await allPresent(entry.files) {
            progress(100, "Already on the Deck")
            return entry.files
        }
        let files: [String]
        if case let .service(url) = source.kind, Self.canGoDirect(item, system: system) {
            files = [try await direct(item, secret: client?(source).secret, service: deckServiceURL ?? url, directory: "\(paths.roms)/\(system.folder)", progress: progress)]
        } else {
            let local = try await fetch(item, from: source, progress: progress)
            let importer = RomImporter(runner: runner, config: config, catalog: catalog, workRoot: workRoot)
            files = try await importer.importGame(path: local, systemID: item.systemID, paths: paths, progress: progress).files
            // Só depois de instalar: num erro, a cópia parcial serve para retomar.
            try? FileManager.default.removeItem(at: workRoot.appendingPathComponent("shelf/" + item.id.replacingOccurrences(of: "/", with: "_")))
        }
        manifest[item.id] = ShelfManifestEntry(title: item.title, systemID: item.systemID, files: files, size: item.size)
        try await save(manifest)
        return files
    }

    /// O que está de fato no Deck: arquivo apagado à mão volta a aparecer como não instalado.
    public static func installed(_ runner: any CommandRunner) async throws -> [String: ShelfManifestEntry] {
        let manifest = try await manifest(runner)
        guard !manifest.isEmpty else { return [:] }
        let script = manifest.map { id, entry in
            (entry.files.map { "test -e \(Shell.quote($0))" } + ["echo \(Shell.quote(id))"]).joined(separator: " && ")
        }.joined(separator: "; ")
        // `run`, não `check`: o status é o do último teste, e a resposta está no que foi ecoado.
        let present = try await runner.run(script).stdout.split(whereSeparator: \.isNewline).map(String.init)
        return manifest.filter { present.contains($0.key) }
    }

    /// Só baixa da fonte oficial do catálogo e só instala se o SHA-256 bater.
    public func installFree(_ game: FreeGame, paths: EmulationPaths, progress: @escaping Progress) async throws -> [String] {
        let item = game.item
        var manifest = try await Self.manifest(runner)
        if let entry = manifest[item.id], try await allPresent(entry.files) {
            progress(100, "Already on the Deck")
            return entry.files
        }
        let directory = workRoot.appendingPathComponent("free/" + game.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let local = directory.appendingPathComponent(game.fileName).path
        progress(nil, "Downloading from the official source")
        let r = try await LocalProcess.run("/usr/bin/curl", ["-fsSL", "-o", local, game.download])
        guard r.ok else { throw DeckError.commandFailed(command: "curl \(game.fileName)", result: r) }
        guard try await LocalHash.compute(local, algorithm: 256) == game.sha256 else {
            throw DeckError.unexpectedState("%@ doesn't match the catalog checksum, so it wasn't installed.", game.title)
        }
        let importer = RomImporter(runner: runner, config: config, catalog: catalog, workRoot: workRoot)
        let files = try await importer.importGame(path: local, systemID: game.system, paths: paths, progress: progress).files
        manifest[item.id] = ShelfManifestEntry(title: game.title, systemID: game.system, files: files, size: game.size)
        try await save(manifest)
        return files
    }

    private func allPresent(_ files: [String]) async throws -> Bool {
        try await runner.run(files.map { "test -e \(Shell.quote($0))" }.joined(separator: " && ")).ok
    }

    /// O Deck baixa do serviço e confere o SHA1, com o Mac só acompanhando.
    private func direct(_ item: ShelfItem, secret: SourceSecret?, service: String, directory: String, progress: Progress) async throws -> String {
        let name = (item.entry as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { throw DeckError.unexpectedState("Invalid file name: %@", name) }
        let target = "\(directory)/\(name)", partial = target + ".quietdeck-part"
        try await RemoteFiles(runner: runner).ensureSpace(item.size, in: directory)
        progress(nil, "Sending")
        let url = Self.fileURL(service: service, path: item.entry)
        let script = "curl -fsS -K - -C - -o \(Shell.quote(partial)) \(Shell.quote(url)) && test \"$(sha1sum \(Shell.quote(partial)) | cut -d' ' -f1)\" = \(Shell.quote(item.id)) && mv -f \(Shell.quote(partial)) \(Shell.quote(target))"
        try await runner.check(RemoteCommand(script, stdin: Curl.config([Curl.bearer(secret?.token ?? "")]), timeout: 21600))
        progress(100, "Sending")
        return target
    }

    /// Traz para o Mac só quando há o que processar aqui.
    private func fetch(_ item: ShelfItem, from source: LibrarySource, progress: Progress) async throws -> String {
        let origin = item.origins.first { $0.sourceID == source.id } ?? ShelfOrigin(sourceID: source.id, entry: item.entry, members: item.members)
        switch source.kind {
        case .folder, .smb, .nfs: return origin.entry
        default: break
        }
        guard let client = client?(source) else { throw DeckError.unexpectedState("%@ isn't available.", source.name) }
        let directory = workRoot.appendingPathComponent("shelf/" + item.id.replacingOccurrences(of: "/", with: "_"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        progress(nil, "Downloading from the server")
        return try await client.download(origin, to: directory)
    }

    /// Apaga só o que a Estante registrou. Com atalho, o Steam reinicia: a UI confirma antes.
    public func remove(_ item: ShelfItem, user: String?) async throws {
        var manifest = try await Self.manifest(runner)
        guard let entry = manifest[item.id] else { return }
        let home = try await RemoteFiles(runner: runner).home()
        for file in entry.files where !Self.isSafeToDelete(file, home: home) {
            throw DeckError.unexpectedState("%@ isn't in a ROM folder, so it wasn't deleted.", file)
        }
        try await runner.check(entry.files.map { "rm -f \(Shell.quote($0))" }.joined(separator: "; "))
        try await cleanPlaylists(entry.files)
        try await forgetIndex(entry.files, home: home)
        if let user {
            _ = try await SteamControl(runner: runner).removeShortcuts(names: [item.deckTitle], user: user)
        }
        manifest[item.id] = nil
        try await save(manifest)
    }

    static func isSafeToDelete(_ path: String, home: String) -> Bool {
        (path.hasPrefix(home + "/") || path.hasPrefix("/run/media/")) && path.contains("/roms/") && !path.contains("/../")
    }

    /// Disco removido não pode ficar citado: a playlist quebraria ou sairia com um disco só.
    private func cleanPlaylists(_ removed: [String]) async throws {
        let importer = RomImporter(runner: runner, config: config, catalog: catalog, workRoot: workRoot)
        for file in removed {
            let name = (file as NSString).lastPathComponent, directory = (file as NSString).deletingLastPathComponent
            guard let base = ROMPlan.discInfo(name)?.base else { continue }
            let playlist = "\(directory)/\(base).m3u"
            if try await importer.updatePlaylist(for: name, directory: directory) == nil {
                try await runner.check("rm -f \(Shell.quote(playlist))")
            }
        }
    }

    private func forgetIndex(_ removed: [String], home: String) async throws {
        let files = RemoteFiles(runner: runner), path = home + "/" + RomImporter.indexPath
        guard let data = try await files.read(path) else { return }
        let kept = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).filter { line in
            !removed.contains { line.contains("\t\($0)\t") }
        }
        try await files.write(Data((kept.joined(separator: "\n") + "\n").utf8), to: path)
    }
}
