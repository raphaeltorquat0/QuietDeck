import Foundation
import DeckKit

/// Tema Quiet no Game Mode. Tudo que instala vira um passo de `restore`, e o estado anterior dos
/// temas do usuário fica guardado no próprio Deck: restaurar devolve exatamente o que havia.
public struct ThemeHealth: Equatable, Sendable {
    public var steamVersion: String?
    public var deckyActive: Bool
    /// Seletores que o CSS Loader não sabe traduzir neste cliente.
    public var missingSelectors: [String]

    public var isHealthy: Bool { deckyActive && missingSelectors.isEmpty }
}

public enum QuietTheme {
    public static let themeName = "Quiet Clean"
    public static let storeTitle = "Loja"
    static let snapshot = ".local/share/quietdeck/theme-snapshot.json"
    static let themes = "homebrew/themes"
    static let overrides = ".steam/root/config/uioverrides"
    static let sounds = "homebrew/sounds/Quiet"
    static let tabMaster = "homebrew/settings/TabMaster/settings.json"

    static func resource(_ path: String) -> URL? {
        Bundle.deckKitResources?.appendingPathComponent("theme/" + path)
    }

    public static func selectors(css: String) -> [String] {
        let clean = css.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        guard let regex = try? NSRegularExpression(pattern: #"\.([a-z0-9]+_[A-Za-z0-9\-]+)"#) else { return [] }
        let names = regex.matches(in: clean, range: NSRange(clean.startIndex..., in: clean)).compactMap { Range($0.range(at: 1), in: clean).map { String(clean[$0]) } }
        return Array(Set(names)).sorted()
    }

    static func cleanCSS() throws -> String {
        guard let url = resource("QuietClean/shared.css") else { throw CocoaError(.fileNoSuchFile) }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Só leitura. A tabela `css_translations.json` é refeita pelo CSS Loader para cada cliente Steam.
    static func healthScript(selectors: [String]) -> String {
        let python = #"""
        import json, os, sys
        names = sys.argv[1:]
        try:
            d = json.load(open(os.path.expanduser("~/homebrew/themes/css_translations.json")))
            known = {x for v in d.values() for x in v}
            print(json.dumps([n for n in names if n not in known]))
        except Exception:
            print(json.dumps(names))
        """#
        return "python3 -c \(Shell.quote(python)) " + selectors.map(Shell.quote).joined(separator: " ")
            + "; systemctl is-active plugin_loader; grep -h -m1 '\"version\"' ~/.steam/root/package/steam_client_*.manifest 2>/dev/null | head -1 | tr -dc 0-9; echo"
    }

    public static func parseHealth(_ text: String) -> ThemeHealth {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        let missing = lines.first.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
        let version = lines.count > 2 ? lines[2] : nil
        return ThemeHealth(steamVersion: version?.isEmpty == false ? version : nil,
                           deckyActive: lines.count > 1 && lines[1] == "active", missingSelectors: missing)
    }

    public static func health(_ runner: any CommandRunner) async throws -> ThemeHealth {
        parseHealth(try await runner.run(healthScript(selectors: selectors(css: try cleanCSS()))).stdout)
    }

    public static func isInstalled(_ runner: any CommandRunner) async throws -> Bool {
        try await runner.run("test -e ~/\(snapshot)").ok
    }

    /// Lê o `active` de cada tema; é o que `restore` devolve.
    static let readStates = #"""
    python3 -c 'import glob,json,os
    out={}
    for p in glob.glob(os.path.expanduser("~/homebrew/themes/*/config_USER.json")):
        try:
            out[os.path.basename(os.path.dirname(p))]=json.load(open(p)).get("active",False)
        except Exception:
            pass
    print(json.dumps(out))'
    """#

    /// Liga e desliga temas sem mexer nas outras opções de cada um.
    static func setStates(_ states: [String: Bool]) -> String {
        let json = String(decoding: (try? JSONEncoder().encode(states)) ?? Data("{}".utf8), as: UTF8.self)
        let python = #"""
        import json, os, sys
        root = os.path.expanduser("~/homebrew/themes")
        for name, active in json.loads(sys.argv[1]).items():
            p = os.path.join(root, name, "config_USER.json")
            if not os.path.isdir(os.path.dirname(p)):
                continue
            c = {}
            if os.path.exists(p):
                c = json.load(open(p))
            c["active"] = active
            json.dump(c, open(p, "w"))
        """#
        return "python3 -c \(Shell.quote(python)) \(Shell.quote(json))"
    }

    /// Abas pedidas: Instalados, Favoritos, Emuladores (só com atalhos não-Steam) e Todos.
    public static func tabs(hasNonSteam: Bool) -> [String: [String: Any]] {
        var result: [String: [String: Any]] = [
            "Installed": ["id": "Installed", "title": "Instalados", "position": 0],
            "Favorites": ["id": "Favorites", "title": "Favoritos", "position": 1],
            "AllGames": ["id": "AllGames", "title": "Todos", "position": hasNonSteam ? 3 : 2],
        ]
        if hasNonSteam {
            result["quietdeck-emulators"] = [
                "id": "quietdeck-emulators", "title": "Emuladores", "position": 2, "filtersMode": "and",
                "filters": [["type": "platform", "inverted": false, "params": ["platform": "nonSteam"]]],
                "includesHidden": false, "categoriesToInclude": 0, "autoHide": false, "visibleToOthers": false,
                "sortByOverride": -1, "displayAsCollection": false,
            ]
        }
        return result
    }

    /// Só com o TabMaster instalado; a cópia original fica ao lado para `restore`.
    static func writeTabs(_ runner: any CommandRunner, user: String) async throws {
        let path = "~/" + tabMaster
        guard try await runner.run("test -d ~/homebrew/plugins/TabMaster").ok else { return }
        let hasNonSteam = try await SteamControl(runner: runner).hasShortcuts(user: user)
        let tabs = try JSONSerialization.data(withJSONObject: Self.tabs(hasNonSteam: hasNonSteam))
        let python = #"""
        import json, os, shutil, sys
        p = os.path.expanduser(sys.argv[1])
        os.makedirs(os.path.dirname(p), exist_ok=True)
        s = json.load(open(p)) if os.path.exists(p) else {}
        if os.path.exists(p) and not os.path.exists(p + ".quietdeck-backup"):
            shutil.copy(p, p + ".quietdeck-backup")
        s.setdefault("usersDict", {}).setdefault(sys.argv[2], {})["tabs"] = json.loads(sys.argv[3])
        json.dump(s, open(p, "w"))
        """#
        try await runner.check("python3 -c \(Shell.quote(python)) \(Shell.quote(path)) \(Shell.quote(user)) \(Shell.quote(String(decoding: tabs, as: UTF8.self)))")
    }

    static func files(model: String?) -> [(resource: String, remote: String)] {
        var list = [("QuietClean/theme.json", "\(themes)/\(themeName)/theme.json"),
                    ("QuietClean/shared.css", "\(themes)/\(themeName)/shared.css"),
                    ("screensaver/index.html", "\(overrides)/screensavers/quiet/index.html"),
                    ("screensaver/main.css", "\(overrides)/screensavers/quiet/main.css"),
                    ("screensaver/main.js", "\(overrides)/screensavers/quiet/main.js"),
                    // O Steam escolhe o nome pelo modelo: `oled_startup` no Galileo, `deck_startup` no LCD.
                    ("boot.webm", "\(overrides)/movies/\(model == "Steam Deck OLED" ? "oled" : "deck")_startup.webm"),
                    ("sounds/pack.json", "\(sounds)/pack.json")]
        for wav in ["deck_ui_navigation", "deck_ui_tile_scroll", "deck_ui_default_activation", "deck_ui_out_of_game_detail", "deck_ui_hide_modal"] {
            list.append(("sounds/\(wav).wav", "\(sounds)/\(wav).wav"))
        }
        return list
    }

    public enum Applied: Equatable, Sendable {
        /// O CSS Loader carregou agora.
        case live
        /// Sem a senha do deck não dá para reiniciar o Decky: vale no próximo boot.
        case afterReboot
    }

    /// Recusa instalar em cliente que o tema não conhece: tema pela metade pode prender o foco.
    public static func apply(_ runner: any CommandRunner, user: String, model: String?, password: String?) async throws -> Applied {
        let health = try await health(runner)
        guard health.isHealthy else {
            throw DeckError.unexpectedState("The theme doesn't match this Steam client: %@", health.missingSelectors.joined(separator: ", "))
        }
        let files = RemoteFiles(runner: runner)
        let home = try await files.home()
        let states = try JSONDecoder().decode([String: Bool].self, from: Data(try await runner.check(readStates).stdout.utf8))
        // Reaplicar não pode trocar o estado original pelo estado já com o tema.
        if !(try await files.exists("\(home)/\(snapshot)")) {
            try await files.write(try JSONEncoder().encode(states), to: "\(home)/\(snapshot)")
        }
        for file in Self.files(model: model) {
            guard let url = resource(file.resource) else { throw CocoaError(.fileNoSuchFile) }
            try await files.write(try Data(contentsOf: url), to: "\(home)/\(file.remote)")
        }
        var next = states.mapValues { _ in false }
        next[themeName] = true
        try await runner.check(setStates(next))
        try await writeTabs(runner, user: user)
        _ = try await SteamControl(runner: runner).addShortcuts([storeShortcut], user: user)
        return try await reload(runner, password: password)
    }

    public static let glassName = "Quiet Glass"
    static let glassFiles = ["theme.json", "glass.css", "opaque.css"]

    /// Fica ao lado dos temas do usuário, sem desligar nenhum, e não reinicia o Steam.
    public static func applyGlass(_ runner: any CommandRunner, password: String) async throws {
        var css = ""
        for name in glassFiles where name.hasSuffix(".css") {
            guard let url = resource("QuietGlass/\(name)") else { throw CocoaError(.fileNoSuchFile) }
            css += try String(contentsOf: url, encoding: .utf8)
        }
        let health = parseHealth(try await runner.run(healthScript(selectors: selectors(css: css))).stdout)
        guard health.isHealthy else {
            throw DeckError.unexpectedState("The theme doesn't match this Steam client: %@", health.missingSelectors.joined(separator: ", "))
        }
        let files = RemoteFiles(runner: runner)
        let home = try await files.home()
        for name in glassFiles {
            guard let url = resource("QuietGlass/\(name)") else { throw CocoaError(.fileNoSuchFile) }
            try await files.write(try Data(contentsOf: url), to: "\(home)/\(themes)/\(glassName)/\(name)")
        }
        try await runner.check(setStates([glassName: true]))
        // Instalar reinicia o Decky, e é aí que o CSS Loader relê os temas.
        if try await BundledPlugin.quietTune.install(runner: runner, password: password) == .alreadyCurrent {
            _ = try await reload(runner, password: password)
        }
    }

    public static func removeGlass(_ runner: any CommandRunner, password: String) async throws {
        let home = try await RemoteFiles(runner: runner).home()
        try await runner.check(setStates([glassName: false]))
        try await runner.check("rm -rf \(Shell.quote("\(home)/\(themes)/\(glassName)"))")
        if try await Decky.removePlugin(name: BundledPlugin.quietTune.name, runner: runner, password: password) == .notInstalled {
            _ = try await reload(runner, password: password)
        }
    }

    public static func hasGlass(_ runner: any CommandRunner) async throws -> Bool {
        try await runner.run("test -e ~/\(Shell.quote("\(themes)/\(glassName)/glass.css"))").ok
    }

    /// Último item da linha: abre a Loja, já que ela sai da home.
    public static let storeShortcut = Shortcut(name: storeTitle, exe: "/usr/bin/steam", startDir: "/usr/bin", launchOptions: "steam://store", tags: ["Quiet"])

    static func reload(_ runner: any CommandRunner, password: String?) async throws -> Applied {
        guard let password else { return .afterReboot }
        try await runner.check(.sudo("systemctl restart plugin_loader", password: password))
        return .live
    }

    /// Restaurar padrão: tema, TabMaster, sons, boot, protetor de tela e atalho da Loja.
    public static func restore(_ runner: any CommandRunner, user: String, password: String?) async throws -> Applied {
        let files = RemoteFiles(runner: runner)
        let home = try await files.home()
        guard let saved = try await files.read("\(home)/\(snapshot)") else { return .live }
        let states = try JSONDecoder().decode([String: Bool].self, from: saved)
        try await runner.check(setStates(states))
        let remove = ["\(themes)/\(themeName)", sounds, "\(overrides)/screensavers/quiet",
                      "\(overrides)/movies/deck_startup.webm", "\(overrides)/movies/oled_startup.webm"]
        try await runner.check("cd ~ && rm -rf " + remove.map(Shell.quote).joined(separator: " "))
        // O Steam gera uma miniatura ao lado do vídeo; sem o vídeo, ela e as pastas vazias não têm dono.
        // Sem `rmdir -p`: ele sobe até `.steam/root`, que é link simbólico, e falha com "Not a directory".
        let leftovers = ["\(overrides)/movies", "\(overrides)/screensavers", overrides].map(Shell.quote).joined(separator: " ")
        try await runner.check("cd ~ && rm -f \(overrides)/movies/deck_startup.jpg \(overrides)/movies/oled_startup.jpg && for d in \(leftovers); do if [ -d \"$d\" ]; then rmdir --ignore-fail-on-non-empty \"$d\"; fi; done")
        try await runner.check("cd ~ && if [ -e \(tabMaster).quietdeck-backup ]; then mv -f \(tabMaster).quietdeck-backup \(tabMaster); fi")
        _ = try await SteamControl(runner: runner).removeShortcuts(names: [storeTitle], user: user)
        try await runner.check("rm -f ~/\(snapshot)")
        return try await reload(runner, password: password)
    }

    /// Chamado a cada conexão: cliente novo sem os seletores desliga o tema, sem apagar nada.
    public static func disableIfBroken(_ runner: any CommandRunner) async throws -> ThemeHealth? {
        guard try await isInstalled(runner) else { return nil }
        let health = try await health(runner)
        if !health.isHealthy { try await runner.check(setStates([themeName: false])) }
        return health
    }
}
