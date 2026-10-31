import Foundation
import Testing
@testable import DeckKit

@Suite struct ShelfTests {
    let systems = try! Catalog.load().systems
    func rec(_ path: String, _ sha: String, size: Int64 = 100, crc: String = "aabbccdd", text: String? = nil) -> ScanRecord {
        ScanRecord(path: path, size: size, mtime: 1, crc: crc, sha1: sha, text: text)
    }

    @Test func logiqxAndClrMamePro() {
        var i = DatIndex()
        i.load(Data("""
        <?xml version="1.0"?><datafile><game name="240p Test Suite (World)"><description>x</description>
        <rom name="240p.gba" size="16" crc="AB12CD34" sha1="DEADBEEF"/></game></datafile>
        """.utf8))
        i.load(Data("""
        clrmamepro (
            name "Sample"
        )
        game (
            name "Game Two"
            rom ( name "g.gb" size 32 crc 11223344 md5 aa sha1 cafe )
        )
        """.utf8))
        #expect(i.game(sha1: "deadbeef", crc: "", size: 0) == "240p Test Suite (World)")
        #expect(i.game(sha1: "cafe", crc: "", size: 0) == "Game Two")
        #expect(i.game(sha1: "zz", crc: "ab12cd34", size: 16) == "240p Test Suite (World)")
        #expect(i.game(sha1: "zz", crc: "ab12cd34", size: 99) == nil)
    }

    @Test func copiesMergeAndKeepWhereTheyAre() {
        let r = ShelfIndex.build([rec("/a/gba/One.gba", "s1"), rec("/backup/gba/One copy.gba", "s1"), rec("/a/gba/Two.gba", "s2")], systems: systems, dats: DatIndex())
        #expect(r.items.count == 2)
        #expect(r.items.first { $0.id == "s1" }?.duplicates == ["/backup/gba/One copy.gba"])
    }

    @Test func cueTracksBecomeOneGame() {
        let cue = "FILE \"G (Track 1).bin\" BINARY\nFILE \"G (Track 2).bin\" BINARY\n"
        let r = ShelfIndex.build([rec("/a/psx/G.cue", "c", size: 10, text: cue), rec("/a/psx/G (Track 1).bin", "t1", size: 700), rec("/a/psx/G (Track 2).bin", "t2", size: 50)], systems: systems, dats: DatIndex())
        #expect(r.items.count == 1)
        #expect(r.items[0].id == "t1" && r.items[0].size == 760 && r.items[0].members.count == 2)
        #expect(r.items[0].entry == "/a/psx/G.cue")
    }

    @Test func datTitleWinsAndUnknownSystemIsReported() {
        var d = DatIndex()
        d.add(game: "Título Oficial (USA)", sha1: "s1", crc: nil, size: nil)
        let r = ShelfIndex.build([rec("/a/snes/x.sfc", "s1"), rec("/a/misc/mystery.iso", "s2"), rec("/a/misc/readme.txt", "s3")], systems: systems, dats: d)
        #expect(r.items.first?.title == "Título Oficial (USA)" && r.items.first?.verified == true)
        #expect(r.undecided.map(\.path) == ["/a/misc/mystery.iso"])
    }

    @Test func spaceAdvisorPicksLeastPlayed() {
        let gb: Int64 = 1 << 30
        let games = [SpaceAdvisor.Installed(title: "Novo", size: 10 * gb, lastPlayed: 900), .init(title: "Antigo", size: 3 * gb, lastPlayed: 10), .init(title: "Médio", size: 4 * gb, lastPlayed: 500)]
        #expect(SpaceAdvisor.fits(size: gb, free: 3 * gb))
        #expect(!SpaceAdvisor.fits(size: gb, free: gb + 1))
        #expect(SpaceAdvisor.suggest(size: 5 * gb, free: 2 * gb, installed: games).map(\.title) == ["Antigo", "Médio"])
        #expect(SpaceAdvisor.suggest(size: gb, free: 9 * gb, installed: games).isEmpty)
        #expect(SpaceAdvisor.suggest(size: 100 * gb, free: 0, installed: games).isEmpty)
    }

    /// O serviço roda sem o catálogo do app, então leva a lista junto.
    @Test func serviceFolderListMatchesCatalog() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let listed = try String(contentsOf: root.appendingPathComponent("Service/shelf/folders.txt"), encoding: .utf8)
        let expected: [String] = systems.flatMap { s in ([s.id] + s.aliases).map { $0.lowercased() } }
        let found: [String] = listed.split(separator: "\n").map(String.init)
        #expect(Set(found) == Set(expected))
    }

    @Test func crcInBlocksMatchesWhole() {
        let a = Data("123".utf8), b = Data("456789".utf8)
        #expect(~CRC32.update(CRC32.update(~0, a), b) == 0xCBF43926)
    }
}
