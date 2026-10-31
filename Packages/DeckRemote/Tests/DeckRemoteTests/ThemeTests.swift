import Foundation
import Testing
@testable import DeckKit
@testable import DeckRemote

@Suite struct ThemeUnitTests {
    /// Os dois patches precisam cobrir as mesmas abas, ou um estado deixaria um menu sem tema.
    @Test func glassPatchesCoverTheSameMenusAndOpaqueHasNoFilter() throws {
        let manifest = try #require(QuietTheme.resource("QuietGlass/theme.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        let patches = try #require(json["patches"] as? [String: Any])
        let menus = try #require(patches["Menus"] as? [String: Any])
        let values = try #require(menus["values"] as? [String: [String: [String]]])
        #expect(menus["default"] as? String == "Vidro")
        // A chave é sensível a maiúsculas: `quickaccess` não casa com janela nenhuma e o tema não aparece.
        #expect(values["Vidro"]?["glass.css"] == ["bigpicture", "bigpictureoverlay"])
        #expect(values["Opaco"]?["opaque.css"] == ["bigpicture", "bigpictureoverlay"])
        let opaque = try String(contentsOf: try #require(QuietTheme.resource("QuietGlass/opaque.css")), encoding: .utf8)
        #expect(opaque.contains("backdrop-filter: none") && !opaque.contains("blur("))
        let glass = try String(contentsOf: try #require(QuietTheme.resource("QuietGlass/glass.css")), encoding: .utf8)
        #expect(Set(QuietTheme.selectors(css: opaque)).isSubset(of: QuietTheme.selectors(css: glass)))
        #expect(glass.contains("@supports not (backdrop-filter") && glass.contains("prefers-reduced-transparency"))
    }

    @Test func selectorsComeFromTheBundledThemeAndSkipComments() throws {
        let names = QuietTheme.selectors(css: "/* .fake_Comment */ .a_B::after, .c_D-e.gpfocus {} .plain {}")
        #expect(names == ["a_B", "c_D-e"])
        #expect(try QuietTheme.selectors(css: QuietTheme.cleanCSS()).contains("gamepadhome_TabbedContent"))
    }

    /// Pior caso do pedido: arte branca. Relação WCAG de texto branco sobre branco escurecido pelo scrim.
    @Test func scrimKeepsTextContrastOverWhiteArt() throws {
        func contrast(alpha: Double) -> Double {
            let c = 1 - alpha
            let l = c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            return 1.05 / (l + 0.05)
        }
        let css = try QuietTheme.cleanCSS()
        let top = String(try #require(css.split(separator: "\n").first { $0.contains("linear-gradient(to top") }))
        let alphas = try NSRegularExpression(pattern: #"rgba\(0, 0, 0, ([0-9.]+)\)"#)
            .matches(in: top, range: NSRange(location: 0, length: top.utf16.count))
            .compactMap { Range($0.range(at: 1), in: top).flatMap { Double(top[$0]) } }
        #expect(alphas.count == 3)
        #expect(contrast(alpha: alphas.min()!) >= 4.5)
    }

    @Test func hidingUsesDisplayNoneOnly() throws {
        let css = try QuietTheme.cleanCSS()
        #expect(css.contains("display: none"))
        #expect(!css.contains("visibility:") && !css.contains("opacity: 0"))
    }

    @Test func noTextBelowFourteenPixels() throws {
        let css = try QuietTheme.cleanCSS()
        let sizes = try NSRegularExpression(pattern: #"font-size: ([0-9]+)px"#).matches(in: css, range: NSRange(css.startIndex..., in: css))
            .compactMap { Range($0.range(at: 1), in: css).flatMap { Int(css[$0]) } }
        #expect(!sizes.isEmpty && sizes.allSatisfy { $0 >= 14 })
    }

    @Test func healthParsing() {
        let ok = QuietTheme.parseHealth("[]\nactive\n1792618285\n")
        #expect(ok.isHealthy && ok.steamVersion == "1792618285")
        #expect(!QuietTheme.parseHealth("[\"a_B\"]\nactive\n\n").isHealthy)
        #expect(!QuietTheme.parseHealth("[]\ninactive\n").isHealthy)
    }

    @Test func emulatorsTabOnlyWithNonSteamShortcuts() {
        #expect(QuietTheme.tabs(hasNonSteam: false)["quietdeck-emulators"] == nil)
        #expect(QuietTheme.tabs(hasNonSteam: true)["quietdeck-emulators"] != nil)
        #expect(QuietTheme.tabs(hasNonSteam: true).count == 4)
    }

    @Test func bootMovieFollowsModel() {
        #expect(QuietTheme.files(model: "Steam Deck OLED").contains { $0.remote.hasSuffix("movies/oled_startup.webm") })
        #expect(QuietTheme.files(model: "Steam Deck LCD").contains { $0.remote.hasSuffix("movies/deck_startup.webm") })
    }

    @Test func storeShortcutTargetsStore() {
        #expect(QuietTheme.storeShortcut.launchOptions == "steam://store")
    }

    @Test func removeRenumbersAndKeepsOthers() throws {
        let a = Shortcut(name: "A", exe: "/a", startDir: "/"), b = Shortcut(name: "B", exe: "/b", startDir: "/")
        let root = try ShortcutsFile.merge([a, b], into: ShortcutsFile.emptyFile).root
        let result = ShortcutsFile.remove(names: ["A"], from: root)
        #expect(result.removed == 1)
        #expect(ShortcutsFile.existing(in: result.root).map(\.name) == ["B"])
        #expect(result.root["shortcuts"]?["0"]?["AppName"] == .string("B"))
        #expect(ShortcutsFile.remove(names: ["Z"], from: root).removed == 0)
    }
}

extension IntegrationTests {
    /// Tema do usuário ativo antes, tudo de volta depois: a prova do "restaurar em um clique".
    @Test func themeAppliesThenRestoresExactly() async throws {
        guard Sim.hasHarness else { return }
        let r = try await Sim.runner()
        try await r.check("deck-sim game")
        try await Sim.waitForSteam(r)
        let css = try QuietTheme.selectors(css: QuietTheme.cleanCSS())
        let table = try JSONEncoder().encode(Dictionary(uniqueKeysWithValues: css.map { ($0, [$0]) }))
        try await r.check("rm -rf ~/homebrew/themes ~/homebrew/sounds ~/.steam/root/config/uioverrides ~/.local/share/quietdeck; mkdir -p ~/homebrew/themes/Obsidian ~/homebrew/themes/Other; printf '{\"active\": true, \"Main Color\": \"Black\"}' > ~/homebrew/themes/Obsidian/config_USER.json; printf '{\"active\": false}' > ~/homebrew/themes/Other/config_USER.json")
        try await RemoteFiles(runner: r).write(table, to: "/home/deck/homebrew/themes/css_translations.json")
        try await r.check(.sudo("systemctl start plugin_loader", password: Sim.password))
        let before = try await Sim.shortcutNames(r)

        #expect(try await QuietTheme.apply(r, user: Sim.user, model: "Steam Deck LCD", password: Sim.password) == .live)
        #expect(try await r.check("cat ~/homebrew/themes/Obsidian/config_USER.json").stdout.contains("\"active\": false"))
        #expect(try await r.check("cat ~/homebrew/themes/Obsidian/config_USER.json").stdout.contains("Black"))
        #expect(try await r.check("cat '/home/deck/homebrew/themes/Quiet Clean/config_USER.json'").stdout.contains("true"))
        #expect(try await r.run("test -s ~/.steam/root/config/uioverrides/movies/deck_startup.webm && test -s ~/.steam/root/config/uioverrides/screensavers/quiet/index.html && test -s ~/homebrew/sounds/Quiet/pack.json").ok)
        #expect(try await QuietTheme.isInstalled(r))
        #expect(try await Sim.shortcutNames(r).contains(QuietTheme.storeTitle))
        #expect(try await QuietTheme.apply(r, user: Sim.user, model: "Steam Deck LCD", password: Sim.password) == .live)

        // Cliente novo sem um seletor: o tema sai sozinho e nada mais muda.
        try await RemoteFiles(runner: r).write(Data("{}".utf8), to: "/home/deck/homebrew/themes/css_translations.json")
        #expect(try await QuietTheme.disableIfBroken(r)?.isHealthy == false)
        #expect(try await r.check("cat '/home/deck/homebrew/themes/Quiet Clean/config_USER.json'").stdout.contains("false"))
        await #expect(throws: DeckError.self) { _ = try await QuietTheme.apply(r, user: Sim.user, model: nil, password: Sim.password) }

        #expect(try await QuietTheme.restore(r, user: Sim.user, password: Sim.password) == .live)
        #expect(try await r.check("cat ~/homebrew/themes/Obsidian/config_USER.json").stdout.contains("\"active\": true"))
        #expect(try await r.run("test ! -e '/home/deck/homebrew/themes/Quiet Clean' && test ! -e ~/homebrew/sounds/Quiet && test ! -e ~/.steam/root/config/uioverrides/movies/deck_startup.webm").ok)
        #expect(try await !QuietTheme.isInstalled(r))
        #expect(try await Sim.shortcutNames(r) == before)
        try await Sim.cycleSteam(r)
        #expect(try await Sim.shortcutNames(r) == before)
    }
}
