import Foundation
import Testing
import DeckKit
@testable import DeckRemote

/// Protocolos reais: `make integration` sobe WebDAV e S3 (rclone) e um RomM com MariaDB.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["QUIETDECK_TEST_SOURCES"] != nil))
struct IntegrationSourceTests {
    static let token = ProcessInfo.processInfo.environment["QUIETDECK_TEST_ROMM_TOKEN"] ?? ""
    let webdav = LibrarySource(name: "WebDAV", priority: 0, kind: .webdav(url: "http://127.0.0.1:8767"))
    let s3 = LibrarySource(name: "S3", priority: 1, kind: .s3(endpoint: "http://127.0.0.1:8768", region: "us-east-1", bucket: "acervo", prefix: "", accessKey: "acervo"))
    let romm = LibrarySource(name: "RomM", priority: 2, kind: .romm(url: "http://127.0.0.1:8769"))

    func client(_ s: LibrarySource, _ secret: SourceSecret? = nil) -> SourceClient {
        SourceClient(source: s, secret: secret ?? SourceSecret(user: "acervo", password: "acervo-password", token: Self.token), sshKey: "", knownHosts: "")
    }
    func catalog() throws -> Catalog { try Catalog.load() }

    @Test func statusSeparatesWrongCredentialsFromOffline() async throws {
        for source in [webdav, s3, romm] {
            #expect(await client(source).probe() == .online, "\(source.name)")
            #expect(await client(source, SourceSecret(user: "x", password: "errada", token: "rmm_errado")).probe() == .badCredentials, "\(source.name)")
        }
        let off = LibrarySource(name: "Fora", priority: 0, kind: .webdav(url: "http://127.0.0.1:9"))
        #expect(await client(off).probe() == .offline)
    }

    @Test(arguments: ["webdav", "s3"]) func scansAndDownloadsWithoutHashing(_ kind: String) async throws {
        let source = kind == "s3" ? s3 : webdav
        let c = client(source), systems = try catalog().systems
        let records = try await c.scan(systems: systems, cache: [:])
        #expect(records.allSatisfy { $0.sha1.isEmpty })
        let items = ShelfIndex.build([(source, records)], systems: systems, dats: DatIndex()).items
        #expect(Set(items.map(\.title)).isSuperset(of: ["Alpha", "Beta", "Gamma"]))
        // Mesmo nome e tamanho, em pastas diferentes da mesma fonte, é um jogo só.
        let alpha = try #require(items.first { $0.title == "Alpha" })
        #expect(alpha.duplicates.count == 1)
        let dir = Sim.dir.appendingPathComponent("dl-\(kind)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = try await c.download(alpha.origins[0], to: dir)
        #expect((try FileManager.default.attributesOfItem(atPath: path))[.size] as? Int == 8192)
    }

    @Test func rommBringsItsOwnOrganizationAndHashes() async throws {
        let c = client(romm), systems = try catalog().systems
        let records = try await c.scan(systems: systems, cache: [:])
        let items = ShelfIndex.build([(romm, records)], systems: systems, dats: DatIndex()).items
        let delta = try #require(items.first { $0.title == "Delta" })
        #expect(delta.systemID == "gba" && delta.id.count == 40 && delta.cover == nil)
        let dir = Sim.dir.appendingPathComponent("dl-romm")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = try await c.download(delta.origins[0], to: dir)
        #expect(try await LocalHash.compute(path, algorithm: 1) == delta.id)
    }

    /// O jogo existe em duas fontes; instala pela de maior prioridade, e a outra fica de reserva.
    @Test func samePathInTwoSourcesMergesByPriority() async throws {
        let systems = try catalog().systems
        let a = try await client(webdav).scan(systems: systems, cache: [:])
        let b = try await client(s3).scan(systems: systems, cache: [:])
        let items = ShelfIndex.build([(s3, b), (webdav, a)], systems: systems, dats: DatIndex()).items
        let beta = try #require(items.first { $0.title == "Beta" })
        #expect(beta.origins.map(\.sourceID) == [webdav.id, s3.id])
    }

    @Test func folderMapCoversCollectionsOutsideTheExpectedLayout() throws {
        var source = webdav
        source.folderMap = ["consoles/portatil": "gba"]
        let r = ScanRecord(path: "/consoles/portatil/jogo.bin", size: 10, mtime: 0, crc: "", sha1: "")
        let unmapped = ShelfIndex.build([(webdav, [r])], systems: try catalog().systems, dats: DatIndex())
        let mapped = ShelfIndex.build([(source, [r])], systems: try catalog().systems, dats: DatIndex())
        #expect(unmapped.items.isEmpty && unmapped.undecided.count == 1)
        #expect(mapped.items.first?.systemID == "gba")
    }
}
