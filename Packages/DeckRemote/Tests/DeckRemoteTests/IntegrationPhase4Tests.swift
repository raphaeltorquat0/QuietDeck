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
        try await r.check(.sudo("rm -rf /home/deck/homebrew/plugins /home/deck/.local/share/quietdeck/quiet-home.sha256; mkdir -p /home/deck/homebrew/plugins /home/deck/homebrew/settings; chown deck /home/deck/homebrew/plugins; echo '{\"disabled_plugins\": [\"Quiet Home\", \"Other\"]}' > /home/deck/homebrew/settings/loader.json", password: Sim.password))
        #expect(try await BundledPlugin.quietHome.install(runner: r, password: Sim.password) == .installed)
        #expect(try await BundledPlugin.quietHome.isInstalled(r))
        #expect(try await r.run("test -s ~/homebrew/plugins/QuietHome/dist/index.js").ok)
        let settings = try await r.check("cat ~/homebrew/settings/loader.json").stdout
        #expect(!settings.contains("Quiet Home") && settings.contains("Other"))
        #expect(try await r.run("systemctl is-active plugin_loader").ok)
        #expect(try await BundledPlugin.quietHome.install(runner: r, password: Sim.password) == .alreadyCurrent)
    }

    /// Liga ao lado dos temas do usuário, sem desligar nenhum, e sai sem deixar rastro.
    @Test(.enabled(if: Sim.hasHarness)) func quietGlassKeepsOtherThemesAndRemovesCleanly() async throws {
        let r = try await Sim.runner()
        try await r.check("mkdir -p ~/homebrew/themes/Obsidian ~/homebrew/plugins; echo '{\"active\":true}' > ~/homebrew/themes/Obsidian/config_USER.json; rm -f ~/.local/share/quietdeck/quiet-tune.sha256")
        let translations = try await r.run("cat ~/homebrew/themes/css_translations.json 2>/dev/null").stdout
        defer { Task { [translations] in try? await RemoteFiles(runner: r).write(Data(translations.utf8), to: "/home/deck/homebrew/themes/css_translations.json") } }
        try await RemoteFiles(runner: r).write(Data(#"{"a": ["header_Header", "footer_BasicFooter", "quickaccessmenu_QuickAccessMenu", "quickaccessmenu_Tab", "quickaccessmenu_Selected", "quickaccessmenu_Title", "mainmenu_Menu"]}"#.utf8), to: "/home/deck/homebrew/themes/css_translations.json")
        try await QuietTheme.applyGlass(r, password: Sim.password)
        #expect(try await QuietTheme.hasGlass(r))
        #expect(try await BundledPlugin.quietTune.isInstalled(r))
        #expect(try await r.check("cat ~/homebrew/themes/'Quiet Glass'/config_USER.json").stdout.contains("true"))
        #expect(try await r.check("cat ~/homebrew/themes/Obsidian/config_USER.json").stdout.contains("true"))
        // Reaplicar não muda nada.
        try await QuietTheme.applyGlass(r, password: Sim.password)
        try await QuietTheme.removeGlass(r, password: Sim.password)
        #expect(try await !QuietTheme.hasGlass(r))
        #expect(try await !BundledPlugin.quietTune.isInstalled(r))
        #expect(try await r.check("cat ~/homebrew/themes/Obsidian/config_USER.json").stdout.contains("true"))
    }
}
