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
        let s = try #require(Library.shortcut(name: "Golden Sun", romPath: "/r/Golden Sun.gba", system: catalog.system("gba")!, catalog: catalog, corePath: "/c/mgba_libretro.so", home: nil))
        #expect(s.exe == "\"/usr/bin/flatpak\"")
        #expect(s.launchOptions == "run org.libretro.RetroArch -f -L \"/c/mgba_libretro.so\" \"/r/Golden Sun.gba\"")
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
        #expect(found.count == 3)
        #expect(found.first { $0.path.hasSuffix("notes.txt") }?.detection == .unknown)
        #expect(found.first { $0.path.hasSuffix("Game.cue") }?.detection == .system("psx"))
        #expect(found.first { $0.path.hasSuffix("noext.rom") }?.detection == .system("nes"))
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func fakeNSZ(_ body: String, in dir: URL) throws -> String {
        let tool = dir.appendingPathComponent("nsz")
        try "#!/bin/sh\n\(body)\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return tool.path
    }

    @Test func decompressMovesFinishedGameAndReusesIt() async throws {
        let dir = try tempDir()
        let tool = try fakeNSZ(#"echo "$@" >> "$0.calls"; touch "$4/Game.nsp""#, in: dir)
        let source = dir.appendingPathComponent("Game.nsz")
        for _ in 0..<2 {
            let out = try await RomImporter.decompress(source, work: dir, tool: tool)
            #expect(out.lastPathComponent == "Game.nsp")
            #expect(FileManager.default.fileExists(atPath: out.path))
        }
        let calls = try String(contentsOfFile: tool + ".calls", encoding: .utf8)
        #expect(calls.split(separator: "\n").count == 1)
        #expect(calls.hasPrefix("-D --verify -o "))
    }

    @Test func decompressAsksForKeysAndKeepsNothing() async throws {
        let dir = try tempDir()
        let tool = try fakeNSZ(#"echo "Exception: Could not load keys file." >&2; exit 1"#, in: dir)
        await #expect(throws: DeckError.unexpectedState("Switch keys are missing. Drop your own prod.keys on Library, then try again.")) {
            _ = try await RomImporter.decompress(dir.appendingPathComponent("Game.nsz"), work: dir, tool: tool)
        }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("decompressed-Game").path))
    }

    @Test func decompressFailsWhenToolCreatesNoGame() async throws {
        let dir = try tempDir()
        let tool = try fakeNSZ("exit 0", in: dir)
        await #expect(throws: DeckError.self) {
            _ = try await RomImporter.decompress(dir.appendingPathComponent("Game.xcz"), work: dir, tool: tool)
        }
    }

    /// IPS que troca os dois primeiros bytes por "HI".
    private let hiPatch = Data("PATCH".utf8) + Data([0, 0, 0, 0, 2]) + Data("HIEOF".utf8)

    @Test func patchedCopyKeepsOriginalAndIsReused() async throws {
        let dir = try tempDir()
        let rom = dir.appendingPathComponent("Game (USA).sfc"), patch = dir.appendingPathComponent("Game PT-BR.ips")
        try Data("abcd".utf8).write(to: rom)
        try hiPatch.write(to: patch)
        let out = try await RomImporter.patched(rom, with: patch, named: "Game (USA) (Game PT-BR).sfc", work: dir)
        #expect(out.lastPathComponent == "Game (USA) (Game PT-BR).sfc")
        #expect(try Data(contentsOf: out) == Data("HIcd".utf8))
        #expect(try Data(contentsOf: rom) == Data("abcd".utf8))
        try FileManager.default.removeItem(at: patch)
        #expect(try await RomImporter.patched(rom, with: patch, named: out.lastPathComponent, work: dir) == out)
    }

    @Test func patchedDiscRenamesTracksAndPatchesTheFirst() async throws {
        let dir = try tempDir()
        let cue = dir.appendingPathComponent("Game.cue"), patch = dir.appendingPathComponent("p.ips")
        try "FILE \"Game (Track 1).bin\" BINARY\n  TRACK 01 MODE2/2352\nFILE \"Game (Track 2).bin\" BINARY\n  TRACK 02 AUDIO\n".write(to: cue, atomically: true, encoding: .utf8)
        try Data("data".utf8).write(to: dir.appendingPathComponent("Game (Track 1).bin"))
        try Data("song".utf8).write(to: dir.appendingPathComponent("Game (Track 2).bin"))
        try hiPatch.write(to: patch)
        let out = try await RomImporter.patched(cue, with: patch, named: "Game (p).cue", work: dir)
        let sheet = try String(contentsOf: out, encoding: .utf8)
        #expect(ROMPlan.referencedFiles(cueSheet: sheet, extension: "cue") == ["Game (p) (Track 1).bin", "Game (p) (Track 2).bin"])
        let folder = out.deletingLastPathComponent()
        #expect(try Data(contentsOf: folder.appendingPathComponent("Game (p) (Track 1).bin")) == Data("HIta".utf8))
        #expect(try Data(contentsOf: folder.appendingPathComponent("Game (p) (Track 2).bin")) == Data("song".utf8))
    }

    @Test func patchRefusesCompressedImagesAndExplainsWrongVersion() async throws {
        let dir = try tempDir()
        let chd = dir.appendingPathComponent("Game.chd"), rom = dir.appendingPathComponent("Game.iso"), patch = dir.appendingPathComponent("p.xdelta")
        await #expect(throws: DeckError.self) { _ = try await RomImporter.patched(chd, with: patch, named: "x.chd", work: dir) }
        try Data("abcd".utf8).write(to: rom)
        try Data().write(to: patch)
        let tool = try fakeNSZ(#"echo "xdelta3: source file BLAKE3 mismatch: x" >&2; exit 1"#, in: dir)
        await #expect(throws: DeckError.unexpectedState("%@ was made for another version of this game. Check the CRC32 or SHA-1 its readme asks for.", "p.xdelta")) {
            _ = try await RomImporter.patched(rom, with: patch, named: "Game (p).iso", work: dir, xdelta: tool)
        }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("patched-Game (p)/Game (p).iso").path))
    }

    /// Com o `xdelta3` do Homebrew, quando instalado: confere o formato e a mensagem reais.
    @Test(.enabled(if: LocalTools.find("xdelta3") != nil)) func patchWithRealXdelta() async throws {
        let dir = try tempDir()
        let a = dir.appendingPathComponent("a.iso"), b = dir.appendingPathComponent("b.iso"), patch = dir.appendingPathComponent("t.xdelta")
        let source = Data((0..<200_000).map { UInt8($0 % 251) })
        var target = source
        target.replaceSubrange(1000..<1010, with: Data("TRADUZIDO!".utf8))
        try source.write(to: a)
        try target.write(to: b)
        let tool = LocalTools.find("xdelta3")!
        #expect(try await LocalProcess.run(tool, ["-e", "-f", "-s", a.path, b.path, patch.path]).ok)
        let out = try await RomImporter.patched(a, with: patch, named: "a (t).iso", work: dir)
        #expect(try Data(contentsOf: out) == target)
        var wrong = source
        wrong[5] ^= 1
        try wrong.write(to: a)
        await #expect(throws: DeckError.unexpectedState("%@ was made for another version of this game. Check the CRC32 or SHA-1 its readme asks for.", "t.xdelta")) {
            _ = try await RomImporter.patched(a, with: patch, named: "a (t2).iso", work: dir)
        }
    }

    @Test func shortcutPointsToBaseGameNotUpdate() {
        func game(_ name: String) -> Library.Game { Library.Game(systemID: "switch", name: name, path: "/r/" + name, size: 1) }
        let update = game("Zelda [01006BB00C6F0800][v131072] (0.04 GB).nsp"), base = game("Zelda [01006BB00C6F0000][v0] (5.84 GB).nsp")
        let ref = GameRef(systemID: "switch", title: "Zelda")
        #expect(Library.pick(ref, in: [update, base]) == base)
        #expect(Library.pick(ref, in: [update]) == nil)
    }

    @Test func controllerProfileRespectsManualMapping() throws {
        let profile = try #require(try Catalog.load().emulator("dolphin")?.profiles?.first { $0.path.hasSuffix("GCPadNew.ini") })
        let factory = "[GCPad1]\nDevice = XInput2/0/Virtual core pointer\nButtons/A = `X`\nMain Stick/Calibration = 100.00\n"
        let written = try #require(EmulatorSetup.patched(profile, current: factory))
        #expect(written.contains("Device = SDL/0/Steam Deck Controller"))
        #expect(written.contains("Buttons/A = `Button S`"))
        #expect(written.contains("Main Stick/Calibration = 100.00"))
        #expect(!written.contains("XInput2"))
        #expect(EmulatorSetup.patched(profile, current: written) == nil)
        #expect(EmulatorSetup.patched(profile, current: "[GCPad1]\nDevice = SDL/0/Outro\n[GCPad2]\nDevice = XInput2/0/Virtual core pointer\n") == nil)
    }

    @Test func ryubingGetsDeckControllerAndScreenOnce() throws {
        let profiles = try #require(try Catalog.load().emulator("ryubing")?.profiles)
        let factory = #"{"version": 70, "start_fullscreen": false, "docked_mode": true, "res_scale": 1, "input_config": [{"backend": "WindowKeyboard", "id": "0"}]}"#
        let input = try #require(EmulatorSetup.patched(profiles[0], current: factory))
        // O Ryubing 1.3.3 do Flathub só conhece GamepadSDL2; GamepadSDL3 faz ele descartar o arquivo inteiro.
        #expect(ConfigPatcher.jsonValue(input, path: "input_config.0.backend") == "GamepadSDL2")
        #expect(ConfigPatcher.jsonValue(input, path: "input_config.0.id") == "0-00000003-28de-0000-ff11-000001000000")
        #expect(ConfigPatcher.jsonValue(input, path: "res_scale") == "1")
        // Como no Dolphin: cada botão faz o que a letra impressa no Deck diz.
        #expect(ConfigPatcher.jsonValue(input, path: "input_config.0.right_joycon.button_a") == "A")
        #expect(ConfigPatcher.jsonValue(input, path: "input_config.0.right_joycon.button_x") == "X")
        #expect(EmulatorSetup.patched(profiles[0], current: input) == nil)
        let screen = try #require(EmulatorSetup.patched(profiles[1], current: input))
        #expect(ConfigPatcher.jsonValue(screen, path: "start_fullscreen") == "true")
        #expect(ConfigPatcher.jsonValue(screen, path: "docked_mode") == "false")
        // Quem voltou ao modo dock no Ryubing não é desfeito no próximo atalho.
        #expect(EmulatorSetup.patched(profiles[1], current: screen.replacingOccurrences(of: #""docked_mode" : false"#, with: #""docked_mode" : true"#)) == nil)
        #expect(EmulatorSetup.patched(profiles[0], current: #"{"input_config": [{"backend": "GamepadSDL2", "id": "1-outro"}]}"#) == nil)
        #expect(EmulatorSetup.patched(profiles[0], current: nil) == nil)
    }

    /// Bateria no Lichii (#125): cada chave só muda enquanto está no padrão de fábrica do Lichii.
    @Test func lichiiBatteryProfileKeepsUserChoice() throws {
        let profiles = try #require(try Catalog.load().emulator("lichii")?.profiles).filter { $0.untouched?.hasSuffix("\\default=true") == true }
        #expect(profiles.count == 6)
        let factory = "[UI]\nconfirmStop\\default=true\nconfirmStop=0\n[Renderer]\ngpu_accuracy\\default=true\ngpu_accuracy=1\nframe_pacing_mode\\default=false\nframe_pacing_mode=4\n"
        var current = factory
        for profile in profiles { current = EmulatorSetup.patched(profile, current: current) ?? current }
        #expect(current.contains("confirmStop\\default=false\nconfirmStop=2"))
        #expect(current.contains("gpu_accuracy\\default=false\ngpu_accuracy=0"))
        // 120 escolhido pelo usuário fica.
        #expect(current.contains("frame_pacing_mode=4") && !current.contains("frame_pacing_mode=1"))
        // Chave ausente espera o Lichii criar o arquivo completo; aplicado, não reaplica.
        #expect(!current.contains("resolution_setup"))
        for profile in profiles { #expect(EmulatorSetup.patched(profile, current: current) == nil) }
    }

    /// Sem mouse no Game Mode: Eden fecha sem perguntar e não busca atualização; tema escuro só sobre o claro de fábrica.
    @Test func edenAndRetroArchProfilesForGameMode() throws {
        let catalog = try Catalog.load()
        let eden = try #require(catalog.emulator("eden")?.profiles).filter { $0.path.hasSuffix("qt-config.ini") && $0.entries.allSatisfy { $0.section == "UI" } }
        let factory = "[UI]\nconfirmStop\\default=true\nconfirmStop=0\ncheck_for_updates\\default=true\ncheck_for_updates=true\ntheme\\default=false\ntheme=colorful\n"
        var current = factory
        for profile in eden { current = EmulatorSetup.patched(profile, current: current) ?? current }
        #expect(current.contains("confirmStop=2") && current.contains("check_for_updates=false") && current.contains("theme=colorful_dark"))
        for profile in eden { #expect(EmulatorSetup.patched(profile, current: current) == nil) }
        // Tema escolhido pelo usuário fica.
        let theme = try #require(eden.first { $0.entries.contains { $0.key == "theme" } })
        #expect(EmulatorSetup.patched(theme, current: "[UI]\ntheme\\default=false\ntheme=default\n") == nil)
        let retroarch = try #require(catalog.emulator("retroarch")?.profiles?.first { $0.entries.contains { $0.key == "input_menu_toggle_gamepad_combo" } })
        #expect(try #require(EmulatorSetup.patched(retroarch, current: "input_menu_toggle_gamepad_combo = \"0\"\n")).contains("input_menu_toggle_gamepad_combo = \"2\""))
        #expect(EmulatorSetup.patched(retroarch, current: "input_menu_toggle_gamepad_combo = \"4\"\n") == nil)
    }

    @Test func videoProfileOnlyFillsMissingKeys() throws {
        let profiles = try #require(try Catalog.load().emulator("dolphin")?.profiles)
        let gfx = try #require(profiles.first { $0.path.hasSuffix("GFX.ini") })
        let fresh = try #require(EmulatorSetup.patched(gfx, current: ""))
        #expect(fresh.contains("[Settings]\nInternalResolution = 2\nwideScreenHack = True\nAspectRatio = 3"))
        // Quem voltou para 1x no emulador continua em 1x; só o que falta é acrescentado.
        let chosen = try #require(EmulatorSetup.patched(gfx, current: "[Settings]\nInternalResolution = 1\n"))
        #expect(chosen.contains("InternalResolution = 1") && !chosen.contains("InternalResolution = 2"))
        #expect(EmulatorSetup.patched(gfx, current: fresh) == nil)
        let main = try #require(profiles.first { $0.path.hasSuffix("Dolphin.ini") })
        #expect(try #require(EmulatorSetup.patched(main, current: "[General]\nISOPaths = 2\n")).hasSuffix("[Display]\nFullscreen = True\n"))
    }

    @Test func ps4GameIsAFolder() throws {
        let catalog = try Catalog.load()
        let root = try tempDir()
        let game = root.appendingPathComponent("Dump/CUSA00900")
        try FileManager.default.createDirectory(at: game.appendingPathComponent("sce_sys"), withIntermediateDirectories: true)
        try Data(count: 10).write(to: game.appendingPathComponent("eboot.bin"))
        try Data(count: 5).write(to: game.appendingPathComponent("sce_sys/param.sfo"))
        try Data(count: 3).write(to: game.appendingPathComponent("other.bin"))
        try Data(count: 3).write(to: root.appendingPathComponent("Dump/Golden Sun.gba"))
        let found = ROMScanner.scan([root], catalog: catalog)
        #expect(found.count == 2)
        let ps4Game = try #require(found.first { $0.detection == .system("ps4") })
        #expect(ps4Game.path.hasSuffix("/Dump/CUSA00900") && ps4Game.size == 18)

        let paths = EmulationPaths(root: "/home/deck/Emulation")
        let listing = "10\tps4/Bloodborne [CUSA00900]/eboot.bin\n3\tps4/Bloodborne [CUSA00900]/other.bin\n4\tps4/Bloodborne [CUSA00900]/sce_module/x.bin\n"
        let games = Library.parse(listing, systems: catalog.systems, paths: paths)
        #expect(games == [Library.Game(systemID: "ps4", name: "Bloodborne [CUSA00900]", path: "/home/deck/Emulation/roms/ps4/Bloodborne [CUSA00900]/eboot.bin", size: 10)])
        let game0 = try #require(Library.pick(GameRef(systemID: "ps4", title: "Bloodborne"), in: games))
        let ps4 = try #require(catalog.system("ps4"))
        let s = try #require(Library.shortcut(name: "Bloodborne", romPath: game0.path, system: ps4, catalog: catalog, corePath: nil, home: nil))
        #expect(s.launchOptions == "run --command=shadps4 net.shadps4.shadPS4 -f true -g \"/home/deck/Emulation/roms/ps4/Bloodborne [CUSA00900]/eboot.bin\"")
    }

    @Test func partialUploadsAreNotGames() throws {
        let catalog = try Catalog.load()
        let listing = "10\tswitch/.quietdeck-partial/RE0.nsp\n10\tswitch/.RE0.nsp.kaKvW8\n10\tswitch/RE0.nsp\n"
        let games = Library.parse(listing, systems: catalog.systems, paths: EmulationPaths(root: "/home/deck/Emulation"))
        #expect(games.map(\.path) == ["/home/deck/Emulation/roms/switch/RE0.nsp"])
    }

    @Test func newestSwitchUpdateIsChosen() {
        func g(_ n: String) -> Library.Game { Library.Game(systemID: "switch", name: n, path: "/r/" + n, size: 1) }
        let games = [g("Mario [010099C022B96000][v0].nsp"), g("Mario [010099C022B96800][v327680].nsp"),
                     g("Mario [010099C022B96800][v65536].nsp"), g("Zelda [01006BB00C6F0800][v131072].nsp")]
        #expect(SwitchUpdates.latest(games) == ["010099c022b96000": "/r/Mario [010099C022B96800][v327680].nsp",
                                                "01006bb00c6f0000": "/r/Zelda [01006BB00C6F0800][v131072].nsp"])
    }

    @Test func edenRunsTheGamesRyubingCannot() throws {
        let catalog = try Catalog.load()
        let switchSystem = try #require(catalog.system("switch"))
        #expect(switchSystem.emulator(for: "Super Mario Galaxy [010099C022B96000][v0] (3.30 GB).nsp") == "eden")
        #expect(switchSystem.emulator(for: "Resident Evil 0 [010097000BC10000][v0].nsp") == "ryubing")
        let s = try #require(Library.shortcut(name: "Super Mario Galaxy", romPath: "/r/Super Mario Galaxy [010099C022B96000][v0].nsp", system: switchSystem, catalog: catalog, corePath: nil, home: nil))
        #expect(s.launchOptions == "run dev.eden_emu.eden -f -g \"/r/Super Mario Galaxy [010099C022B96000][v0].nsp\"")
        let eden = try #require(catalog.emulator("eden")?.profiles)
        let factory = "[Controls]\nplayer_0_button_a\\default=false\nplayer_0_button_a=\"engine:keyboard,code:67,toggle:0\"\n[System]\nuse_docked_mode\\default=true\nuse_docked_mode=1\n"
        let pad = try #require(EmulatorSetup.patched(eden[0], current: factory))
        #expect(pad.contains("player_0_button_a=\"engine:sdl,port:0,guid:03000000de280000ff11000001000000,button:0\""))
        #expect(EmulatorSetup.patched(eden[0], current: pad) == nil)
        #expect(try #require(EmulatorSetup.patched(eden[1], current: factory)).contains("use_docked_mode=0"))
    }

    @Test func ps3DiscFolderAndPackages() throws {
        let catalog = try Catalog.load()
        let detector = ROMDetector(systems: catalog.systems)
        #expect(detector.detect(path: "/d/Patch 1.01.pkg", prefix: Data([0x7F, 0x50, 0x4B, 0x47]), size: 10) == .system("ps3"))
        #expect(detector.detect(path: "/d/Game.pkg", prefix: Data([0x7F, 0x43, 0x4E, 0x54]), size: 10) == .system("ps4"))

        let root = try tempDir()
        let game = root.appendingPathComponent("GoW [BCES00791]")
        try FileManager.default.createDirectory(at: game.appendingPathComponent("PS3_GAME/USRDIR"), withIntermediateDirectories: true)
        try Data(count: 4).write(to: game.appendingPathComponent("PS3_GAME/USRDIR/EBOOT.BIN"))
        try Data(count: 4).write(to: game.appendingPathComponent("PS3_GAME/PARAM.SFO"))
        try Data([0x7F, 0x50, 0x4B, 0x47]).write(to: game.appendingPathComponent("GoW Patch 1.01.pkg"))
        let found = ROMScanner.scan([root], catalog: catalog)
        #expect(found.filter { $0.detection == .system("ps3") }.map { ($0.path as NSString).lastPathComponent }.sorted() == ["GoW Patch 1.01.pkg", "GoW [BCES00791]"])

        let paths = EmulationPaths(root: "/home/deck/Emulation")
        let listing = "9\tps3/God of War [BCES00791]/PS3_GAME/PARAM.SFO\n9\tps3/God of War [BCES00791]/PS3_GAME/ICON0.PNG\n9\tps3/Demon.iso\n"
        let games = Library.parse(listing, systems: catalog.systems, paths: paths)
        #expect(games.map(\.name) == ["God of War [BCES00791]", "Demon.iso"])
        let ps3 = try #require(catalog.system("ps3"))
        let s = try #require(Library.shortcut(name: "God of War", romPath: games[0].path, system: ps3, catalog: catalog, corePath: nil, home: nil))
        #expect(s.launchOptions.hasSuffix("\"/home/deck/Emulation/roms/ps3/God of War [BCES00791]/PS3_GAME/USRDIR/EBOOT.BIN\""))
        #expect(try #require(Library.shortcut(name: "Demon", romPath: games[1].path, system: ps3, catalog: catalog, corePath: nil, home: nil)).launchOptions.hasSuffix("\"/home/deck/Emulation/roms/ps3/Demon.iso\""))
        var header = Data([0x7F, 0x50, 0x4B, 0x47]) + Data(count: 0x2C)
        header += Data("EP9000-BCES00791_00-GOWHDCLSHIP02222".utf8) + Data(count: 0x30)
        let pkg = root.appendingPathComponent("header.pkg")
        try header.write(to: pkg)
        #expect(try PS3Install.packageTitleID(pkg) == "BCES00791")
    }

    @Test func rpcs3PadProfileOnlyWhenMissing() throws {
        let profile = try #require(try Catalog.load().emulator("rpcs3")?.profiles?.first)
        #expect(EmulatorSetup.patched(profile, current: nil) == "Player 1 Input:\n  Handler: SDL\n  Device: Steam Deck Controller 1\n")
        #expect(EmulatorSetup.patched(profile, current: "Player 1 Input:\n  Handler: Keyboard\n") == nil)
        let video = try #require(try Catalog.load().emulator("rpcs3")?.profiles?.last)
        let factory = "Video:\n  Renderer: Vulkan\n  Shader Mode: Async Recompiler with Shader Interpreter\n  Shader Precision: High\n"
        #expect(EmulatorSetup.patched(video, current: factory) == "Video:\n  Renderer: Vulkan\n  Shader Mode: Async Recompiler (multi-threaded)\n  Shader Precision: High\n")
        #expect(EmulatorSetup.patched(video, current: factory.replacingOccurrences(of: "Async Recompiler with Shader Interpreter", with: "Shader Interpreter only")) == nil)
    }

    @Test func keysAreValidatedAndPrivate() throws {
        let dir = try tempDir(), home = dir.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let bad = dir.appendingPathComponent("notes.keys"), good = dir.appendingPathComponent("prod.keys")
        try "hello".write(to: bad, atomically: true, encoding: .utf8)
        #expect(throws: DeckError.self) { try SwitchKeys.install(from: bad, home: home) }
        let target = home.appendingPathComponent(".switch/prod.keys")
        #expect(!FileManager.default.fileExists(atPath: target.path))
        try ("header_key = " + String(repeating: "0", count: 64) + "\n").write(to: good, atomically: true, encoding: .utf8)
        try SwitchKeys.install(from: good, home: home)
        let mode = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        // title.keys: pares rights id = title key; um prod.keys renomeado não passa.
        let titles = dir.appendingPathComponent("title.keys")
        try ("header_key = " + String(repeating: "0", count: 64) + "\n").write(to: titles, atomically: true, encoding: .utf8)
        #expect(throws: DeckError.self) { try SwitchKeys.install(from: titles, home: home) }
        try (String(repeating: "a", count: 32) + " = " + String(repeating: "b", count: 32) + "\n").write(to: titles, atomically: true, encoding: .utf8)
        try SwitchKeys.install(from: titles, home: home)
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".switch/title.keys").path))
    }
}
