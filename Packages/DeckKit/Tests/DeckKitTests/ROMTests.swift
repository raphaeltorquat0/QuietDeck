import Foundation
import Testing
@testable import DeckKit

@Suite struct ROMTests {
    let catalog = try! Catalog.load()
    var detector: ROMDetector { ROMDetector(systems: catalog.systems) }
    func detect(_ path: String, _ prefix: Data = Data(), size: Int64 = 0) -> ROMDetection {
        detector.detect(path: path, prefix: prefix, size: size)
    }
    func blank(_ n: Int, patch: [(Int, [UInt8])]) -> Data {
        var d = Data(count: n)
        for (o, b) in patch { d.replaceSubrange(o..<(o + b.count), with: b) }
        return d
    }
    func pvd(_ system: String, _ extra: String = "") -> Data {
        var d = blank(0x9000, patch: [(0x8001, Array("CD001".utf8)), (0x8008, Array(system.utf8))])
        d.append(Data(extra.utf8))
        return d
    }

    @Test func uniqueExtensions() {
        #expect(detect("/x/Game.gba") == .system("gba"))
        #expect(detect("/x/Game.z64") == .system("n64"))
        #expect(detect("/x/Game.gdi") == .system("dreamcast"))
        #expect(detect("/x/readme.txt") == .unknown)
        #expect(detect("/x/Game [v0].nsz") == .system("switch"))
        #expect(detect("/x/Game.xcz") == .system("switch"))
    }

    @Test func folderBeatsExtensionWithAliases() {
        #expect(detect("/Volumes/nas/roms/ps1/Game.iso") == .system("psx"))
        #expect(detect("/roms/gamecube/Game.iso") == .system("gc"))
        #expect(detect("/roms/megadrive/Game.bin") == .system("genesis"))
        #expect(detect("/roms/3ds/Game.3ds") == .system("n3ds"))
    }

    @Test func ambiguousAsksInsteadOfGuessing() {
        guard case let .ambiguous(ids) = detect("/x/Game.iso") else { Issue.record("deveria ser ambíguo"); return }
        #expect(ids.contains("psx") && ids.contains("ps2") && ids.contains("gc"))
    }

    @Test func headers() {
        #expect(ROMDetector.header(Data([0x4E, 0x45, 0x53, 0x1A]), size: 16) == "nes")
        #expect(ROMDetector.header(Data([0x80, 0x37, 0x12, 0x40]), size: 16) == "n64")
        #expect(ROMDetector.header(blank(0x200, patch: [(4, [0x24, 0xFF, 0xAE, 0x51, 0x69, 0x9A, 0xA2, 0x21])]), size: 0) == "gba")
        #expect(ROMDetector.header(blank(0x200, patch: [(0x104, [0xCE, 0xED, 0x66, 0x66]), (0x143, [0xC0])]), size: 0) == "gbc")
        #expect(ROMDetector.header(blank(0x200, patch: [(0x104, [0xCE, 0xED, 0x66, 0x66])]), size: 0) == "gb")
        #expect(ROMDetector.header(blank(0x200, patch: [(0x100, Array("SEGA GENESIS".utf8))]), size: 0) == "genesis")
        #expect(ROMDetector.header(blank(0x40, patch: [(0x1C, [0xC2, 0x33, 0x9F, 0x3D])]), size: 0) == "gc")
        #expect(ROMDetector.header(blank(0x40, patch: [(0x18, [0x5D, 0x1C, 0x9E, 0xA3])]), size: 0) == "wii")
        #expect(ROMDetector.header(Data("SEGA SEGAKATANA".utf8), size: 0) == "dreamcast")
        #expect(ROMDetector.header(Data(count: 0x10) + Data("SEGA SEGASATURN".utf8), size: 0) == "saturn")
        #expect(ROMDetector.header(pvd("PSP GAME"), size: 0) == "psp")
        #expect(ROMDetector.header(pvd("PLAYSTATION", "BOOT2 = cdrom0:\\SLUS_200.01;1"), size: 0) == "ps2")
        #expect(ROMDetector.header(pvd("PLAYSTATION", "BOOT = cdrom:\\SLUS_000.01;1"), size: 0) == "psx")
        #expect(ROMDetector.header(pvd("PLAYSTATION"), size: 4_000_000_000) == "ps2")
        #expect(ROMDetector.header(pvd("PLAYSTATION"), size: 600_000_000) == nil)
    }

    @Test func headerResolvesAmbiguousExtension() {
        #expect(detect("/x/Game.iso", pvd("PSP GAME")) == .system("psp"))
    }

    @Test func conversionPlan() {
        let psx = catalog.system("psx")!, ps2 = catalog.system("ps2")!, psp = catalog.system("psp")!, dc = catalog.system("dreamcast")!
        #expect(ROMPlan.conversion(for: psx, fileExtension: "cue", size: 0) == .cd)
        #expect(ROMPlan.conversion(for: psx, fileExtension: "bin", size: 0) == nil)
        #expect(ROMPlan.conversion(for: psx, fileExtension: "chd", size: 0) == nil)
        #expect(ROMPlan.conversion(for: ps2, fileExtension: "iso", size: 4_000_000_000) == .dvd)
        #expect(ROMPlan.conversion(for: ps2, fileExtension: "iso", size: 600_000_000) == .cd)
        #expect(ROMPlan.conversion(for: dc, fileExtension: "gdi", size: 0) == .cd)
        #expect(ROMPlan.conversion(for: psp, fileExtension: "iso", size: 0) == nil)
    }

    @Test func archives() {
        #expect(ROMPlan.mustExtract(system: catalog.system("ps2")!, fileExtension: "zip"))
        #expect(ROMPlan.mustExtract(system: catalog.system("gc")!, fileExtension: "7z"))
        #expect(!ROMPlan.mustExtract(system: catalog.system("snes")!, fileExtension: "zip"))
        #expect(!ROMPlan.mustExtract(system: catalog.system("arcade")!, fileExtension: "zip"))
    }

    @Test func cueAndGdiMembers() {
        #expect(ROMPlan.referencedFiles(cueSheet: "FILE \"Game (Track 1).bin\" BINARY\n  TRACK 01 MODE2/2352\nFILE t2.bin BINARY\n", extension: "cue")
                == ["Game (Track 1).bin", "t2.bin"])
        #expect(ROMPlan.referencedFiles(cueSheet: "3\n1 0 4 2352 track01.bin 0\n2 600 0 2352 \"track 02.raw\" 0\n3 45000 4 2352 track03.bin 0\n", extension: "gdi")
                == ["track01.bin", "track 02.raw", "track03.bin"])
    }

    @Test func switchDumpNames() {
        let base = "Super Mario Galaxy [010099C022B96000][v0] (3.30 GB).nsz"
        #expect(ROMPlan.displayName(base) == "Super Mario Galaxy")
        #expect(ROMPlan.displayName("Game (USA) (Disc 1).chd") == "Game (USA)")
        #expect(!ROMPlan.isSwitchAddon(base))
        #expect(ROMPlan.isSwitchAddon("Super Mario Galaxy [010099C022B96800][v327680] (0.32 GB).nsp"))
        #expect(ROMPlan.isSwitchAddon("Game [0100AAAA00001001][v0].nsp"))
        #expect(!ROMPlan.isSwitchAddon("Game (USA).sfc"))
    }

    @Test func multiDiscPlaylists() {
        let m3u = ROMPlan.playlists(for: ["FF7 (USA) (Disc 2).chd", "FF7 (USA) (Disc 1).chd", "FF7 (USA) (Disc 3).chd", "Solo (Disc 1).chd", "Other.chd"])
        #expect(m3u.count == 1)
        #expect(m3u[0].name == "FF7 (USA).m3u")
        #expect(m3u[0].contents == "FF7 (USA) (Disc 1).chd\nFF7 (USA) (Disc 2).chd\nFF7 (USA) (Disc 3).chd\n")
        #expect(ROMPlan.discInfo("Game CD2.iso")?.number == 2)
        #expect(ROMPlan.discInfo("Game - Disk B.iso")?.number == 2)
        #expect(ROMPlan.discInfo("Discworld.iso") == nil)
        #expect(ROMPlan.displayName("Metal Gear (Disc 1).chd") == "Metal Gear")
    }
}

@Suite struct CatalogTests {
    let catalog = try! Catalog.load()

    @Test func everySystemHasAnEmulatorThatCanRun() {
        for s in catalog.systems {
            let e = catalog.emulator(s.emulator)
            #expect(e?.isAvailable == true, "\(s.id)")
            #expect(e?.launch != nil, "\(s.id)")
            #expect(s.emulator != "retroarch" || s.core != nil, "\(s.id)")
        }
    }

    @Test func folderLayoutMatchesEmuDeck() {
        #expect(catalog.system("n3ds")?.folder == "n3ds")
        #expect(catalog.system("wiiu")?.folder == "wiiu/roms")
    }

    @Test func biosHashesAreWellFormed() {
        #expect(catalog.bios.entries.count >= 88)
        for e in catalog.bios.entries {
            #expect(e.md5.count == 32 && e.sha1.count == 40)
        }
        #expect(catalog.bios.entries.first { $0.file == "scph5501.bin" }?.sha1 == "0555c6fae8906f3f09baf5988f00e55f88e9f30b")
    }

    @Test func removedAppsStayMarkedUnavailable() {
        #expect(catalog.emulator("duckstation")?.isAvailable == false)
    }

    @Test func overrideDirectoryReplacesCatalog() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"[{"id":"x","name":"X","flatpak":"a.b.C","systems":[]}]"#.utf8).write(to: dir.appendingPathComponent("emulators.json"))
        #expect(try Catalog.load(overrideDirectory: dir).emulators.map(\.id) == ["x"])
    }
}
