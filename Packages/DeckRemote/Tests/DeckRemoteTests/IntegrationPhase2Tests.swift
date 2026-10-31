import Foundation
import Testing
import DeckKit
@testable import DeckRemote

extension IntegrationTests {

    @Test func flatpakLifecycleIsIdempotent() async throws {
        let r = try await Sim.runner()
        _ = try await Flatpaks.remove(Sim.flatpak, runner: r)
        #expect(try await Flatpaks.install(Sim.flatpak, runner: r) == .done)
        #expect(try await Flatpaks.install(Sim.flatpak, runner: r) == .alreadyInstalled)
        #expect(try await Flatpaks.installed(r).first { $0.appID == Sim.flatpak }?.installation == "user")
        #expect(try await Flatpaks.update(Sim.flatpak, runner: r) == .done)
        #expect(try await Flatpaks.remove(Sim.flatpak, runner: r) == .done)
        #expect(try await Flatpaks.remove(Sim.flatpak, runner: r) == .notInstalled)
    }

    @Test func emulationLayoutThenEmuDeckIsRespected() async throws {
        let r = try await Sim.runner()
        let catalog = try Catalog.load()
        try await r.check("rm -rf ~/Emulation ~/.config/EmuDeck ~/.var/app/org.ppsspp.PPSSPP")
        let plain = try await Emulation.paths(r)
        #expect(plain == EmulationPaths(root: "/home/deck/Emulation"))
        #expect(try await Emulation.prepare(r, paths: plain, systems: catalog.systems) > 0)
        #expect(try await Emulation.prepare(r, paths: plain, systems: catalog.systems) == 0)
        #expect(try await r.run("test -d ~/Emulation/roms/wiiu/roms && test -d ~/Emulation/bios/psx && test -d ~/Emulation/saves/ps2").ok)

        let ppsspp = try #require(catalog.emulator("ppsspp"))
        #expect(try await EmulatorSetup.configure(ppsspp, paths: plain, overwrite: false, runner: r) == .written)
        let cfg = "/home/deck/" + ppsspp.config!.path
        let files = RemoteFiles(runner: r)
        var text = String(decoding: try await files.read(cfg) ?? Data(), as: UTF8.self)
        #expect(text.contains("CurrentDirectory = /home/deck/Emulation/roms/psp"))
        guard case .needsConfirmation = try await EmulatorSetup.configure(ppsspp, paths: plain, overwrite: false, runner: r) else {
            Issue.record("config existente exige confirmação"); return
        }
        #expect(try await EmulatorSetup.configure(ppsspp, paths: plain, overwrite: true, runner: r) == .unchanged)

        try await r.check("mkdir -p ~/.config/EmuDeck && printf 'emulationPath=\"$HOME/Custom/Emu\"\\nromsPath=$HOME/Custom/Emu/roms\\n' > ~/.config/EmuDeck/settings.sh; sed -i 's/psp/mine/' \(Shell.quote(cfg))")
        let emu = try await Emulation.paths(r)
        #expect(emu.isEmuDeck && emu.roms == "/home/deck/Custom/Emu/roms")
        #expect(try await EmulatorSetup.configure(ppsspp, paths: emu, overwrite: true, runner: r) == .skippedEmuDeck)
        text = String(decoding: try await files.read(cfg) ?? Data(), as: UTF8.self)
        #expect(text.contains("roms/mine"))
        try await r.check("rm -rf ~/.config/EmuDeck ~/Custom ~/Emulation")
    }
}
