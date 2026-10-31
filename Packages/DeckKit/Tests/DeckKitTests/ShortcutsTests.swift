import Foundation
import Testing
@testable import DeckKit

@Suite struct ShortcutsTests {
    let game = Shortcut(name: "Zelda: Ocarina", exe: "/usr/bin/flatpak", startDir: "/home/deck")

    @Test func crcMatchesKnownVector() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF43926)
    }

    @Test func idFollowsSteamRomManager() {
        // zlib.crc32(b'"/usr/bin/flatpak"Zelda: Ocarina') | 0x80000000
        #expect(game.exe == "\"/usr/bin/flatpak\"")
        #expect(game.appID == 0x8000_0000 | CRC32.checksum(Data("\"/usr/bin/flatpak\"Zelda: Ocarina".utf8)))
        #expect(game.appID & 0x8000_0000 != 0)
    }

    @Test func artFileNames() {
        #expect(ArtKind.portrait.fileName(appID: 123) == "123p.png")
        #expect(ArtKind.wide.fileName(appID: 123) == "123.png")
        #expect(ArtKind.hero.fileName(appID: 123) == "123_hero.png")
        #expect(ArtKind.logo.fileName(appID: 123) == "123_logo.png")
    }

    @Test func mergeIsIdempotentAndKeepsUnknownFields() throws {
        let existing = VDFValue.map([("shortcuts", .map([
            ("3", .map([("appid", .int32(-5)), ("appname", .string("Old")), ("exe", .string("\"/x\"")), ("Futuro", .string("preservar"))])),
        ]))])
        let first = try ShortcutsFile.merge([game], into: existing)
        #expect(first.added == [game])
        let parsed = try VDF.parse(VDF.serialize(first.root))
        #expect(parsed["shortcuts"]?["3"]?["Futuro"] == .string("preservar"))
        #expect(parsed["shortcuts"]?["4"]?["AppName"] == .string(game.name))
        #expect(parsed["shortcuts"]?["4"]?["appid"] == .int32(Int32(bitPattern: game.appID)))
        #expect(ShortcutsFile.existing(in: parsed)[0].appID == UInt32(bitPattern: -5))

        let second = try ShortcutsFile.merge([game], into: parsed)
        #expect(second.added.isEmpty)
        #expect(VDF.serialize(second.root) == VDF.serialize(parsed))
    }

    @Test func emptyAndMissingFile() throws {
        let merged = try ShortcutsFile.merge([game], into: ShortcutsFile.parse(Data()))
        #expect(ShortcutsFile.existing(in: merged.root).count == 1)
    }
}
