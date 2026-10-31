import Foundation
import Testing
import DeckKit
@testable import DeckRemote

/// Servidor de acervo de `Harness/shelf` (`make integration`): SSH, SMB e o serviço, com a mesma pasta.
@Suite(.serialized, .enabled(if: Sim.enabled && ProcessInfo.processInfo.environment["QUIETDECK_TEST_SHELF"] != nil))
struct IntegrationShelfTests {
    static let root = "/srv/acervo"
    static let key = Sim.dir.appendingPathComponent("shelf-key").path
    static let serviceURL = "http://127.0.0.1:8766"
    static let token = "test-token"

    static func exec(_ script: String) async throws {
        let r = try await LocalProcess.run("/usr/bin/env", ["docker", "exec", "quietdeck-shelf", "sh", "-c", script])
        #expect(r.ok, "\(r.stderr)")
    }

    static let seeded = Task<Void, Error> {
        try await Pairing.ensureKey(at: key)
        let pub = try String(contentsOfFile: key + ".pub", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        try await exec("printf '%s\\n' \(Shell.quote(pub)) > /home/acervo/.ssh/authorized_keys && chown acervo /home/acervo/.ssh/authorized_keys && chmod 600 /home/acervo/.ssh/authorized_keys")
    }

    var server: SSHConfig {
        SSHConfig(host: "127.0.0.1", port: 2223, user: "acervo", identityFile: Self.key,
                  knownHostsFile: Sim.dir.appendingPathComponent("known hosts").path)
    }
    var source: LibrarySource { LibrarySource(name: "SSH", priority: 0, kind: .ssh(host: "127.0.0.1", user: "acervo", port: 2223, path: Self.root)) }
    var service: LibrarySource { LibrarySource(name: "Serviço", priority: 0, kind: .service(url: Self.serviceURL)) }

    func client(_ s: LibrarySource) -> SourceClient {
        SourceClient(source: s, secret: SourceSecret(user: "acervo", password: "acervo-password", token: Self.token), sshKey: Self.key,
                     knownHosts: Sim.dir.appendingPathComponent("known hosts").path)
    }

    func catalog() throws -> Catalog { try Catalog.load() }

    func items(_ records: [ScanRecord]) throws -> [ShelfItem] {
        ShelfIndex.build(records, systems: try catalog().systems, dats: DatIndex()).items
    }

    func installer(_ r: SSHRunner, service: Bool = false) throws -> ShelfInstaller {
        ShelfInstaller(runner: r, config: Sim.config, catalog: try catalog(), workRoot: Sim.dir.appendingPathComponent("work"),
                       client: { client($0) }, deckServiceURL: service ? "http://quietdeck-shelf:8766" : nil)
    }

    @Test func remoteScanIsIncrementalAndDeduplicates() async throws {
        try await Self.seeded.value
        let runner = SSHRunner(config: server)
        let systems = try catalog().systems
        let first = try await ShelfScanner.scanRemote(runner, root: Self.root, systems: systems, cache: [:])
        let found = try items(first)
        #expect(Set(found.map(\.title)) == ["Alpha", "Beta", "Gamma"])
        #expect(found.first { $0.title == "Alpha" }?.duplicates.count == 1)
        #expect(!first.contains { $0.path.hasSuffix("quebrado.gba") })

        var marked = ShelfScanner.cache(first)
        let alpha = Self.root + "/gba/Alpha.gba"
        marked[alpha]?.crc = "cached00"
        let again = try await ShelfScanner.scanRemote(runner, root: Self.root, systems: systems, cache: marked)
        #expect(again.first { $0.path == alpha }?.crc == "cached00")
    }

    @Test func installsAndRemovesThroughSSH() async throws {
        try await Self.seeded.value
        let deck = try await Sim.runner()
        let records = try await ShelfScanner.scanRemote(SSHRunner(config: server), root: Self.root, systems: try catalog().systems, cache: [:])
        let item = try #require(try items(records).first { $0.title == "Beta" })
        let paths = try await Emulation.paths(deck)
        let install = try installer(deck)

        let files = try await install.install(item, from: source, paths: paths) { _, _ in }
        #expect(try await deck.run("test -f \(Shell.quote(files[0]))").ok)
        let installed = try await ShelfInstaller.installed(deck)
        #expect(installed[item.id]?.files == files)
        // Idempotente: segunda vez não reenvia.
        #expect(try await install.install(item, from: source, paths: paths) { _, _ in } == files)
        // Apagado à mão, o Deck manda.
        try await deck.check("rm -f \(Shell.quote(files[0]))")
        #expect(try await ShelfInstaller.installed(deck)[item.id] == nil)
        _ = try await install.install(item, from: source, paths: paths) { _, _ in }

        try await install.remove(item, user: nil)
        #expect(try await !deck.run("test -e \(Shell.quote(files[0]))").ok)
        #expect(try await ShelfInstaller.manifest(deck)[item.id] == nil)
    }

    @Test func serviceRejectsBadTokenAndEscapes() async throws {
        try await Self.seeded.value
        func code(_ args: String) async throws -> String {
            try await LocalProcess.run("/bin/sh", ["-c", "curl -s -o /dev/null -w '%{http_code}' --path-as-is \(args)"]).stdout
        }
        #expect(try await code("\(Self.serviceURL)/index") == "401")
        #expect(try await code("-H 'Authorization: Bearer errado' \(Self.serviceURL)/index") == "401")
        let auth = "-H 'Authorization: Bearer \(Self.token)'"
        #expect(try await code("\(auth) \(Self.serviceURL)/files/etc/passwd") == "404")
        #expect(try await code("\(auth) \(Self.serviceURL)/files/\(Self.root)/../../etc/passwd") == "404")
        #expect(try await code("\(auth) \(Self.serviceURL)/files\(Self.root)/gba/Beta.gba") == "200")
    }

    @Test func serverSendsDirectlyToTheDeck() async throws {
        try await Self.seeded.value
        let deck = try await Sim.runner()
        let records = try await client(service).scan(systems: try catalog().systems, cache: [:])
        let item = try #require(try items(records).first { $0.title == "Gamma" })
        #expect(ShelfInstaller.canGoDirect(item, system: try #require(try catalog().system("gb"))))
        let install = try installer(deck, service: true)
        let files = try await install.install(item, from: service, paths: try await Emulation.paths(deck)) { _, _ in }
        #expect(try await deck.run("sha1sum \(Shell.quote(files[0]))").stdout.hasPrefix(item.id))
        #expect(try await deck.run("ls \(Shell.quote((files[0] as NSString).deletingLastPathComponent)) | grep -c quietdeck-part").trimmed == "0")
        // O token não pode aparecer na linha de comando do Deck.
        #expect(try await !deck.run("ps -eo args | grep -v grep | grep -q test-token").ok)
        try await install.remove(item, user: nil)
    }

    /// Fonte oficial trocada por `file://`, para o teste rodar sem rede. Inclui zip com cue que vira CHD.
    @Test(.enabled(if: Fixtures.available)) func freeCatalogInstallsVerifiesAndRemoves() async throws {
        try await Self.seeded.value
        let deck = try await Sim.runner()
        let paths = try await Emulation.paths(deck)
        var game = try #require(try catalog().free.first { $0.id == "240p-ps1" })
        game.download = Fixtures.file(game.fileName).absoluteString
        let install = try installer(deck)
        let files = try await install.installFree(game, paths: paths) { _, _ in }
        #expect(files.allSatisfy { $0.contains("/roms/") })
        #expect(try await ShelfInstaller.installed(deck)[game.item.id]?.files == files)
        try await install.remove(game.item, user: nil)
        #expect(try await ShelfInstaller.installed(deck)[game.item.id] == nil)

        var tampered = try #require(try catalog().free.first { $0.id == "144p-gb" })
        tampered.download = Fixtures.file(tampered.fileName).absoluteString
        tampered.sha256 = String(repeating: "0", count: 64)
        await #expect(throws: DeckError.self) { try await install.installFree(tampered, paths: paths) { _, _ in } }
        #expect(try await deck.run("ls \(Shell.quote(paths.roms))/gb 2>/dev/null | grep -c gb240p; true").trimmed == "0")
    }

    /// Compartilhamento montado pelo sistema: `make shelf-mount` ou o passo do CI, em `QUIETDECK_TEST_SMB`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QUIETDECK_TEST_SMB"] != nil))
    func installsFromMountedShare() async throws {
        try await Self.seeded.value
        let mount = try #require(ProcessInfo.processInfo.environment["QUIETDECK_TEST_SMB"])
        let deck = try await Sim.runner()
        let systems = try catalog().systems
        let records = try await ShelfScanner.scanFolder(URL(fileURLWithPath: mount), systems: systems, cache: [:])
        let item = try #require(try items(records).first { $0.title == "Alpha" }, "\(records.map(\.path))")
        let install = try installer(deck)
        let files = try await install.install(item, from: LibrarySource(name: "SMB", priority: 0, kind: .folder(path: mount)), paths: try await Emulation.paths(deck)) { _, _ in }
        #expect(try await deck.run("sha1sum \(Shell.quote(files[0]))").stdout.hasPrefix(item.id))
        try await install.remove(item, user: nil)
    }
}
