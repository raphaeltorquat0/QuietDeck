import Foundation
import Testing
import DeckKit
@testable import DeckRemote

/// Num Deck de verdade (`QUIETDECK_REAL_DECK=<host>`), com a chave já instalada. Nada aqui apaga dados
/// do usuário: os testes de `Integration` fazem `rm -rf ~/Emulation` e nunca podem rodar num aparelho real.
/// `QUIETDECK_REAL_STEP` escolhe o passo, para acompanhar cada um na tela do Deck.
enum Real {
    static let env = ProcessInfo.processInfo.environment
    static let host = env["QUIETDECK_REAL_DECK"] ?? ""
    static func step(_ name: String) -> Bool { !host.isEmpty && env["QUIETDECK_REAL_STEP"] == name }
    static let config = SSHConfig(host: host, identityFile: NSHomeDirectory() + "/.ssh/quietdeck_ed25519",
                                  knownHostsFile: NSHomeDirectory() + "/Library/Application Support/QuietDeck/known_hosts")
    static var runner: SSHRunner { SSHRunner(config: config) }
    static var steam: SteamControl {
        var s = SteamControl(runner: runner)
        s.pollInterval = .milliseconds(500)
        return s
    }
    static func user() async throws -> String { try #require(try await SteamControl(runner: runner).users().first) }
    static var flatpak: String { env["QUIETDECK_REAL_FLATPAK"] ?? "com.snes9x.Snes9x" }
    static func shortcut(_ name: String) -> Shortcut {
        Shortcut(name: name, exe: "/usr/bin/flatpak", startDir: "/usr/bin", launchOptions: "run \(flatpak)", tags: ["QuietDeck"])
    }
    static func names() async throws -> [String] {
        let r = runner
        let path = try await SteamControl(runner: r).configDirectory(user: try await user()) + "/shortcuts.vdf"
        return ShortcutsFile.existing(in: try VDF.parse(try #require(try await RemoteFiles(runner: r).read(path)))).map(\.name)
    }
}

@Suite("RealDeck", .serialized) struct RealDeckTests {
    /// ROM vazia, só para percorrer o job até o Steam reiniciado. Desfaça com o passo `switch-clean`.
    @Test(.enabled(if: Real.step("switch-shortcut"))) func switchShortcut() async throws {
        let r = Real.runner
        let paths = try await Emulation.paths(r, sdMount: nil)
        let dir = paths.roms + "/switch"
        try await r.check("mkdir -p \(Shell.quote(dir)) && : > \(Shell.quote(dir + "/QuietDeck Teste [0100000000000000][v0] (0.01 GB).nsp"))")
        let action = JobAction.addToSteam(user: try await Real.user(), games: [GameRef(systemID: "switch", title: "QuietDeck Teste")], sdMount: nil)
        let context = JobContext(runner: r, config: Real.config, catalog: try Catalog.load(), password: nil, workRoot: FileManager.default.temporaryDirectory) {}
        try await JobExecutor.run(Job(deckID: UUID(), title: "Teste", action: action), context: context) { _, _ in }
        #expect(try await Real.names().contains("QuietDeck Teste"))
    }

    /// Perfis de controle e vídeo do Dolphin pelo mesmo código do atalho. Não mexe em jogo aberto:
    /// o Dolphin regrava a configuração ao fechar.
    @Test(.enabled(if: Real.step("dolphin-profiles"))) func dolphinProfiles() async throws {
        let r = Real.runner
        #expect(try await !r.run("pgrep -x dolphin-emu").ok, "Feche o jogo antes")
        let dolphin = try #require(try Catalog.load().emulator("dolphin"))
        _ = try await EmulatorSetup.applyProfiles(dolphin, runner: r)
        let dir = "~/.var/app/org.DolphinEmu.dolphin-emu/config/dolphin-emu"
        let gfx = try await r.check("cat \(dir)/GFX.ini").stdout
        #expect(gfx.contains("InternalResolution = 2") && gfx.contains("wideScreenHack = True"))
        #expect(try await r.check("cat \(dir)/Dolphin.ini").stdout.contains("Fullscreen = True"))
        #expect(try await EmulatorSetup.applyProfiles(dolphin, runner: r) == 0)
    }

    /// Firmware falso pelo caminho real (rsync com nome novo e troca da pasta), apagado no fim.
    /// Só roda sem firmware instalado: nunca toca num `registered` de verdade.
    @Test(.enabled(if: Real.step("firmware-fake"))) func firmwareSwap() async throws {
        let r = Real.runner
        let base = "~/" + SwitchFirmware.deckDirectory
        #expect(try await !r.run("test -e \(base)/registered").ok, "Já há firmware: o teste não roda")
        let src = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        for i in 0..<SwitchFirmware.minimum { try Data("fake\(i)".utf8).write(to: src.appendingPathComponent("f\(i).nca")) }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let n = try await SwitchFirmware.install(src, config: Real.config, runner: r, work: work) { _, _ in }
        #expect(n == SwitchFirmware.minimum)
        #expect(try await r.check("cat \(base)/registered/f3.nca/00").stdout == "fake3")
        #expect(try await !r.run("test -e \(base)/registered.quietdeck-new").ok)
        try await r.check("rm -rf \(base)/registered")
    }

    /// Mod falso para um Title ID que não existe, pelo caminho real, apagado no fim.
    @Test(.enabled(if: Real.step("mod-fake"))) func modInstall() async throws {
        let r = Real.runner
        let pack = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("QuietDeck Teste PT-BR")
        let romfs = pack.appendingPathComponent("atmosphere/contents/01000000000FFFF0/romfs/text")
        try FileManager.default.createDirectory(at: romfs, withIntermediateDirectories: true)
        try Data("ola".utf8).write(to: romfs.appendingPathComponent("msg.bin"))
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(try await SwitchMods.install(pack, config: Real.config, runner: r, work: work) { _, _ in } == ["01000000000FFFF0"])
        let dir = "~/" + SwitchMods.deckDirectory + "/01000000000FFFF0"
        #expect(try await r.check("cat \(dir)/'QuietDeck Teste PT-BR'/romfs/text/msg.bin").stdout == "ola")
        try await r.check("rm -rf \(dir)")
    }

    @Test(.enabled(if: Real.step("switch-clean"))) func switchClean() async throws {
        let r = Real.runner
        let paths = try await Emulation.paths(r, sdMount: nil)
        #expect(try await SteamControl(runner: r).removeShortcuts(names: ["QuietDeck Teste"], user: try await Real.user()))
        try await r.check("rm -f \(Shell.quote(paths.roms + "/switch/QuietDeck Teste [0100000000000000][v0] (0.01 GB).nsp"))")
        #expect(try await !Real.names().contains("QuietDeck Teste"))
    }

    @Test(.enabled(if: Real.step("record"))) func recordFixture() async throws {
        let url = URL(fileURLWithPath: Real.env["QUIETDECK_REAL_OUT"] ?? "/tmp/steamos-real.json")
        let r = RecordingRunner(base: Real.runner, recorder: CommandRecorder(url: url, source: "steamos-real"))
        let status = try await DeviceProbe.read(r)
        print(status)
        _ = try await Flatpaks.installed(r)
        _ = try await r.run(Flatpaks.updates)
        _ = try await r.run(Decky.stateScript)
        _ = try await Decky.plugins(r)
        _ = try await r.run(CompatTools.list)
        #expect(status.osVersion?.hasPrefix("3.") == true && status.batteryPercent != nil)
        #expect(status.temperatures["CPU"] != nil)
    }

    @Test(.enabled(if: Real.step("transfer"))) func transferWithSpacesAndResume() async throws {
        let r = Real.runner
        let dir = "/home/deck/.cache/quietdeck-test/my folder"
        try await r.check("mkdir -p \(Shell.quote(dir))")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("it's a game.iso")
        try Data((0..<30_000_000).map { UInt8(truncatingIfNeeded: $0 &* 7) }).write(to: file)
        try await Transfer.upload(file, to: dir, config: Real.config)
        let local = try await LocalHash.compute(file.path, algorithm: 256)
        #expect(try await r.check("sha256sum \(Shell.quote(dir + "/" + file.lastPathComponent))").trimmed.hasPrefix(local))
        try await r.check("rm -rf ~/.cache/quietdeck-test")
    }

    @Test(.enabled(if: Real.step("flatpak"))) func userFlatpakOnRealRemote() async throws {
        let r = Real.runner
        #expect(try await Flatpaks.install(Real.flatpak, runner: r) == .done)
        #expect(try await Flatpaks.install(Real.flatpak, runner: r) == .alreadyInstalled)
        #expect(try await Flatpaks.installed(r).first { $0.appID == Real.flatpak }?.installation == "user")
    }

    @Test(.enabled(if: Real.step("desktop"))) func shortcutInDesktopMode() async throws {
        #expect(try await DeviceProbe.read(Real.runner).mode == .desktop)
        let s = Real.shortcut("QuietDeck Test Desktop")
        #expect(try await Real.steam.addShortcuts([s], user: try await Real.user()).added == [s])
        try await Task.sleep(for: .seconds(20))
        #expect(try await Real.steam.running())
        #expect(try await Real.names().contains(s.name))
    }

    @Test(.enabled(if: Real.step("switch"))) func switchToGameMode() async throws {
        try await QuickAction.switchToGameMode.run(Real.runner, password: nil)
    }

    @Test(.enabled(if: Real.step("game"))) func shortcutInGameMode() async throws {
        #expect(try await DeviceProbe.read(Real.runner).mode == .game)
        let s = Real.shortcut("QuietDeck Test Game Mode")
        #expect(try await Real.steam.addShortcuts([s], user: try await Real.user()).added == [s])
        try await Task.sleep(for: .seconds(20))
        #expect(try await Real.steam.running())
        #expect(try await Real.runner.run(DeviceProbe.userBus + "systemctl --user is-enabled steam-launcher.service").trimmed != "masked-runtime")
        #expect(try await Real.names().contains(s.name))
    }

    @Test(.enabled(if: Real.step("theme"))) func applyThemeWithoutPassword() async throws {
        let r = Real.runner
        let user = try await Real.user()
        let health = try await QuietTheme.health(r)
        print(health)
        #expect(health.isHealthy)
        let model = try await DeviceProbe.read(r).model
        #expect(try await QuietTheme.apply(r, user: user, model: model, password: nil) == .afterReboot)
        #expect(try await Real.steam.removeShortcuts(names: ["QuietDeck Test Desktop", "QuietDeck Test Game Mode"], user: user))
        try await Task.sleep(for: .seconds(20))
        #expect(try await Real.steam.running())
        let names = try await Real.names()
        print(names)
        #expect(names.contains(QuietTheme.storeTitle) && !names.contains("QuietDeck Test Desktop"))
    }

    @Test(.enabled(if: Real.step("restore"))) func restoreThemeWithoutPassword() async throws {
        let r = Real.runner
        let user = try await Real.user()
        #expect(try await QuietTheme.restore(r, user: user, password: nil) == .afterReboot)
        try await Task.sleep(for: .seconds(20))
        #expect(try await Real.steam.running())
        #expect(try await !QuietTheme.isInstalled(r))
        print(try await Real.names())
    }

    /// A prova definitiva: o Steam relançado precisa ter lido o arquivo, senão o perde ao sair de novo.
    @Test(.enabled(if: Real.step("survive"))) func shortcutsSurviveAnotherSteamCycle() async throws {
        try await Real.steam.restart()
        try await Task.sleep(for: .seconds(20))
        let names = try await Real.names()
        #expect(names.contains("QuietDeck Test Game Mode"))
        print(names)
    }
}
