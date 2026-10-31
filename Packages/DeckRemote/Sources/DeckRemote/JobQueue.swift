import Foundation
import DeckKit
import Observation

/// O que a fila sabe fazer. É `Codable` para sobreviver ao fechamento do app e poder repetir depois.
/// Jogo por sistema e título. O caminho é procurado no Deck quando o trabalho roda, não na hora do pedido.
public struct GameRef: Codable, Hashable, Sendable {
    public var systemID: String
    public var title: String

    public init(systemID: String, title: String) {
        self.systemID = systemID
        self.title = title
    }
}

public enum JobAction: Codable, Hashable, Sendable {
    case upload(localPath: String, remoteDirectory: String)
    case installEmulator(appID: String)
    case updateEmulator(appID: String)
    case removeEmulator(appID: String)
    case prepareEmulation(sdMount: String?)
    case configureEmulator(id: String, overwrite: Bool, sdMount: String?)
    case addToSteam(user: String, games: [GameRef], sdMount: String?)
    case applyArt(user: String, appID: UInt32, kind: ArtKind, url: String)
    case installDecky
    case installPlugin(name: String, version: StorePlugin.Version)
    case removePlugin(name: String)
    case installCompatTool(archive: GitHubAsset, checksum: GitHubAsset?, folderName: String)
    case removeCompatTool(name: String)
    case backupSaves(localPath: String)
    case restoreSaves(localPath: String)
    case importBIOS(localPath: String, sdMount: String?)
    case quickAction(QuickAction)
    case installQuietHome
    case applyQuietGlass
    case removeQuietGlass
    case shelfInstall(item: ShelfItem, source: ShelfSource, sdMount: String?)
    case shelfRemove(item: ShelfItem, user: String?)
    case freeInstall(game: FreeGame, sdMount: String?)
    /// Arte já baixada no Mac: a URL do ScreenScraper tem credenciais e não pode ir ao Deck nem à fila.
    case applyArtFile(user: String, appID: UInt32, kind: ArtKind, localPath: String)
    case applyTheme(user: String, model: String?)
    case restoreTheme(user: String)
    case importROM(localPath: String, systemID: String, sdMount: String?)
}

public struct Job: Codable, Identifiable, Hashable, Sendable {
    public enum State: Codable, Hashable, Sendable {
        case queued, running, succeeded
        case failed(String)
        case cancelled
        /// Estava rodando quando o app fechou. Não recomeça sozinho: pode haver um jogo aberto.
        case interrupted
    }

    public var id = UUID()
    public var deckID: UUID
    public var title: String
    public var action: JobAction
    public var state: State = .queued
    public var percent: Int?
    public var detail: String?

    public init(deckID: UUID, title: String, action: JobAction) {
        self.deckID = deckID
        self.title = title
        self.action = action
    }

    public var isFinished: Bool {
        switch state {
        case .queued, .running: false
        default: true
        }
    }

    public var canRetry: Bool {
        switch state {
        case .failed, .cancelled, .interrupted: true
        default: false
        }
    }
}

/// Um trabalho por vez em cada Deck; Decks diferentes andam em paralelo. A UI só observa.
@MainActor @Observable
public final class JobQueue {
    public typealias Progress = @Sendable (Int?, String?) -> Void
    public typealias Executor = @Sendable (Job, @escaping Progress) async throws -> Void

    public private(set) var jobs: [Job] = []
    private let storeURL: URL?
    private let executor: Executor
    /// Traduz erros e avisa a UI ao terminar; o pacote não conhece textos da interface.
    @ObservationIgnored public var describe: (Error) -> String = { String(describing: $0) }
    @ObservationIgnored public var onFinish: ((Job) -> Void)?
    @ObservationIgnored private var workers: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var running: [UUID: Task<Void, Error>] = [:]

    public init(storeURL: URL?, executor: @escaping Executor) {
        self.storeURL = storeURL
        self.executor = executor
        guard let storeURL, let data = try? Data(contentsOf: storeURL),
              let saved = try? JSONDecoder().decode([Job].self, from: data) else { return }
        jobs = saved.map {
            var job = $0
            if job.state == .running { job.state = .interrupted; job.percent = nil }
            return job
        }
    }

    public var activeCount: Int { jobs.filter { !$0.isFinished }.count }

    @discardableResult
    public func enqueue(_ job: Job) -> UUID {
        // Duas instalações iguais na fila seriam dois cliques impacientes, não dois pedidos.
        if let same = jobs.first(where: { $0.action == job.action && $0.deckID == job.deckID && !$0.isFinished }) { return same.id }
        jobs.append(job)
        save()
        startWorker(job.deckID)
        return job.id
    }

    public func cancel(_ id: UUID) {
        guard let i = index(id) else { return }
        switch jobs[i].state {
        case .queued:
            jobs[i].state = .cancelled
            save()
        case .running: running[id]?.cancel()
        default: break
        }
    }

    public func retry(_ id: UUID) {
        guard let i = index(id), jobs[i].canRetry else { return }
        jobs[i].state = .queued
        jobs[i].percent = nil
        jobs[i].detail = nil
        save()
        startWorker(jobs[i].deckID)
    }

    /// Depois de reabrir o app: retoma o que estava só na fila quando o Deck responde.
    public func resume(deckID: UUID) {
        if nextJob(deckID) != nil { startWorker(deckID) }
    }

    public func clearFinished() {
        jobs.removeAll { $0.state == .succeeded || $0.state == .cancelled }
        save()
    }

    /// Para testes e para a tela esperar uma operação que ela mesma pediu.
    public func waitUntilIdle() async {
        while let worker = workers.values.first { await worker.value }
    }

    private func index(_ id: UUID) -> Int? { jobs.firstIndex { $0.id == id } }

    private func startWorker(_ deckID: UUID) {
        guard workers[deckID] == nil else { return }
        workers[deckID] = Task { [weak self] in
            while let self, let next = self.nextJob(deckID) { await self.execute(next) }
            self?.workers[deckID] = nil
        }
    }

    private func nextJob(_ deckID: UUID) -> Job? {
        jobs.first { $0.deckID == deckID && $0.state == .queued }
    }

    private func execute(_ job: Job) async {
        update(job.id) { $0.state = .running }
        let executor = self.executor
        let task = Task.detached {
            try await executor(job) { percent, detail in
                Task { @MainActor [weak self] in
                    self?.update(job.id, persist: false) {
                        guard $0.state == .running else { return }
                        if let percent { $0.percent = percent }
                        if let detail { $0.detail = detail }
                    }
                }
            }
        }
        running[job.id] = task
        let outcome = await task.result
        running[job.id] = nil
        defer { if let finished = jobs.first(where: { $0.id == job.id }) { onFinish?(finished) } }
        update(job.id) {
            switch outcome {
            case .success:
                $0.state = .succeeded
                $0.percent = 100
            case .failure(is CancellationError):
                $0.state = .cancelled
            case let .failure(error):
                $0.state = task.isCancelled ? .cancelled : .failed(self.describe(error))
            }
        }
    }

    private func update(_ id: UUID, persist: Bool = true, _ change: (inout Job) -> Void) {
        guard let i = index(id) else { return }
        change(&jobs[i])
        if persist { save() }
    }

    private func save() {
        guard let storeURL, let data = try? JSONEncoder().encode(jobs) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
