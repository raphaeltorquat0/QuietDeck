import Foundation
import Testing
import DeckKit
@testable import DeckRemote

@Suite struct AppImageTests {
    let catalog = try! Catalog.load()
    var lichii: Emulator { catalog.emulator("lichii")! }
    let digest = "sha256:" + String(repeating: "ab", count: 32)

    func release(_ tag: String, _ assets: [GitHubAsset]) -> GitHubRelease { GitHubRelease(tag_name: tag, prerelease: true, assets: assets) }
    func asset(_ name: String = "lichii-linux-x86_64-deck.AppImage", digest: String? = nil) -> GitHubAsset {
        GitHubAsset(name: name, browser_download_url: "https://example.invalid/\(name)", digest: digest, size: 10)
    }

    /// Maior número, não ordem da API; sem digest ou sem o asset certo não conta.
    @Test func latestIsHighestVerifiableBuild() throws {
        let source = try #require(lichii.appImage)
        let releases = [
            release("deck-88", [asset(digest: digest)]),
            release("deck-100", [asset(digest: nil)]),
            release("deck-90", [asset("lichii-linux-x86_64-pgo.AppImage", digest: digest)]),
            release("nightly", [asset(digest: digest)]),
            release("deck-9", [asset(digest: digest)]),
        ]
        let picked = try #require(AppImages.latest(releases, source: source))
        #expect(picked.tag == "deck-88")
        #expect(AppImages.latest([], source: source) == nil)
    }

    @Test func digestAndTagValidation() {
        #expect(AppImages.sha256(asset(digest: digest)) == String(repeating: "ab", count: 32))
        #expect(AppImages.sha256(asset(digest: "sha1:" + String(repeating: "a", count: 40))) == nil)
        #expect(AppImages.sha256(asset(digest: "sha256:xyz")) == nil)
        for bad in ["", ".", "..", "build-1/..", "../x", "-rf", "a b", "build-1;rm"] { #expect(!AppImages.isSafeTag(bad), "\(bad)") }
        #expect(AppImages.isSafeTag("build-88"))
        #expect(AppImages.buildNumber("build-88", prefix: "build-") == 88)
        #expect(AppImages.buildNumber("build-0", prefix: "build-") == nil)
        #expect(AppImages.buildNumber("build-8x", prefix: "build-") == nil)
    }

    /// Só `versions/<tag>` conta; link para fora ou tag estranha é ignorado.
    @Test func statusParsing() {
        #expect(AppImages.parseStatus("current versions/build-88\nprevious versions/build-83\n") == .init(current: "build-88", previous: "build-83"))
        #expect(AppImages.parseStatus("current /usr/bin\nprevious versions/../x\n") == .init())
        #expect(!AppImages.parseStatus("").isInstalled)
    }

    @Test func shortcutRunsTheStableLauncher() throws {
        let system = try #require(catalog.system("switch2"))
        let rom = "/run/media/deck/Samsung Evo/Emulation/roms/switch2/Some Game.xci"
        let s = try #require(Library.shortcut(name: "Some Game", romPath: rom, system: system, catalog: catalog, corePath: nil, home: "/home/deck"))
        #expect(s.exe == "\"/home/deck/.local/share/quietdeck/emulators/lichii/run.sh\"")
        #expect(s.startDir == "\"/home/deck/.local/share/quietdeck/emulators/lichii\"")
        // Opções de `launch_params.cpp` (getopt): `-f` tela cheia, `-g` jogo.
        #expect(s.launchOptions == "-f -g \"\(rom)\"")
        // Sem a pasta pessoal do Deck não dá para montar o caminho: melhor nenhum atalho que um errado.
        #expect(Library.shortcut(name: "Some Game", romPath: rom, system: system, catalog: catalog, corePath: nil, home: nil) == nil)
    }

    /// O arquivo nasce do próprio emulador: antes disso o QuietDeck só cria controle e o atualizador desligado.
    @Test func profilesTurnOffTheBuiltInUpdater() throws {
        var text: String?
        for profile in lichii.profiles ?? [] {
            if let after = EmulatorSetup.patched(profile, current: text) { text = after }
        }
        let ini = try #require(text)
        #expect(ini.contains("[UI]\ncheck_for_updates\\default=false\ncheck_for_updates=false"))
        #expect(ini.contains("player_0_button_a=\"engine:sdl,port:0,guid:03000000de280000ff11000001000000,button:0\""))
        // Escolha do usuário fica: com a chave já presente, nada muda.
        let chosen = "[UI]\ncheck_for_updates\\default=false\ncheck_for_updates=true\n"
        #expect(EmulatorSetup.patched(lichii.profiles![1], current: chosen) == nil)
    }

    @Test func launcherEntersItsFolder() {
        let script = AppImages.launcherScript
        #expect(script.hasPrefix("#!/bin/sh\n"))
        #expect(script.contains("cd \"$(dirname \"$0\")\" || exit 1\nfor f in ./current/*.AppImage; do exec \"$f\" \"$@\"; done"))
    }
}
