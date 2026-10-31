import Foundation
import Testing
@testable import DeckKit
@testable import DeckRemote

@Suite struct CommandTests {
    @Test func nothingWritesOutsideHomeOrUsesForbiddenTools() throws {
        let scripts = [Flatpaks.list, Flatpaks.updates, SteamControl.mask, SteamControl.stopUnit,
                       Decky.stateScript, CompatTools.list, Emulation.emuDeckSettings]
        for s in scripts {
            #expect(!s.contains("pacman") && !s.contains("steamos-readonly"))
        }
    }

    @Test func steamUnitIsMaskedOnlyInRuntimeScope() {
        #expect(SteamControl.mask.hasSuffix("mask --runtime steam-launcher.service"))
    }

    @Test func artGoesToTheShortIdName() {
        let s = Art.script(url: "https://cdn2.steamgriddb.com/x/abc.jpg", kind: .hero, appID: 2_500_000_000, gridDirectory: "/g")
        #expect(s.contains("'/g/2500000000_hero.jpg'"))
    }

    @Test func steamGridDBURLs() {
        #expect(SteamGridDB.imagesURL(kind: .portrait, gameID: 7) == "https://www.steamgriddb.com/api/v2/grids/game/7?dimensions=600x900")
        #expect(SteamGridDB.imagesURL(kind: .logo, gameID: 7) == "https://www.steamgriddb.com/api/v2/logos/game/7")
        #expect(SteamGridDB.encode("Zelda/Link's Awakening") == "Zelda%2FLink's%20Awakening")
    }

    @Test func compatAssetsPickArchAndChecksum() {
        let source = CompatToolSource(id: "c", name: "C", repo: "r", assetSuffix: "-x86_64.tar.xz", checksumSuffix: ".sha512sum")
        func a(_ n: String) -> GitHubAsset { GitHubAsset(name: n, browser_download_url: n) }
        let release = GitHubRelease(tag_name: "t", prerelease: false, assets: [
            a("proton-1-x86_64_v3.tar.xz"), a("proton-1-x86_64.tar.xz"), a("proton-1-x86_64_v3.sha512sum"), a("proton-1-x86_64.sha512sum")])
        let picked = CompatTools.assets(in: release, source: source)
        #expect(picked?.archive.name == "proton-1-x86_64.tar.xz")
        #expect(picked?.checksum?.name == "proton-1-x86_64.sha512sum")
    }

    @Test func compatToolNamesCantEscape() {
        for bad in ["", ".", "..", "../x", "a/b"] { #expect(!CompatTools.isSafeName(bad)) }
        #expect(CompatTools.isSafeName("GE-Proton11-11"))
    }

    @Test func shortcutForRetroArchPointsAtCoreAndRom() throws {
        let catalog = try Catalog.load()
        let s = try #require(Library.shortcut(name: "Golden Sun", romPath: "/r/Golden Sun.gba", system: catalog.system("gba")!, catalog: catalog, corePath: "/c/mgba_libretro.so"))
        #expect(s.exe == "\"/usr/bin/flatpak\"")
        #expect(s.launchOptions == "run org.libretro.RetroArch -L \"/c/mgba_libretro.so\" \"/r/Golden Sun.gba\"")
    }
}

@Suite struct ParserTests {
    @Test func flatpakColumnsKeepEmptyVersion() {
        #expect(Flatpaks.parseList("org.a.B\t\tstable\tuser\n")[0] == InstalledFlatpak(appID: "org.a.B", version: "", installation: "user"))
        #expect(Flatpaks.parseUpdates("org.a.B\t2\n") == ["org.a.B": "2"])
    }

    @Test func emuDeckSettingsAreParsedNeverSourced() {
        let text = "#!/bin/bash\nemulationPath=\"/run/media/mmcblk0p1/Emulation\"\nromsPath=$emulationPath/roms\nbiosPath=\"$HOME/x; rm -rf ~\"\n"
        let p = Emulation.parseEmuDeck(text, home: "/home/deck")
        #expect(p?.root == "/run/media/mmcblk0p1/Emulation" && p?.isEmuDeck == true)
        #expect(p?.roms == "/run/media/mmcblk0p1/Emulation/roms")
        #expect(p?.bios == "/home/deck/x; rm -rf ~")
        #expect(p?.saves == "/run/media/mmcblk0p1/Emulation/saves")
        #expect(Emulation.parseEmuDeck("nothing=1", home: "/h") == nil)
    }

    @Test func emuDeckKeepsFlatBios() {
        var p = EmulationPaths(root: "/e")
        p.isEmuDeck = true
        let system = GameSystem(id: "psx", name: "P", folder: "psx", aliases: [], extensions: [], readsArchives: false, emulator: "x")
        #expect(Emulation.directories(p, systems: [system]) == ["/e/roms/psx"])
    }

    @Test func configPatchKeepsTheRestOfTheFile() {
        let e = [ConfigEntry(section: "General", key: "ISOPath0", value: "/r/gc"), ConfigEntry(section: "New", key: "A", value: "1")]
        let out = ConfigPatcher.apply("[General]\nISOPath0 = /old\n; comment\nOther = 2\n[Core]\nX = 1\n", format: "ini", entries: e)
        #expect(out == "[General]\nISOPath0 = /r/gc\n; comment\nOther = 2\n[Core]\nX = 1\n[New]\nA = 1\n")
        #expect(ConfigPatcher.apply(out, format: "ini", entries: e) == out)
    }

    @Test func configFormats() {
        #expect(ConfigPatcher.apply("", format: "cfg", entries: [ConfigEntry(section: nil, key: "system_directory", value: "/b")]) == "system_directory = \"/b\"\n")
        #expect(ConfigPatcher.apply("[sys.files]\n", format: "toml", entries: [ConfigEntry(section: "sys.files", key: "hdd_path", value: "/h")]) == "[sys.files]\nhdd_path = '/h'\n")
    }

    @Test func biosStatus() {
        let t = [BIOSEntry(system: "psx", file: "a.bin", size: 1, md5: "", sha1: "aa"), BIOSEntry(system: "psx", file: "b.bin", size: 1, md5: "", sha1: "bb"),
                 BIOSEntry(system: "gba", file: "g.bin", size: 1, md5: "", sha1: "cc"), BIOSEntry(system: "nds", file: "n.bin", size: 1, md5: "", sha1: "dd")]
        #expect(BIOS.status(scanOutput: "bb  ./renamed.bin\nff  ./g.bin\n", table: t) == ["psx": .ok, "gba": .invalid, "nds": .missing])
        #expect(BIOS.match(sha1: "CC", table: t)?.file == "g.bin")
    }

    @Test func deckyState() {
        #expect(Decky.parseState("installed\nv3.1.5\n\nactive\n") == DeckyState(installed: true, version: "v3.1.5", serviceActive: true))
        #expect(Decky.parseState("\ninactive\n") == DeckyState(installed: false, version: nil, serviceActive: false))
    }

    @Test func storeResponseDecodes() throws {
        let json = #"[{"id":1,"name":"X","author":"a","description":"d","tags":["t"],"versions":[{"name":"1.0","hash":"h"}],"image_url":"u","downloads":1}]"#
        let p = try JSONDecoder().decode([StorePlugin].self, from: Data(json.utf8))
        #expect(StorePlugin.artifactURL(p[0].versions[0]) == "https://cdn.tzatzikiweeb.moe/file/steam-deck-homebrew/versions/h.zip")
    }

    @Test func discSetIsAddedThroughItsPlaylist() {
        func g(_ n: String) -> Library.Game { Library.Game(systemID: "psx", name: n, path: "/r/" + n, size: 1) }
        let games = [g("FF (Disc 1).chd"), g("FF (Disc 2).chd"), g("FF.m3u"), g("Other.chd")]
        #expect(Library.pick(GameRef(systemID: "psx", title: "FF"), in: games)?.name == "FF.m3u")
        #expect(Library.pick(GameRef(systemID: "psx", title: "Other"), in: games)?.name == "Other.chd")
        #expect(Library.pick(GameRef(systemID: "gba", title: "FF"), in: games) == nil)
    }

    @Test func steamUsersSkipAnonymous() {
        #expect(SteamControl.parseUsers("0\n12345\nanonymous\n") == ["12345"])
    }
}

@Suite struct ScannerTests {
    @Test func biosIsRecognizedByHashNotByName() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bios = dir.appendingPathComponent("renamed.dat"), other = dir.appendingPathComponent("same-size.bin")
        try Data("good".utf8).write(to: bios)
        try Data("nope".utf8).write(to: other)
        let sha1 = try await LocalHash.compute(bios.path, algorithm: 1)
        let table = [BIOSEntry(system: "gba", file: "gba_bios.bin", size: 4, md5: "", sha1: sha1)]
        #expect(await ROMScanner.biosFiles([dir], table: table).map { URL(fileURLWithPath: $0).lastPathComponent } == ["renamed.dat"])
    }

    @Test func cueTracksStayWithTheirIndexAndDetectionUsesFolderAndHeader() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let ps1 = root.appendingPathComponent("ps1"), other = root.appendingPathComponent("misc")
        for d in [ps1, other] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try Data(count: 2352).write(to: ps1.appendingPathComponent("Game (Track 1).bin"))
        try "FILE \"Game (Track 1).bin\" BINARY\n".write(to: ps1.appendingPathComponent("Game.cue"), atomically: true, encoding: .utf8)
        try Data([0x4E, 0x45, 0x53, 0x1A]).write(to: other.appendingPathComponent("noext.rom"))
        try Data("x".utf8).write(to: other.appendingPathComponent("notes.txt"))
        let found = ROMScanner.scan([root], catalog: try Catalog.load())
        #expect(found.count == 2)
        #expect(found.first { $0.path.hasSuffix("Game.cue") }?.detection == .system("psx"))
        #expect(found.first { $0.path.hasSuffix("noext.rom") }?.detection == .system("nes"))
    }
}
