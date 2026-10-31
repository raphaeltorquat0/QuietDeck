import Foundation
import Testing
import DeckKit
@testable import DeckRemote

extension IntegrationTests {

    @Test(.enabled(if: Sim.hasHarness)) func deckyPluginFromVerifiedZip() async throws {
        let r = try await Sim.runner()
        try await r.check("mkdir -p ~/homebrew/plugins; rm -rf /tmp/plug; mkdir -p /tmp/plug/Fan && cd /tmp/plug && printf '{\"name\":\"Fan Control\"}' > Fan/plugin.json && printf '{\"version\":\"1.2.3\"}' > Fan/package.json && python3 -m zipfile -c /tmp/fan.zip Fan")
        let hash = String(try await r.check("sha256sum /tmp/fan.zip").trimmed.prefix(64))
        let version = StorePlugin.Version(name: "1.2.3", hash: hash, artifact: "file:///tmp/fan.zip")
        #expect(try await Decky.installPlugin(name: "Fan Control", version: version, runner: r, password: Sim.password) == .done)
        #expect(try await Decky.plugins(r) == [InstalledPlugin(name: "Fan Control", version: "1.2.3", folder: "Fan")])
        #expect(try await r.check("stat -c %u ~/homebrew/plugins/Fan").trimmed == "0")
        #expect(try await Decky.installPlugin(name: "Fan Control", version: version, runner: r, password: Sim.password) == .alreadyCurrent)
        #expect(try await r.run("systemctl is-active plugin_loader").ok)

        let tampered = StorePlugin.Version(name: "9", hash: String(repeating: "0", count: 64), artifact: "file:///tmp/fan.zip")
        await #expect(throws: DeckError.self) { try await Decky.installPlugin(name: "Fan Control", version: tampered, runner: r, password: Sim.password) }
        #expect(try await Decky.plugins(r).count == 1)

        #expect(try await Decky.removePlugin(name: "Fan Control", runner: r, password: Sim.password) == .done)
        #expect(try await Decky.removePlugin(name: "Fan Control", runner: r, password: Sim.password) == .notInstalled)
        #expect(try await Decky.plugins(r).isEmpty)
    }

    @Test(.enabled(if: Sim.hasHarness && Sim.env["QUIETDECK_TEST_NETWORK"] != nil)) func officialDeckyInstaller() async throws {
        let r = try await Sim.runner()
        try await r.check(.sudo("rm -rf /home/deck/homebrew/services", password: Sim.password))
        try await Decky.install(r, password: Sim.password)
        let s = try await Decky.state(r)
        #expect(s.installed && s.serviceActive && s.version?.hasPrefix("v") == true)
    }

    @Test(.enabled(if: Sim.hasHarness)) func quietHomeInstallsFromBundledZip() async throws {
        let r = try await Sim.runner()
        try await r.check(.sudo("rm -rf /home/deck/homebrew/plugins /home/deck/.local/share/quietdeck/quiet-home.sha256; mkdir -p /home/deck/homebrew/plugins; chown deck /home/deck/homebrew/plugins", password: Sim.password))
        #expect(try await QuietHomePlugin.install(runner: r, password: Sim.password) == .installed)
        #expect(try await QuietHomePlugin.isInstalled(r))
        #expect(try await r.run("test -s ~/homebrew/plugins/QuietHome/dist/index.js").ok)
        #expect(try await QuietHomePlugin.install(runner: r, password: Sim.password) == .alreadyCurrent)
    }
}
