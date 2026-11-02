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

@Suite struct ShortcutNameTests {
    @Test func namesAreCleanedForTheHome() {
        #expect(ROMPlan.shortcutName("Resident Evil 0 (Russian Voice+Text mod.)") == "Resident Evil 0")
        #expect(ROMPlan.shortcutName("Legend of Zelda, The - The Wind Waker (USA)") == "The Legend of Zelda - The Wind Waker")
        #expect(ROMPlan.shortcutName("Chrono Trigger (USA) (CT PT-BR)") == "Chrono Trigger (CT PT-BR)")
        #expect(ROMPlan.shortcutName("Super Metroid (Tradução PT-BR)") == "Super Metroid")
        #expect(ROMPlan.shortcutName("Bloodborne [CUSA00900]") == "Bloodborne")
        #expect(ROMPlan.shortcutName("(mod)") == "(mod)")
    }

    @Test func renameKeepsTheAppID() throws {
        let game = Shortcut(name: "Resident Evil 0 (Russian Voice+Text mod.)", exe: "/usr/bin/flatpak", startDir: "/usr/bin",
                            launchOptions: "run io.github.ryubing.Ryujinx \"/home/deck/Emulation/roms/switch/RE0.nsp\"")
        let root = try ShortcutsFile.merge([game], into: ShortcutsFile.emptyFile).root
        let renamed = ShortcutsFile.rename(["Resident Evil 0 (Russian Voice+Text mod.)": "Resident Evil 0"], in: root)
        #expect(renamed.renamed == 1)
        let after = try #require(ShortcutsFile.existing(in: renamed.root).first)
        #expect(after.name == "Resident Evil 0" && after.appID == game.appID)
        #expect(after.isEmulatorGame && after.romPath == "/home/deck/Emulation/roms/switch/RE0.nsp")
    }
}

@Suite struct TidyTests {
    func s(_ name: String, _ rom: String?) -> ShortcutsFile.Existing {
        ShortcutsFile.Existing(appID: 1, name: name, exe: rom == nil ? "\"/usr/bin/steam\"" : "\"/usr/bin/flatpak\"",
                               launchOptions: rom.map { "run x \"/home/deck/Emulation/roms/\($0)\"" } ?? "")
    }

    @Test func removesBrokenAndCleansTheRest() {
        let list = [s("Resident Evil 0", "switch/.quietdeck-partial/RE0.nsp"),
                    s("Resident Evil 0 (Russian Voice+Text mod.)", "switch/RE0 Voice.nsp"),
                    s("Legend of Zelda, The - The Wind Waker (USA)", "gc/ww.iso"),
                    s("Mario (USA)", "snes/Mario (USA).sfc"), s("Mario (Europe)", "snes/Mario (Europe).sfc"),
                    s("Some Game (Beta)", nil)]
        let plan = ShortcutsFile.tidyPlan(list, missing: ["/home/deck/Emulation/roms/switch/.quietdeck-partial/RE0.nsp"])
        #expect(plan.remove == ["Resident Evil 0"])
        #expect(plan.rename == ["Resident Evil 0 (Russian Voice+Text mod.)": "Resident Evil 0",
                                "Legend of Zelda, The - The Wind Waker (USA)": "The Legend of Zelda - The Wind Waker"])
    }

    @Test func keepsNamesThatWouldCollide() {
        let list = [s("Resident Evil 0", "switch/RE0.nsp"), s("Resident Evil 0 (Russian Text mod.)", "switch/RE0 T.nsp")]
        #expect(ShortcutsFile.tidyPlan(list, missing: []).rename.isEmpty)
    }
}

@Suite struct MergeByCommandTests {
    @Test func sameGameWithNewNameIsNotDuplicated() throws {
        let old = Shortcut(name: "Legend of Zelda, The (USA)", exe: "/usr/bin/flatpak", startDir: "/usr/bin", launchOptions: "run d \"/r/gc/z.iso\"")
        let root = try ShortcutsFile.merge([old], into: ShortcutsFile.emptyFile).root
        let new = Shortcut(name: "The Legend of Zelda", exe: "/usr/bin/flatpak", startDir: "/usr/bin", launchOptions: "run d \"/r/gc/z.iso\"")
        #expect(try ShortcutsFile.merge([new], into: root).added.isEmpty)
    }
}
