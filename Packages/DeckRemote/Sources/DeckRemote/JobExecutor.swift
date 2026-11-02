import DeckKit
import Foundation

public struct JobContext: Sendable {
    var runner: any CommandRunner
    var config: SSHConfig
    var catalog: Catalog
    var password: String?
    var workRoot: URL
    /// Cliente de cada fonte, com o segredo lido do Keychain só na hora do uso.
    var shelfClient: (@Sendable (LibrarySource) -> SourceClient)?
    /// Endereço do serviço visto pelo Deck, quando difere do visto pelo Mac.
    var deckServiceURL: String?
    /// Conta do RetroAchievements lida do Keychain na hora: o token não passa pela fila.
    public var achievements: RetroAchievementsAccount?
    /// A senha do Keychain deixou de valer: o app apaga a cópia para pedir de novo.
    var onSudoRejected: @Sendable () async -> Void

    public init(runner: any CommandRunner, config: SSHConfig, catalog: Catalog, password: String?, workRoot: URL,
                shelfClient: (@Sendable (LibrarySource) -> SourceClient)? = nil, deckServiceURL: String? = nil,
                achievements: RetroAchievementsAccount? = nil, onSudoRejected: @escaping @Sendable () async -> Void) {
        self.achievements = achievements
        self.runner = runner
        self.config = config
        self.catalog = catalog
        self.password = password
        self.workRoot = workRoot
        self.shelfClient = shelfClient
        self.deckServiceURL = deckServiceURL
        self.onSudoRejected = onSudoRejected
    }

    func requirePassword() throws -> String {
        guard let password else { throw DeckError.sudoPasswordMissing }
        return password
    }
}

/// Liga cada `JobAction` à operação. As operações leem o estado no Deck antes de agir.
public enum JobExecutor {
    public static func run(_ job: Job, context c: JobContext, progress: @escaping JobQueue.Progress) async throws {
        let r = c.runner
        let live: LocalProcess.Output = { chunk in
            if let line = chunk.split(whereSeparator: \.isNewline).last { progress(nil, String(line.prefix(120))) }
        }
        let transfer: @Sendable (TransferProgress) -> Void = { progress($0.percent, $0.rate) }
        do {
            switch job.action {
            case let .installEmulator(id): try note(await Flatpaks.install(id, runner: r, onOutput: live), progress)
            case let .updateEmulator(id): try note(await Flatpaks.update(id, runner: r, onOutput: live), progress)
            case let .removeEmulator(id): try note(await Flatpaks.remove(id, runner: r), progress)
            case let .prepareEmulation(sd):
                let paths = try await Emulation.paths(r, sdMount: sd)
                let created = try await Emulation.prepare(r, paths: paths, systems: c.catalog.systems)
                progress(100, "Folders ready")
            case let .configureEmulator(id, overwrite, sd):
                guard let emulator = c.catalog.emulator(id) else { return }
                let paths = try await Emulation.paths(r, sdMount: sd)
                switch try await EmulatorSetup.configure(emulator, paths: paths, overwrite: overwrite, runner: r) {
                case .written: progress(100, "Paths written")
                case .unchanged: progress(100, "Paths already set")
                case .skippedEmuDeck: progress(100, "EmuDeck manages this emulator")
                case .notConfigurable: progress(100, emulator.note ?? "Nothing to set")
                case let .needsConfirmation(path): throw DeckError.unexpectedState("%@ already exists.", path)
                }
            case let .upload(local, remote):
                try await Transfer.upload(URL(fileURLWithPath: local), to: remote, config: c.config, onProgress: transfer)
            case let .importROM(local, system, sd, patch):
                let paths = try await Emulation.paths(r, sdMount: sd)
                let importer = RomImporter(runner: r, config: c.config, catalog: c.catalog, workRoot: c.workRoot)
                _ = try await importer.importGame(path: local, systemID: system, paths: paths, patch: patch, progress: progress)
            case let .addToSteam(user, refs, sd): try await addToSteam(user, refs, sd, c, progress)
            case let .applyArt(user, appID, kind, url):
                let dir = try await SteamControl(runner: r).configDirectory(user: user) + "/grid"
                try await r.check(RemoteCommand(Art.script(url: url, kind: kind, appID: appID, gridDirectory: dir), timeout: 120))
            case let .applyArtFile(user, appID, kind, local):
                let dir = try await SteamControl(runner: r).configDirectory(user: user) + "/grid"
                let data = try Data(contentsOf: URL(fileURLWithPath: local))
                try await RemoteFiles(runner: r).write(data, to: dir + "/" + kind.fileName(appID: appID))
            case .installDecky: try await Decky.install(r, password: c.requirePassword(), onOutput: live)
            case let .installPlugin(name, version):
                _ = try await Decky.installPlugin(name: name, version: version, runner: r, password: c.requirePassword())
            case let .removePlugin(name):
                _ = try await Decky.removePlugin(name: name, runner: r, password: c.requirePassword())
            case let .installCompatTool(archive, checksum, folder):
                _ = try await CompatTools.install(archive: archive, checksum: checksum, folderName: folder, runner: r, onOutput: live)
            case let .removeCompatTool(name): _ = try await CompatTools.remove(name, runner: r)
            case let .backupSaves(local):
                let paths = try await Emulation.paths(r)
                let n = try await Saves.backup(paths: paths, emulators: c.catalog.emulators, to: URL(fileURLWithPath: local), config: c.config, runner: r, onProgress: transfer)
                progress(100, "Done")
            case let .restoreSaves(local):
                let paths = try await Emulation.paths(r)
                let n = try await Saves.restore(paths: paths, emulators: c.catalog.emulators, from: URL(fileURLWithPath: local), config: c.config, runner: r, onProgress: transfer)
                progress(100, "Done")
            case let .importBIOS(local, sd): try await importBIOS(local, sd, c, transfer)
            case let .quickAction(action): try await action.run(r, password: c.password)
            case let .shelfInstall(item, source, sd):
                let paths = try await Emulation.paths(r, sdMount: sd)
                _ = try await installer(c).install(item, from: source, paths: paths, progress: progress)
            case let .freeInstall(game, sd):
                let paths = try await Emulation.paths(r, sdMount: sd)
                _ = try await installer(c).installFree(game, paths: paths, progress: progress)
            case let .shelfRemove(item, user):
                try await installer(c).remove(item, user: user)
            case .applyQuietGlass:
                try await QuietTheme.applyGlass(r, password: c.requirePassword())
                progress(100, "Quiet Glass applied")
            case .removeQuietGlass:
                try await QuietTheme.removeGlass(r, password: c.requirePassword())
                progress(100, "Quiet Glass removed")
            case let .applyAchievements(signedIn):
                let installed = Set(try await Flatpaks.installed(r).map(\.appID))
                let account = signedIn ? c.achievements : nil
                for emulator in c.catalog.emulators where installed.contains(emulator.flatpak) {
                    _ = try await EmulatorSetup.applyAchievements(emulator, account: account, runner: r)
                }
                progress(100, signedIn ? "Achievements on" : "Achievements off")
            case .installQuietHome:
                let result = try await BundledPlugin.quietHome.install(runner: r, password: c.requirePassword())
                progress(100, result == .installed ? "Quiet Home installed" : "Already installed")
            case let .applyTheme(user, model):
                let result = try await QuietTheme.apply(r, user: user, model: model, password: c.password)
                progress(100, result == .live ? "Theme applied" : "Applied after the next reboot")
            case let .restoreTheme(user):
                let result = try await QuietTheme.restore(r, user: user, password: c.password)
                progress(100, result == .live ? "Valve defaults restored" : "Applied after the next reboot")
            }
        } catch DeckError.sudoRejected {
            await c.onSudoRejected()
            throw DeckError.sudoRejected
        }
    }

    private static func installer(_ c: JobContext) -> ShelfInstaller {
        ShelfInstaller(runner: c.runner, config: c.config, catalog: c.catalog, workRoot: c.workRoot,
                       client: c.shelfClient, deckServiceURL: c.deckServiceURL)
    }

    private static func note(_ outcome: Flatpaks.Outcome, _ progress: JobQueue.Progress) throws {
        switch outcome {
        case .done: break
        case .alreadyInstalled: progress(100, "Already installed")
        case .notInstalled: progress(100, "Not installed")
        case .systemInstall: throw DeckError.unexpectedState("This app is installed system-wide, and QuietDeck only manages --user installs.")
        }
    }

    /// A entrada é só o hash: o nome do arquivo não prova nada. Nunca baixa BIOS.
    private static func importBIOS(_ local: String, _ sd: String?, _ c: JobContext, _ transfer: @escaping @Sendable (TransferProgress) -> Void) async throws {
        let sha1 = try await LocalHash.compute(local, algorithm: 1)
        guard let entry = BIOS.match(sha1: sha1, table: c.catalog.bios.entries) else {
            throw DeckError.unexpectedState("%@ doesn't match any known BIOS hash, so it wasn't copied.", (local as NSString).lastPathComponent)
        }
        let paths = try await Emulation.paths(c.runner, sdMount: sd)
        let target = "\(paths.bios)/\(entry.file)"
        if try await c.runner.run("sha1sum \(Shell.quote(target)) 2>/dev/null").stdout.hasPrefix(entry.sha1) { return }
        // O destino usa o nome canônico, então o upload sai de uma cópia temporária com esse nome.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let copy = dir.appendingPathComponent((entry.file as NSString).lastPathComponent)
        try FileManager.default.copyItem(atPath: local, toPath: copy.path)
        let folder = (target as NSString).deletingLastPathComponent
        try await c.runner.check("mkdir -p \(Shell.quote(folder))")
        try await Transfer.upload(copy, to: folder, config: c.config, onProgress: transfer)
    }

    private static func addToSteam(_ user: String, _ refs: [GameRef], _ sd: String?, _ c: JobContext, _ progress: JobQueue.Progress) async throws {
        let r = c.runner
        let paths = try await Emulation.paths(r, sdMount: sd)
        let listing = try await r.check(Library.listing(paths: paths)).stdout
        let games = Library.parse(listing, systems: c.catalog.systems, paths: paths)
        var shortcuts: [Shortcut] = []
        var emulators: [Emulator] = []
        for ref in refs {
            guard let game = Library.pick(ref, in: games), let system = c.catalog.system(ref.systemID),
                  let emulator = c.catalog.emulator(system.emulator) else { continue }
            if !emulators.contains(emulator) { emulators.append(emulator) }
            progress(nil, "Preparing the emulator")
            _ = try await Flatpaks.install(emulator.flatpak, runner: r)
            if !paths.isEmuDeck { _ = try await EmulatorSetup.applyProfiles(emulator, runner: r) }
            if system.id == "switch" { try await SwitchKeys.send(config: c.config, runner: r) }
            // O flatpak só enxerga a pasta pessoal: no microSD o jogo não abriria.
            if paths.roms.hasPrefix("/run/media/") {
                try await r.check("flatpak override --user --filesystem=\(Shell.quote(paths.roms)):ro \(Shell.quote(emulator.flatpak))")
            }
            var core: String?
            if let name = system.core { core = try await EmulatorSetup.ensureCore(name, runner: r) }
            if let s = Library.shortcut(name: ref.title, romPath: game.path, system: system, catalog: c.catalog, corePath: core) { shortcuts.append(s) }
        }
        guard !shortcuts.isEmpty else { throw DeckError.unexpectedState("The game isn't on the Deck in this location, so no shortcut was created.") }
        let steam = SteamControl(runner: r)
        let known = try await steam.lastPlayed(user: user)
        if shortcuts.contains(where: { known[$0.name] == nil }) {
            while try await steam.gameOpen() {
                progress(nil, "Waiting for the game to close")
                try await Task.sleep(for: .seconds(15))
            }
        }
        if let account = c.achievements, !paths.isEmuDeck {
            for emulator in emulators {
                // Emulador aberto com jogo antigo: grava na próxima vez, sem derrubar o atalho.
                if try await EmulatorSetup.isOpen(emulator, runner: r) {
                    progress(nil, "Achievements wait until the emulator is closed")
                    continue
                }
                _ = try await EmulatorSetup.applyAchievements(emulator, account: account, runner: r)
            }
        }
        progress(nil, "Writing shortcuts")
        let result = try await steam.addShortcuts(shortcuts, user: user)
        progress(100, result.added.isEmpty ? "Already in Steam" : "Added to Steam")
    }
}
