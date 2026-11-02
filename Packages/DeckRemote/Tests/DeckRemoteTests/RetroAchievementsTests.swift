import Foundation
import Testing
import DeckKit
@testable import DeckRemote

@Suite struct RetroAchievementsTests {
    let account = RetroAchievementsAccount(username: "Link", token: "tok123")

    @Test func loginSendsFormAndReadsToken() throws {
        #expect(String(decoding: RetroAchievements.form(["r": "login2", "u": "Link", "p": "a&b c=d"]), as: UTF8.self) == "p=a%26b%20c%3Dd&r=login2&u=Link")
        let ok = Data(#"{"Success":true,"User":"Link","Token":"tok123","Score":10}"#.utf8)
        #expect(try RetroAchievements.parseLogin(ok) == account)
        let refused = Data(#"{"Success":false,"Error":"Invalid User/Password combination. Please try again"}"#.utf8)
        #expect(throws: DeckError.unexpectedState("RetroAchievements refused the login: %@", "Invalid User/Password combination. Please try again")) {
            try RetroAchievements.parseLogin(refused)
        }
        #expect(throws: DeckError.self) { try RetroAchievements.parseLogin(Data("<html>".utf8)) }
    }

    @Test func emulatorsGetTokenNeverPassword() throws {
        let catalog = try Catalog.load()
        let ra = try #require(catalog.emulator("retroarch")), dol = try #require(catalog.emulator("dolphin")), ryu = try #require(catalog.emulator("ryubing"))
        let retroarch = try #require(RetroAchievements.profiles(for: ra, account: account).first)
        let cfg = ConfigPatcher.apply("cheevos_enable = \"false\"\ncheevos_password = \"old\"\nvideo_fullscreen = \"false\"\n", format: retroarch.format, entries: retroarch.entries)
        #expect(cfg == "cheevos_enable = \"true\"\ncheevos_password = \"\"\nvideo_fullscreen = \"false\"\ncheevos_username = \"Link\"\ncheevos_token = \"tok123\"\n")
        let dolphin = try #require(RetroAchievements.profiles(for: dol, account: nil).first)
        #expect(ConfigPatcher.apply("", format: dolphin.format, entries: dolphin.entries) == "[Achievements]\nEnabled = False\nUsername = \nApiToken = \n")
        #expect(RetroAchievements.profiles(for: ryu, account: account).isEmpty)
    }

    @Test func openEmulatorIsLeftAlone() async throws {
        let dolphin = try #require(try Catalog.load().emulator("dolphin"))
        let r = ReplayRunner(["flatpak ps --columns=application": CommandResult(stdout: "org.DolphinEmu.dolphin-emu\n")])
        await #expect(throws: DeckError.self) { _ = try await EmulatorSetup.applyAchievements(dolphin, account: account, runner: r) }
        #expect(r.executed == ["flatpak ps --columns=application"])
    }
}
