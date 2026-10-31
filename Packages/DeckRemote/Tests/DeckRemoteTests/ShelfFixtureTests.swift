import Foundation
import Testing
import DeckKit
@testable import DeckRemote

/// Homebrew real do 240p Test Suite, baixado por `scripts/fetch-fixtures.sh`.
enum Fixtures {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/fixtures")
    static let available = FileManager.default.fileExists(atPath: root.appendingPathComponent("240pee.nes").path)
    static func file(_ name: String) -> URL { root.appendingPathComponent(name) }
}

@Suite(.enabled(if: Fixtures.available)) struct ShelfFixtureTests {
    func acervo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qd-shelf-\(UUID().uuidString)")
        let fm = FileManager.default
        for folder in ["nes", "backup/nes", "soltos"] {
            try fm.createDirectory(at: dir.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try fm.copyItem(at: Fixtures.file("240pee.nes"), to: dir.appendingPathComponent("nes/240pee.nes"))
        try fm.copyItem(at: Fixtures.file("240pee.nes"), to: dir.appendingPathComponent("backup/nes/copia.nes"))
        try fm.copyItem(at: Fixtures.file("gb240p.gb"), to: dir.appendingPathComponent("soltos/gb240p.gb"))
        try fm.copyItem(at: Fixtures.file("240pee_mb.gba"), to: dir.appendingPathComponent("soltos/mb.gba"))
        return dir
    }

    @Test func indexesDetectsAndDeduplicates() async throws {
        let dir = try acervo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let catalog = try Catalog.load()
        let records = try await ShelfScanner.scanFolder(dir, systems: catalog.systems, cache: [:])
        let result = ShelfIndex.build(records, systems: catalog.systems, dats: DatIndex())
        // O 144p é dual-mode (0x143 = 0x80): roda em cor, apesar do `.gb`. A pasta `soltos` não diz nada.
        #expect(Set(result.items.map(\.systemID)) == ["nes", "gbc", "gba"])
        #expect(result.items.first { $0.systemID == "nes" }?.duplicates.count == 1)
        #expect(result.undecided.isEmpty)
        // Hash conferido contra um cálculo independente.
        let crc = try await LocalProcess.run("/usr/bin/python3", ["-I", "-c", "import sys,zlib;print('%08x'%zlib.crc32(open(sys.argv[1],'rb').read()))", Fixtures.file("gb240p.gb").path])
        #expect(result.items.first { $0.systemID == "gbc" }?.crc == crc.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test func incrementalScanSkipsUnchangedFiles() async throws {
        let dir = try acervo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let systems = try Catalog.load().systems
        var cache = ShelfScanner.cache(try await ShelfScanner.scanFolder(dir, systems: systems, cache: [:]))
        // O macOS devolve `/private/var`: a chave vem da própria varredura.
        let path = try #require(cache.keys.first { $0.hasSuffix("/nes/240pee.nes") })
        cache[path]?.crc = "cached00"
        let again = try await ShelfScanner.scanFolder(dir, systems: systems, cache: cache)
        #expect(again.first { $0.path == path }?.crc == "cached00")
    }

    /// DAT que lista só a ROM crua: o arquivo tem cabeçalho iNES de 16 bytes.
    @Test func headerlessDatMatchesNes() async throws {
        let dir = try acervo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let catalog = try Catalog.load()
        let records = try await ShelfScanner.scanFolder(dir, systems: catalog.systems, cache: [:])
        let nes = try #require(records.first { $0.path.hasSuffix("nes/240pee.nes") })
        let raw = try await LocalProcess.run("/usr/bin/python3", ["-I", "-c", "import sys,hashlib;print(hashlib.sha1(open(sys.argv[1],'rb').read()[16:]).hexdigest())", Fixtures.file("240pee.nes").path])
        #expect(nes.headerless == raw.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        var dats = DatIndex()
        dats.add(game: "240p Test Suite (World)", sha1: nes.headerless, crc: nil, size: nes.size - 16)
        let item = ShelfIndex.build(records, systems: catalog.systems, dats: dats).items.first { $0.systemID == "nes" }
        #expect(item?.title == "240p Test Suite (World)" && item?.verified == true)
    }
}

@Suite struct ShelfMetadataTests {
    @Test func screenScraperPicksRegionAndNeverKeepsUrls() throws {
        let json = #"""
        {"response":{"jeu":{"noms":[{"region":"jp","text":"Sonikku"},{"region":"us","text":"Sonic"}],
        "developpeur":{"id":"2","text":"Sega"},"joueurs":{"text":"1-2"},
        "synopsis":[{"langue":"fr","text":"Bonjour"},{"langue":"en","text":"Hello"}],
        "dates":[{"region":"us","text":"1991-07-13"}],
        "genres":[{"id":"1","noms":[{"langue":"en","text":"Platform"}]}],
        "medias":[{"type":"box-2D","url":"https://x/jp.png?ssid=u&sspassword=p","region":"jp"},{"type":"box-2D","url":"https://x/us.png?ssid=u&sspassword=p","region":"us"},{"type":"ss","url":"https://x/s.png","region":"us"}]}}}
        """#
        let r = try #require(ScreenScraper.parse(Data(json.utf8), language: "en"))
        #expect(r.meta.title == "Sonic" && r.meta.summary == "Hello" && r.meta.year == 1991)
        #expect(r.meta.developer == "Sega" && r.meta.players == "1-2" && r.meta.genres == ["Platform"])
        #expect(r.cover?.path == "/us.png" && r.hero == nil)
        let stored = String(decoding: try JSONEncoder().encode(r.meta), as: UTF8.self)
        #expect(!stored.contains("sspassword"))
    }

    @Test func screenScraperErrorPageIsNotAGame() {
        #expect(ScreenScraper.parse(Data("Erreur : jeu non trouvée !".utf8), language: nil) == nil)
    }

    @Test func igdbParsesAndEscapesTheSearch() throws {
        let json = #"[{"name":"Sonic","summary":"Fast","first_release_date":677376000,"involved_companies":[{"company":{"name":"Pub"},"developer":false},{"company":{"name":"Sonic Team"},"developer":true}],"genres":[{"name":"Platform"}],"cover":{"image_id":"co1"},"artworks":[{"image_id":"ar1"}],"game_modes":[{"name":"Single player"}]}]"#
        let r = try #require(IGDB.parse(Data(json.utf8)))
        #expect(r.meta.developer == "Sonic Team" && r.meta.year == 1991 && r.meta.players == "Single player")
        #expect(r.cover?.absoluteString == "https://images.igdb.com/igdb/image/upload/t_cover_big_2x/co1.jpg")
        #expect(r.hero?.absoluteString == "https://images.igdb.com/igdb/image/upload/t_1080p/ar1.jpg")
        let q = IGDB.query(title: "A\"; fields *", systemID: "genesis")
        #expect(q.hasPrefix("search \"A; fields *\";") && q.contains("where platforms = (29);"))
    }
}
