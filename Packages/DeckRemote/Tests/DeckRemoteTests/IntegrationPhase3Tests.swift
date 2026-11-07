import Foundation
import Testing
@testable import DeckKit
@testable import DeckRemote

extension IntegrationTests {

    @Test(.enabled(if: Sim.hasHarness)) func harnessReallyClobbersNaiveWrites() async throws {
        let r = try await Sim.runner()
        try await Sim.waitForSteam(r)
        let original = try #require(try await RemoteFiles(runner: r).read(Sim.vdf))
        let root = try ShortcutsFile.merge([Shortcut(name: "Naive", exe: "/x", startDir: "/")], into: VDF.parse(original)).root
        try await RemoteFiles(runner: r).write(VDF.serialize(root), to: Sim.vdf)
        #expect(try await Sim.shortcutNames(r).contains("Naive"))
        try await Sim.cycleSteam(r)
        #expect(try await !Sim.shortcutNames(r).contains("Naive"))
    }

    @Test(.enabled(if: Sim.hasHarness)) func gameModeWriteSurvivesRelaunch() async throws {
        let r = try await Sim.runner()
        try await r.check("deck-sim game")
        try await Sim.waitForSteam(r)
        let game = Shortcut(name: "Zelda's Quest", exe: "/usr/bin/flatpak", startDir: "/usr/bin", launchOptions: "run x", tags: ["N64"])
        let result = try await Sim.steam(r).addShortcuts([game], user: Sim.user)
        #expect(result.added == [game])
        #expect(try await r.run("test ! -e /run/deck-sim/masked && pgrep -x steam >/dev/null").ok)
        let backup = try #require(result.backup)
        #expect(try await r.run("test -s \(Shell.quote(backup))").ok)

        // A prova: Steam relançado leu o arquivo novo, então sobrevive a outro ciclo de morte.
        try await Sim.cycleSteam(r)
        try await Sim.cycleSteam(r)
        let names = try await Sim.shortcutNames(r)
        #expect(names.contains("Zelda's Quest") && names.contains("Existing Game"))
        let raw = try #require(try await RemoteFiles(runner: r).read(Sim.vdf))
        #expect(try VDF.parse(raw)["shortcuts"]?["0"]?["FutureField"] == .string("keep me"))

        // Nada novo: o Steam nem é tocado.
        let starts = try await r.check("wc -l < /run/deck-sim/steam.log").trimmed
        #expect(try await Sim.steam(r).addShortcuts([game], user: Sim.user).added.isEmpty)
        #expect(try await r.check("wc -l < /run/deck-sim/steam.log").trimmed == starts)
    }

    @Test(.enabled(if: Sim.hasHarness)) func desktopModeWriteSurvivesRestart() async throws {
        let r = try await Sim.runner()
        try await r.check("deck-sim desktop")
        try await Sim.waitForSteam(r)
        let game = Shortcut(name: "Desktop Game", exe: "/usr/bin/flatpak", startDir: "/usr/bin")
        #expect(try await Sim.steam(r).addShortcuts([game], user: Sim.user).added == [game])
        try await Sim.waitForSteam(r)
        try await r.check("pkill -TERM -x steam")
        try await Task.sleep(for: .milliseconds(1200))
        #expect(try await Sim.shortcutNames(r).contains("Desktop Game"))
        try await r.check("deck-sim game")
        try await Sim.waitForSteam(r)
    }

    @Test(.enabled(if: Sim.hasHarness)) func failedStartNeverLeavesTheUnitMasked() async throws {
        let r = try await Sim.runner()
        try await r.check("deck-sim game")
        try await Sim.waitForSteam(r)
        let locked = "/home/deck/.local/share/Steam/userdata/999/config"
        try await r.check("mkdir -p \(locked) && printf 'broken' > \(locked)/shortcuts.vdf")
        await #expect(throws: (any Error).self) {
            _ = try await Sim.steam(r).addShortcuts([Shortcut(name: "N", exe: "/x", startDir: "/")], user: "999")
        }
        #expect(try await r.run("test ! -e /run/deck-sim/masked").ok)
        try await r.check("rm -rf /home/deck/.local/share/Steam/userdata/999")
    }

    @Test func discoversSteamUsers() async throws {
        let r = try await Sim.runner()
        guard Sim.hasHarness else { return }
        #expect(try await SteamControl(runner: r).users() == [Sim.user])
    }

    @Test func quickRestartSteam() async throws {
        guard Sim.hasHarness else { return }
        let r = try await Sim.runner()
        try await r.check("deck-sim game")
        try await Sim.waitForSteam(r)
        let starts = Int(try await r.check("grep -c start /run/deck-sim/steam.log").trimmed)!
        try await Sim.steam(r).restart()
        try await Task.sleep(for: .milliseconds(500))
        #expect(Int(try await r.check("grep -c start /run/deck-sim/steam.log").trimmed)! > starts)
    }

    @Test func uploadWithQuotesAndSpacesReachesTheRightFolder() async throws {
        let r = try await Sim.runner()
        let file = try Sim.tempFile("it's a game (USA).iso", bytes: 200_000)
        let dest = "/home/deck/my sd/roms"
        try await r.check("rm -rf ~/my\\ sd; mkdir -p \(Shell.quote(dest))")
        let last = Box<Int>()
        try await Transfer.upload(file, to: dest, config: Sim.config) { last.value = $0.percent }
        let local = try await LocalHash.compute(file.path, algorithm: 256)
        let remote = try await r.check("sha256sum \(Shell.quote(dest + "/" + file.lastPathComponent))").trimmed
        #expect(remote.hasPrefix(local))
        #expect(try await r.check("ls ~").stdout.contains("my sd"))
        #expect(last.value == 100)
        try await r.check("rm -rf ~/my\\ sd")
    }

    @Test func interruptedUploadResumesFromPartial() async throws {
        let r = try await Sim.runner()
        let file = try Sim.tempFile("big.iso", bytes: 8_000_000)
        try await r.check("rm -rf ~/resume && mkdir -p ~/resume")
        let spec = Transfer.remoteSpec(Sim.config, path: "/home/deck/resume/", clientQuotes: false)
        let quotes = Transfer.clientQuotesPaths(versionOutput: try await LocalProcess.run("/usr/bin/rsync", ["--version"]).stdout)
        let args = ["--bwlimit=1000"] + Transfer.rsyncArguments(config: Sim.config, source: file.path, destination: quotes ? String(spec.filter { $0 != "'" }) : spec)
        let task = Task { try await LocalProcess.run("/usr/bin/rsync", args) }
        try await Task.sleep(for: .seconds(2))
        task.cancel()
        _ = try? await task.value
        try await Task.sleep(for: .milliseconds(500))
        let partial = Int(try await r.check("stat -c %s ~/resume/\(Transfer.partialDir)/big.iso").trimmed) ?? 0
        #expect(partial > 0 && partial < 8_000_000)
        try await Transfer.upload(file, to: "/home/deck/resume", config: Sim.config)
        #expect(try await r.check("sha256sum ~/resume/big.iso").trimmed.hasPrefix(try await LocalHash.compute(file.path, algorithm: 256)))
        #expect(try await !r.run("test -e ~/resume/\(Transfer.partialDir)/big.iso").ok)
    }

    @Test func sftpFallbackDelivers() async throws {
        let r = try await Sim.runner()
        let file = try Sim.tempFile("fall back.bin", bytes: 50_000)
        try await r.check("rm -rf ~/fb && mkdir -p ~/fb")
        try await Transfer.sftpUpload(file, to: "/home/deck/fb/", config: Sim.config, onProgress: nil)
        #expect(try await r.check("stat -c %s ~/fb/fall\\ back.bin").trimmed == "50000")
    }

    func importer(_ r: SSHRunner) throws -> RomImporter {
        RomImporter(runner: r, config: Sim.config, catalog: try Catalog.load(), workRoot: Sim.dir.appendingPathComponent("work"))
    }

    @Test func zipIsExtractedConvertedAndDeduplicated() async throws {
        guard LocalTools.find("chdman") != nil else { return }
        let r = try await Sim.runner()
        try await r.check("rm -rf ~/Emulation ~/.local/share/quietdeck")
        let paths = EmulationPaths(root: "/home/deck/Emulation")
        let src = Sim.dir.appendingPathComponent("disc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        for disc in 1...2 {
            let bin = "Game (Disc \(disc)).bin"
            try Data(repeating: UInt8(disc), count: 2352 * 400).write(to: src.appendingPathComponent(bin))
            try "FILE \"\(bin)\" BINARY\n  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n".write(to: src.appendingPathComponent("Game (Disc \(disc)).cue"), atomically: true, encoding: .utf8)
            let zip = src.appendingPathComponent("Game (Disc \(disc)).zip")
            let z = try await LocalProcess.run("/usr/bin/zip", ["-q", "-j", zip.path, src.appendingPathComponent(bin).path, src.appendingPathComponent("Game (Disc \(disc)).cue").path])
            #expect(z.ok)
        }
        let imp = try importer(r)
        let z1 = src.appendingPathComponent("Game (Disc 1).zip").path, z2 = src.appendingPathComponent("Game (Disc 2).zip").path
        let first = try await imp.importGame(path: z1, systemID: "psx", paths: paths) { _, _ in }
        #expect(!first.skippedAsDuplicate && first.remotePath.hasSuffix("Game (Disc 1).chd"))
        let second = try await imp.importGame(path: z2, systemID: "psx", paths: paths) { _, _ in }
        #expect(second.remotePath == "/home/deck/Emulation/roms/psx/Game.m3u")
        #expect(try await r.check("cat ~/Emulation/roms/psx/Game.m3u").stdout == "Game (Disc 1).chd\nGame (Disc 2).chd\n")

        let again = try await imp.importGame(path: z1, systemID: "psx", paths: paths) { _, _ in }
        #expect(again.skippedAsDuplicate)
        // Apagado à mão no Deck: o índice não engana, envia de novo.
        try await r.check("rm ~/Emulation/roms/psx/Game\\ \\(Disc\\ 1\\).chd")
        #expect(try await !imp.importGame(path: z1, systemID: "psx", paths: paths) { _, _ in }.skippedAsDuplicate)
    }

    @Test func cartridgeStaysZippedAndCueTravelsWithTracksWhenNoChd() async throws {
        let r = try await Sim.runner()
        try await r.check("rm -rf ~/Emulation ~/.local/share/quietdeck")
        let paths = EmulationPaths(root: "/home/deck/Emulation")
        let rom = try Sim.tempFile("Mario.zip", bytes: 1000)
        #expect(try await importer(r).importGame(path: rom.path, systemID: "snes", paths: paths) { _, _ in }.remotePath == "/home/deck/Emulation/roms/snes/Mario.zip")
    }

    @Test func notEnoughSpaceFailsBeforeSending() async throws {
        let r = try await Sim.runner()
        try await r.check("df -B1 --output=avail /tmp >/dev/null")
        // Sem encher o disco: um `df` que responde pouco, instalado só para este usuário.
        try await r.check("mkdir -p ~/bin && printf '#!/bin/sh\\necho 1\\n' > ~/bin/df && chmod +x ~/bin/df")
        let fake = PathRunner(base: r)
        let imp = RomImporter(runner: fake, config: Sim.config, catalog: try Catalog.load(), workRoot: Sim.dir.appendingPathComponent("work"))
        let rom = try Sim.tempFile("Space.gba", bytes: 4096)
        await #expect(throws: DeckError.self) {
            try await imp.importGame(path: rom.path, systemID: "gba", paths: EmulationPaths(root: "/home/deck/Emulation")) { _, _ in }
        }
        #expect(try await !r.run("test -e ~/Emulation/roms/gba/Space.gba").ok)
        try await r.check("rm -rf ~/bin")
    }

    @Test func biosHashesAreCheckedOnTheDeck() async throws {
        let r = try await Sim.runner()
        let paths = EmulationPaths(root: "/home/deck/Emulation")
        try await r.check("rm -rf ~/Emulation; mkdir -p ~/Emulation/bios; printf good > ~/Emulation/bios/ok.bin; printf bad > ~/Emulation/bios/scph5501.bin")
        let good = try await LocalProcess.run("/bin/sh", ["-c", "printf good | /usr/bin/shasum -a 1"]).stdout.prefix(40)
        let table = [BIOSEntry(system: "gba", file: "ok.bin", size: 4, md5: "", sha1: String(good)),
                     BIOSEntry(system: "psx", file: "scph5501.bin", size: 4, md5: "", sha1: String(repeating: "0", count: 40)),
                     BIOSEntry(system: "nds", file: "firmware.bin", size: 4, md5: "", sha1: String(repeating: "1", count: 40))]
        let output = try await r.check(BIOS.scan(paths: paths)).stdout
        #expect(BIOS.status(scanOutput: output, table: table) == ["gba": .ok, "psx": .invalid, "nds": .missing])
    }

    // MARK: Ponta a ponta

    @MainActor @Test(.enabled(if: Sim.hasHarness)) func queueSendsGameThenAddsItToSteam() async throws {
        let r = try await Sim.runner()
        try await r.check("deck-sim game; rm -rf ~/Emulation ~/.local/share/quietdeck")
        try await Sim.waitForSteam(r)
        var catalog = try Catalog.load()
        // Mesmo fluxo do app, com o emulador que existe no flatpak local do Deck simulado.
        catalog.emulators = [Emulator(id: "hello", name: "Hello", flatpak: Sim.flatpak, systems: ["gba"], launch: "run \(Sim.flatpak) {rom}")]
        catalog.systems = catalog.systems.filter { $0.id == "gba" }.map { var s = $0; s.emulator = "hello"; s.core = nil; return s }
        let context = JobContext(runner: r, config: Sim.config, catalog: catalog, password: Sim.password, workRoot: Sim.dir.appendingPathComponent("work")) {}
        let queue = JobQueue(storeURL: nil) { job, progress in try await JobExecutor.run(job, context: context, progress: progress) }
        let rom = try Sim.tempFile("Queue Game.gba", bytes: 4096)
        let deck = UUID()
        queue.enqueue(Job(deckID: deck, title: "send", action: .importROM(localPath: rom.path, systemID: "gba", sdMount: nil)))
        queue.enqueue(Job(deckID: deck, title: "steam", action: .addToSteam(user: Sim.user, games: [GameRef(systemID: "gba", title: "Queue Game")], sdMount: nil)))
        await queue.waitUntilIdle()
        #expect(queue.jobs.map(\.state) == [.succeeded, .succeeded])
        try await Sim.cycleSteam(r)
        #expect(try await Sim.shortcutNames(r).contains("Queue Game"))
    }

    /// Capa antiga desenhada pelo app é trocada; arte do usuário, PNG ou não, fica.
    @Test func artReplacesOnlyOurOldCovers() async throws {
        let r = try await Sim.runner()
        let grid = "/home/deck/.local/share/Steam/userdata/778/config/grid"
        try await r.check("mkdir -p \(grid) && printf old > \(grid)/1p.png && printf user > \(grid)/2p.png && printf user > \(grid)/3p.jpg")
        let old = String(try await r.check("printf old | sha256sum").stdout.prefix(64))
        let new = try Sim.tempFile("new.png", bytes: 64)
        let items = [1, 2, 3, 4].map { ArtItem(appID: UInt32($0), kind: .portrait, file: new.path, replaces: [old]) }
        #expect(try await JobExecutor.writeArt(items, user: "778", runner: r) == 2)
        let sums = try await r.check("cd \(grid) && sha256sum 1p.png 2p.png 3p.jpg 4p.png").stdout
        let newSum = String(try await r.check("sha256sum \(grid)/4p.png").stdout.prefix(64))
        #expect(sums.contains("\(newSum)  1p.png"))
        #expect(!sums.contains("\(newSum)  2p.png") && !sums.contains("\(newSum)  3p.jpg"))
        try await r.check("rm -rf /home/deck/.local/share/Steam/userdata/778")
    }
}
