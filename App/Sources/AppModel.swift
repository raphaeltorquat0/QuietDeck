import AppKit
import DeckKit
import DeckRemote
import Foundation
import Observation
import SwiftUI

struct DeckProfile: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var host: String
    var port = 22
    var user = "deck"
    /// `nil` em perfis antigos: a ed25519 do pareamento por senha. Devkit usa a RSA.
    var identityFile: String?
}

enum AppSection: String, CaseIterable, Identifiable {
    case overview, emulators, library, shelf, decky, compatTools, saves
    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .overview: "Overview"
        case .emulators: "Emulators"
        case .library: "Library"
        case .shelf: "Shelf"
        case .decky: "Decky"
        case .compatTools: "Compat Tools"
        case .saves: "Saves"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .emulators: "gamecontroller"
        case .library: "square.stack.3d.up"
        case .shelf: "books.vertical"
        case .decky: "puzzlepiece.extension"
        case .compatTools: "wineglass"
        case .saves: "externaldrive.badge.timemachine"
        }
    }
}

enum Paths {
    static let support: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "QuietDeck")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    static let key = NSHomeDirectory() + "/.ssh/quietdeck_ed25519"
    static let devkitKey = NSHomeDirectory() + "/.ssh/quietdeck_devkit_rsa"
    static let covers: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "QuietDeck/covers")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    static var knownHosts: String { support.appending(path: "known_hosts").path }
    static var work: URL { support.appending(path: "rom-work") }
}

/// Preferências locais do app (não ficam no Deck).
@MainActor @Observable
final class AppSettings {
    @ObservationIgnored private let d = UserDefaults.standard
    var showMenuBarExtra: Bool { didSet { d.set(showMenuBarExtra, forKey: "showMenuBarExtra") } }
    var syncFolders: [String] { didSet { d.set(syncFolders, forKey: "syncFolders") } }
    var savesFolder: String? { didSet { d.set(savesFolder, forKey: "savesFolder") } }
    var onboarded: Bool { didSet { d.set(onboarded, forKey: "onboarded") } }
    var completionSound: Bool { didSet { d.set(completionSound, forKey: "completionSound") } }
    var shelfSources: [LibrarySource] { didSet { d.set(try? JSONEncoder().encode(shelfSources), forKey: "shelfSources") } }

    init() {
        d.register(defaults: ["showMenuBarExtra": true])
        showMenuBarExtra = d.bool(forKey: "showMenuBarExtra")
        syncFolders = d.stringArray(forKey: "syncFolders") ?? []
        savesFolder = d.string(forKey: "savesFolder")
        onboarded = d.bool(forKey: "onboarded")
        completionSound = d.bool(forKey: "completionSound")
        shelfSources = d.data(forKey: "shelfSources").flatMap { try? JSONDecoder().decode([LibrarySource].self, from: $0) } ?? []
    }
}

/// Estado e ações do app. Tudo que fala com o Deck é assíncrono: a UI só observa.
@MainActor @Observable
final class AppModel {
    static let steamGridKeyAccount = "steamgriddb"
    static let retroAchievementsAccount = "retroachievements"
    static let screenScraperAccount = "screenscraper"
    static let igdbAccount = "igdb"

    let settings = AppSettings()
    let catalog: Catalog
    private(set) var decks: [DeckProfile]
    var selectedDeckID: UUID? { didSet { UserDefaults.standard.set(selectedDeckID?.uuidString, forKey: "selectedDeck") } }
    var section: AppSection? = .overview
    var showOnboarding = false
    var showPalette = false
    var openGame: Library.Game?
    var toast: Toast?
    /// Capas em voo da Biblioteca até a fila.
    var flights: [CoverFlight] = []
    let covers = CoverStore()
    let shelf = ShelfStore()
    private(set) var live: [UUID: LiveDeck] = [:]
    @ObservationIgnored private var queueStore = Paths.support.appending(path: "queue.json")
    @ObservationIgnored private(set) lazy var queue = JobQueue(storeURL: queueStore) { [weak self] job, progress in
        guard let context = await self?.context(job.deckID) else { throw DeckError.unreachable("This Deck isn't connected.") }
        try await JobExecutor.run(job, context: context, progress: progress)
        await self?.live[job.deckID]?.refresh()
    }

    struct Toast: Identifiable, Equatable {
        var id = UUID()
        var title: String
        var detail: String?
        var isError: Bool
    }

    /// Traduz pela chave em inglês do pacote; o que não estiver no catálogo sai em inglês.
    nonisolated func describe(_ error: Error) -> String {
        guard let e = error as? DeckError else { return String(describing: error) }
        let (key, arguments) = e.message
        return arguments.reduce(Bundle.main.localizedString(forKey: key, value: key, table: nil)) { text, value in
            guard let range = text.range(of: "%@") else { return text }
            return text.replacingCharacters(in: range, with: value)
        }
    }

    private func wireQueue() {
        queue.describe = { [weak self] in self?.describe($0) ?? String(describing: $0) }
        queue.onFinish = { [weak self] job in self?.finished(job) }
    }

    private func finished(_ job: Job) {
        switch job.state {
        case .succeeded:
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            if settings.completionSound { NSSound(named: "Glass")?.play() }
        case let .failed(message):
            Motion.run { toast = Toast(title: job.title, detail: message, isError: true) }
        default: break
        }
    }

    /// Dispara a capa até a fila, de onde o trabalho segue.
    func launch(title: String, from frame: CGRect) {
        guard !Motion.reduced else { return }
        flights.append(CoverFlight(title: title, from: frame))
    }

    init(catalog: Catalog) {
        self.catalog = catalog
        decks = (UserDefaults.standard.data(forKey: "decks")).flatMap { try? JSONDecoder().decode([DeckProfile].self, from: $0) } ?? []
        selectedDeckID = UserDefaults.standard.string(forKey: "selectedDeck").flatMap(UUID.init) ?? decks.first?.id
        for deck in decks { live[deck.id] = makeLive(deck) }
        showOnboarding = !settings.onboarded
        wireQueue()
    }

    /// `--replay`/PressKit: um Deck que responde pelas fixtures.
    init(demo runner: any CommandRunner, catalog: Catalog, queueStore: URL) {
        self.catalog = catalog
        self.queueStore = queueStore
        let deck = DeckProfile(name: "Steam Deck", host: "steamdeck.local")
        decks = [deck]
        selectedDeckID = deck.id
        live[deck.id] = LiveDeck(profile: deck, runner: runner, config: Self.config(deck), catalog: catalog)
        wireQueue()
    }

    static func config(_ deck: DeckProfile) -> SSHConfig {
        SSHConfig(host: deck.host, port: deck.port, user: deck.user, identityFile: deck.identityFile ?? Paths.key, knownHostsFile: Paths.knownHosts)
    }

    private func makeLive(_ deck: DeckProfile) -> LiveDeck {
        let config = Self.config(deck)
        let live = LiveDeck(profile: deck, runner: Launch.wrap(SSHRunner(config: config)), config: config, catalog: catalog)
        live.hasPassword = Keychain.password(for: deck.id.uuidString) != nil
        live.onThemeDisabled = { [weak self] _ in
            self?.toast = Toast(title: String(localized: "Quiet Theme turned off"),
                                detail: String(localized: "The theme doesn't match this Steam client. Update QuietDeck, then apply it again."), isError: true)
        }
        return live
    }

    var current: LiveDeck? { selectedDeckID.flatMap { live[$0] } }

    func add(_ deck: DeckProfile) {
        decks.removeAll { $0.host == deck.host && $0.port == deck.port }
        decks.append(deck)
        save()
        live[deck.id] = makeLive(deck)
        selectedDeckID = deck.id
        settings.onboarded = true
        Task { await live[deck.id]?.refresh() }
    }

    func remove(_ deck: DeckProfile) {
        decks.removeAll { $0.id == deck.id }
        live[deck.id] = nil
        Keychain.remove(for: deck.id.uuidString)
        if selectedDeckID == deck.id { selectedDeckID = decks.first?.id }
        save()
    }

    private func save() { UserDefaults.standard.set(try? JSONEncoder().encode(decks), forKey: "decks") }

    func start() {
        Task {
            while !Task.isCancelled {
                for deck in live.values {
                    await deck.refresh()
                    fillArtwork(deck)
                }
                for id in live.keys where live[id]?.connection == .online { queue.resume(deckID: id) }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// Login no servidor, só o token no Keychain, e já grava nos emuladores do Deck.
    func signInRetroAchievements(username: String, password: String) async throws {
        let account = try await RetroAchievements.login(username: username, password: password)
        let data = try JSONEncoder().encode(account)
        Keychain.set(String(decoding: data, as: UTF8.self), for: Self.retroAchievementsAccount)
        enqueue(String(localized: "Turn on achievements"), .applyAchievements(signedIn: true))
    }

    func signOutRetroAchievements() {
        Keychain.remove(for: Self.retroAchievementsAccount)
        enqueue(String(localized: "Turn off achievements"), .applyAchievements(signedIn: false))
    }

    /// Uma vez por abertura do app: atalhos de emulador criados antes da arte automática (ou com ela apagada)
    /// ganham a que falta. Só imagens; o job não toca no Steam nem nos emuladores.
    @ObservationIgnored private var artworkChecked = Set<UUID>()

    private func fillArtwork(_ deck: LiveDeck) {
        guard deck.connection == .online, !artworkChecked.contains(deck.id), let user = deck.steamUsers.first, !deck.games.isEmpty else { return }
        artworkChecked.insert(deck.id)
        let shortcuts = Set(deck.shortcutsPlayed.keys)
        var seen = Set<String>()
        let games = deck.games.compactMap { game -> (String, GameSystem)? in
            let title = ROMPlan.displayName(game.name)
            guard shortcuts.contains(title) || shortcuts.contains(ROMPlan.shortcutName(title)), seen.insert(title).inserted,
                  let system = catalog.system(game.systemID) else { return nil }
            return (title, system)
        }
        Task {
            var items: [ArtItem] = []
            for (title, system) in games {
                for (kind, file) in await ArtMaker.prepare(title: title, system: system) {
                    items.append(ArtItem(names: [ROMPlan.shortcutName(title), title], kind: kind, file: file))
                }
            }
            // Arte antes da limpeza: se a limpeza reiniciar o Steam, as capas já aparecem.
            if !items.isEmpty {
                queue.enqueue(Job(deckID: deck.id, title: String(localized: "Artwork for emulator games"), action: .applyArtwork(user: user, items: items)))
            }
            queue.enqueue(Job(deckID: deck.id, title: String(localized: "Tidy up game shortcuts"), action: .tidyShortcuts(user: user)))
        }
    }

    /// Prepara a arte de cada jogo e só então enfileira: a capa precisa chegar antes de o Steam reiniciar.
    func addToSteam(_ refs: [GameRef], user: String, sdMount: String?) {
        Task {
            var games: [GameRef] = []
            for var ref in refs {
                if let system = catalog.system(ref.systemID) { ref.art = await ArtMaker.prepare(title: ref.title, system: system) }
                games.append(ref)
            }
            enqueue(String(localized: "Add to Steam"), .addToSteam(user: user, games: games, sdMount: sdMount))
        }
    }

    func enqueue(_ title: String, _ action: JobAction) {
        guard let id = selectedDeckID else { return }
        queue.enqueue(Job(deckID: id, title: title, action: action))
    }

    /// Arquivos soltos que batem com a tabela de BIOS vão direto para `bios/`; o resto segue como ROM.
    func importBIOS(_ files: [String]) {
        for path in files {
            let name = (path as NSString).lastPathComponent
            enqueue(String(localized: "Import \(name)"), .importBIOS(localPath: path, sdMount: nil))
        }
    }

    func importSwitchKeys(_ files: [String]) {
        for path in files {
            do {
                try SwitchKeys.install(from: URL(fileURLWithPath: path))
                toast = Toast(title: String(localized: "Switch keys imported"), detail: String(localized: "Compressed Switch games can now be sent."), isError: false)
                // Substitui também a do Ryubing: chaves velhas no Deck não abrem jogo de firmware novo.
                enqueue(String(localized: "Send Switch keys"), .sendSwitchKeys)
            } catch {
                toast = Toast(title: String(localized: "Couldn't import the keys"), detail: describe(error), isError: true)
            }
        }
    }

    func installSwitchMods(_ paths: [String]) {
        for path in paths {
            let name = (path as NSString).lastPathComponent
            enqueue(String(localized: "Install \(name)"), .installSwitchMod(localPath: path))
        }
    }

    func installPS3Firmware(_ paths: [String]) {
        for path in paths { enqueue(String(localized: "Install PS3 firmware"), .installPS3Firmware(localPath: path)) }
    }

    func installSwitchFirmware(_ paths: [String]) {
        for path in paths {
            enqueue(String(localized: "Install Switch firmware"), .installSwitchFirmware(localPath: path))
        }
    }

    private func context(_ id: UUID) -> JobContext? {
        guard let deck = live[id] else { return nil }
        return JobContext(runner: deck.runner, config: deck.config, catalog: catalog, password: Keychain.password(for: id.uuidString),
                          workRoot: Paths.work, shelfClient: { ShelfStore.client($0) },
                          achievements: Keychain.decoded(RetroAchievementsAccount.self, for: Self.retroAchievementsAccount)) {
            Keychain.remove(for: id.uuidString)
        }
    }
}

/// Espelho de um Deck. `refresh` lê tudo de novo: nada aqui decide uma operação, só alimenta a tela.
@MainActor @Observable
final class LiveDeck: Identifiable {
    enum Connection: Equatable { case connecting, online, failed(String) }

    let profile: DeckProfile
    let runner: any CommandRunner
    let config: SSHConfig
    let catalog: Catalog
    nonisolated var id: UUID { profile.id }

    var connection = Connection.connecting
    var status = DeviceStatus()
    var flatpaks: [InstalledFlatpak] = []
    var updates: [String: String] = [:]
    /// Versão ativa e anterior de cada emulador em AppImage.
    var appImages: [String: AppImages.Status] = [:]
    /// Pasta pessoal no Deck: o atalho de um AppImage tem o caminho completo.
    var home: String?
    var paths: EmulationPaths?
    var bios: [String: BIOSStatus] = [:]
    var games: [Library.Game] = []
    var decky: DeckyState?
    var plugins: [InstalledPlugin] = []
    var compatTools: [String] = []
    /// O que a Estante instalou, conferido no Deck a cada leitura.
    var shelfInstalled: [String: ShelfManifestEntry] = [:]
    var shortcutsPlayed: [String: Int64] = [:]
    var steamUsers: [String] = []
    var hasPassword = false
    var themeInstalled = false
    var hasQuietGlass = false
    var themeHealth: ThemeHealth?
    /// Avisa quando o tema acaba de ser desligado por um cliente novo.
    var onThemeDisabled: ((ThemeHealth) -> Void)?
    private var refreshing = false
    /// Pedido que chegou durante uma leitura: refaz ao terminar, senão o jogo recém-enviado
    /// só aparecia no próximo ciclo.
    private var refreshAgain = false

    init(profile: DeckProfile, runner: any CommandRunner, config: SSHConfig, catalog: Catalog) {
        self.profile = profile
        self.runner = runner
        self.config = config
        self.catalog = catalog
    }

    var updateCount: Int { updates.keys.filter { id in flatpaks.contains { $0.appID == id } }.count }
    var sdMount: String? { status.sdCard?.mountPoint }

    func refresh() async {
        guard !refreshing else { refreshAgain = true; return }
        refreshing = true
        defer {
            refreshing = false
            if refreshAgain {
                refreshAgain = false
                Task { await refresh() }
            }
        }
        do {
            status = try await DeviceProbe.read(runner)
            connection = .online
        } catch {
            connection = .failed(String(describing: error))
            return
        }
        let r = runner
        flatpaks = (try? await Flatpaks.installed(r)) ?? flatpaks
        home = (try? await RemoteFiles(runner: r).home()) ?? home
        for e in catalog.emulators where e.appImage != nil {
            if let s = try? await AppImages.status(e, runner: r) { appImages[e.id] = s }
        }
        updates = Flatpaks.parseUpdates((try? await r.run(Flatpaks.updates).stdout) ?? "")
        steamUsers = (try? await SteamControl(runner: r).users()) ?? steamUsers
        if let p = try? await Emulation.paths(r) {
            paths = p
            let scan = (try? await r.run(BIOS.scan(paths: p)).stdout) ?? ""
            bios = DeckRemote.BIOS.status(scanOutput: scan, table: catalog.bios.entries)
            var locations = [p]
            if !p.isEmuDeck, let sd = sdMount { locations.append(EmulationPaths(root: sd + "/Emulation")) }
            var found: [Library.Game] = []
            for location in locations {
                found += Library.parse((try? await r.run(Library.listing(paths: location)).stdout) ?? "", systems: catalog.systems, paths: location)
            }
            games = found
        }
        shelfInstalled = (try? await ShelfInstaller.installed(r)) ?? shelfInstalled
        if let user = steamUsers.first { shortcutsPlayed = (try? await SteamControl(runner: r).lastPlayed(user: user)) ?? shortcutsPlayed }
        decky = try? await Decky.state(r)
        plugins = (try? await Decky.plugins(r)) ?? plugins
        compatTools = (try? await CompatTools.installed(r)) ?? compatTools
        themeInstalled = (try? await QuietTheme.isInstalled(r)) ?? false
        hasQuietGlass = (try? await QuietTheme.hasGlass(r)) ?? false
        let wasHealthy = themeHealth?.isHealthy ?? true
        themeHealth = try? await QuietTheme.disableIfBroken(r)
        if wasHealthy, let health = themeHealth, !health.isHealthy { onThemeDisabled?(health) }
    }
}

/// Flags de linha de comando. `--record <pasta>` grava os comandos num Deck real em fixtures JSON.
enum Launch {
    static func value(after flag: String) -> String? {
        CommandLine.arguments.firstIndex(of: flag).flatMap { CommandLine.arguments.dropFirst($0 + 1).first }
    }

    static func wrap(_ runner: any CommandRunner) -> any CommandRunner {
        guard let dir = value(after: "--record") else { return runner }
        let stamp = Int(Date().timeIntervalSince1970)
        let url = URL(fileURLWithPath: dir).appending(path: "recording-\(stamp)-\(UUID().uuidString.prefix(4)).json")
        return RecordingRunner(base: runner, recorder: CommandRecorder(url: url, source: "steamos-real"))
    }
}
