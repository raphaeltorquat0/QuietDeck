import Foundation
import Testing
import DeckKit
@testable import DeckRemote

extension IntegrationTests {

    @Test func compatToolVerifiedThenInstalledAndRemoved() async throws {
        let r = try await Sim.runner()
        try await r.check("rm -rf /tmp/ct ~/.local/share/Steam/compatibilitytools.d; mkdir -p /tmp/ct/GE-Proton1-1 && echo x > /tmp/ct/GE-Proton1-1/proton && cd /tmp/ct && tar -czf GE-Proton1-1-x86_64.tar.gz GE-Proton1-1 && sha512sum GE-Proton1-1-x86_64.tar.gz > sum")
        let archive = GitHubAsset(name: "GE-Proton1-1-x86_64.tar.gz", browser_download_url: "file:///tmp/ct/GE-Proton1-1-x86_64.tar.gz")
        let checksum = GitHubAsset(name: "s", browser_download_url: "file:///tmp/ct/sum")
        #expect(try await CompatTools.install(archive: archive, checksum: checksum, folderName: "GE-Proton1-1", runner: r) == .done)
        #expect(try await CompatTools.install(archive: archive, checksum: checksum, folderName: "GE-Proton1-1", runner: r) == .alreadyInstalled)
        #expect(try await CompatTools.installed(r) == ["GE-Proton1-1"])
        #expect(try await CompatTools.remove("GE-Proton1-1", runner: r) == .done)
        await #expect(throws: DeckError.self) { try await CompatTools.remove("../..", runner: r) }

        try await r.check("echo tampered >> /tmp/ct/GE-Proton1-1-x86_64.tar.gz")
        await #expect(throws: DeckError.self) { try await CompatTools.install(archive: archive, checksum: checksum, folderName: "GE-Proton1-1", runner: r) }
        #expect(try await CompatTools.installed(r).isEmpty)
    }

    @Test func savesBackupAndRestore() async throws {
        let r = try await Sim.runner()
        let paths = EmulationPaths(root: "/home/deck/Emulation")
        try await r.check("rm -rf ~/Emulation; mkdir -p ~/Emulation/saves/gba; echo slot1 > ~/Emulation/saves/gba/game.sav")
        let folder = Sim.dir.appendingPathComponent("saves-\(UUID().uuidString)")
        #expect(try await Saves.backup(paths: paths, emulators: [], to: folder, config: Sim.config, runner: r) == 1)
        #expect(try String(contentsOf: folder.appendingPathComponent("emulation/gba/game.sav"), encoding: .utf8) == "slot1\n")
        try await r.check("rm -rf ~/Emulation/saves/gba")
        #expect(try await Saves.restore(paths: paths, emulators: [], from: folder, config: Sim.config, runner: r) == 1)
        #expect(try await r.check("cat ~/Emulation/saves/gba/game.sav").stdout == "slot1\n")
    }

    @Test(.enabled(if: Sim.hasHarness)) func switchToGameMode() async throws {
        let r = try await Sim.runner()
        try await r.check("deck-sim desktop")
        #expect(try await DeviceProbe.read(r).mode == .desktop)
        try await QuickAction.switchToGameMode.run(r, password: nil)
        #expect(try await DeviceProbe.read(r).mode == .game)
    }
}
