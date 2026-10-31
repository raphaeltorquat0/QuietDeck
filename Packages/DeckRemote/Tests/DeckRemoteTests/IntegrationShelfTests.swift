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
    var source: ShelfSource { .ssh(host: "127.0.0.1", user: "acervo", port: 2223, path: Self.root) }

    func catalog() throws -> Catalog { try Catalog.load() }

    func items(_ records: [ScanRecord]) throws -> [ShelfItem] {
        ShelfIndex.build(records, systems: try catalog().systems, dats: DatIndex()).items
    }

    func installer(_ r: SSHRunner, service: Bool = false) throws -> ShelfInstaller {
        ShelfInstaller(runner: r, config: Sim.config, catalog: try catalog(), workRoot: Sim.dir.appendingPathComponent("work"),
                       sshKey: Self.key, token: service ? Self.token : nil, deckServiceURL: service ? "http://quietdeck-shelf:8766" : nil)
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
        let records = try await ShelfScanner.scanService(Self.serviceURL, token: Self.token)
        let item = try #require(try items(records).first { $0.title == "Gamma" })
        #expect(ShelfInstaller.canGoDirect(item, system: try #require(try catalog().system("gb"))))
        let install = try installer(deck, service: true)
        let files = try await install.install(item, from: .service(url: Self.serviceURL), paths: try await Emulation.paths(deck)) { _, _ in }
        #expect(try await deck.run("sha1sum \(Shell.quote(files[0]))").stdout.hasPrefix(item.id))
        #expect(try await deck.run("ls \(Shell.quote((files[0] as NSString).deletingLastPathComponent)) | grep -c quietdeck-part").trimmed == "0")
        // O token não pode aparecer na linha de comando do Deck.
        #expect(try await !deck.run("ps -eo args | grep -v grep | grep -q test-token").ok)
        try await install.remove(item, user: nil)
    }

    /// Compartilhamento montado pelo sistema: `make shelf-mount` ou o passo do CI, em `QUIETDECK_TEST_SMB`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QUIETDECK_TEST_SMB"] != nil))
    func installsFromMountedShare() async throws {
        try await Self.seeded.value
        let mount = try #require(ProcessInfo.processInfo.environment["QUIETDECK_TEST_SMB"])
        let deck = try await Sim.runner()
        let systems = try catalog().systems
        let records = try await ShelfScanner.scanFolder(URL(fileURLWithPath: mount), systems: systems, cache: [:])
        let item = try #require(try items(records).first { $0.title == "Alpha" })
        let install = try installer(deck)
        let files = try await install.install(item, from: .folder(path: mount), paths: try await Emulation.paths(deck)) { _, _ in }
        #expect(try await deck.run("sha1sum \(Shell.quote(files[0]))").stdout.hasPrefix(item.id))
        try await install.remove(item, user: nil)
    }
}
