import Foundation
import DeckKit

/// Emuladores em AppImage (Lichii), em `~/.local/share/quietdeck/emulators/<id>`:
/// `versions/<tag>/<asset>`, os symlinks relativos `current` e `previous`, `run.sh` e `user/`.
/// `user/` é a pasta portátil (config, saves, chaves): o emulador a usa porque o `run.sh` entra na pasta
/// antes de abrir (`path_util.cpp`: `./user` vence `~/.local/share/eden`). É do usuário e só sai com pedido.
public enum AppImages {
    public static let base = ".local/share/quietdeck/emulators"

    public struct Status: Equatable, Sendable {
        public var current: String?
        public var previous: String?
        public var isInstalled: Bool { current != nil }

        public init(current: String? = nil, previous: String? = nil) {
            self.current = current
            self.previous = previous
        }
    }

    public enum Outcome: Equatable, Sendable { case done, alreadyInstalled, notInstalled, nothingToRollBack }

    public static func root(home: String, id: String) -> String { "\(home)/\(base)/\(id)" }
    public static func launcher(home: String, id: String) -> String { root(home: home, id: id) + "/run.sh" }

    static func buildNumber(_ tag: String, prefix: String) -> Int? {
        guard tag.hasPrefix(prefix), let n = Int(tag.dropFirst(prefix.count)), n > 0 else { return nil }
        return n
    }

    /// `sha256:<hex>` do GitHub. Sem ele não há o que conferir, e a release não é instalável.
    static func sha256(_ asset: GitHubAsset) -> String? {
        guard let d = asset.digest?.lowercased(), d.hasPrefix("sha256:") else { return nil }
        let hex = d.dropFirst(7)
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit) ? String(hex) : nil
    }

    /// A tag vira nome de pasta no Deck.
    static func isSafeTag(_ tag: String) -> Bool {
        tag.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil && !tag.contains("..")
    }

    /// A release de maior número que traz o asset com digest.
    public static func latest(_ releases: [GitHubRelease], source: AppImageSource) -> (tag: String, asset: GitHubAsset)? {
        releases.compactMap { release -> (Int, String, GitHubAsset)? in
            guard let n = buildNumber(release.tag_name, prefix: source.tagPrefix),
                  let asset = release.assets.first(where: { $0.name == source.asset }), sha256(asset) != nil else { return nil }
            return (n, release.tag_name, asset)
        }.max { $0.0 < $1.0 }.map { ($0.1, $0.2) }
    }

    public static func releases(_ source: AppImageSource) async throws -> [GitHubRelease] {
        try await PublicAPI.get("https://api.github.com/repos/\(source.repo)/releases?per_page=30")
    }

    static func statusScript(root: String) -> String {
        let r = Shell.quote(root)
        return "for l in current previous; do if [ -L \(r)/$l ]; then t=$(readlink \(r)/$l); if [ -d \(r)/\"$t\" ]; then echo \"$l $t\"; fi; fi; done"
    }

    /// Link que não aponta para `versions/<tag>` existente não conta como instalado.
    static func parseStatus(_ text: String) -> Status {
        var status = Status()
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[1].hasPrefix("versions/") else { continue }
            let tag = String(parts[1].dropFirst("versions/".count))
            guard isSafeTag(tag) else { continue }
            if parts[0] == "current" { status.current = tag } else if parts[0] == "previous" { status.previous = tag }
        }
        return status
    }

    public static func status(_ emulator: Emulator, runner: any CommandRunner) async throws -> Status {
        let home = try await RemoteFiles(runner: runner).home()
        return parseStatus(try await runner.check(statusScript(root: root(home: home, id: emulator.id))).stdout)
    }

    /// O runtime do AppImage põe `APPIMAGE=<caminho real>` no ambiente do emulador. Só processos do
    /// próprio usuário: os do root não são legíveis, e o grep de um processo que acabou de sair falha sem importar.
    static func runningScript(root: String) -> String {
        let pattern = Shell.quote("^APPIMAGE=" + root + "/versions/")
        return "for p in $(pgrep -u \"$(id -u)\"); do if grep -qsz \(pattern) /proc/$p/environ; then echo $p; fi; done"
    }

    public static func isOpen(_ emulator: Emulator, runner: any CommandRunner) async throws -> Bool {
        let home = try await RemoteFiles(runner: runner).home()
        return !(try await runner.check(runningScript(root: root(home: home, id: emulator.id))).trimmed.isEmpty)
    }

    /// Abre o AppImage que estiver em `current`, sem fixar o nome: a versão anterior pode ter outro asset
    /// (a troca para o build com PGO), e voltar para ela não pode quebrar o atalho.
    static let launcherScript = """
        #!/bin/sh
        # QuietDeck: abre o emulador com a pasta portátil ./user. Regravado a cada instalação.
        cd "$(dirname "$0")" || exit 1
        for f in ./current/*.AppImage; do exec "$f" "$@"; done
        echo "QuietDeck: nenhum AppImage em current" >&2
        exit 1

        """

    /// Baixa em `versions/.<tag>.partial` (retoma depois de queda), confere o sha256 e só então renomeia
    /// para `versions/<tag>`. A troca de `current` é um `mv -T` de symlink, atômica; o anterior vira `previous`.
    /// Ficam só as duas versões. Hash errado apaga o parcial e sai com 41.
    static func installScript(root: String, tag: String, asset: GitHubAsset, sha256: String) -> String {
        let q = Shell.quote
        let size = asset.size.map(String.init) ?? ""
        return """
        set -eu
        R=\(q(root)); T=\(q(tag)); A=\(q(asset.name)); SHA=\(q(sha256)); URL=\(q(asset.browser_download_url)); SIZE=\(q(size))
        mkdir -p "$R/versions" "$R/user"
        V="$R/versions/$T"
        if [ -d "$V" ] && ! echo "$SHA  $V/$A" | sha256sum -c --status; then rm -rf "$V"; fi
        if [ ! -d "$V" ]; then
          S="$R/versions/.$T.partial"
          mkdir -p "$S"
          if [ -z "$SIZE" ]; then rm -f "$S/$A"; fi
          if [ ! -f "$S/$A" ] || [ "$(stat -c %s "$S/$A")" != "$SIZE" ]; then curl -fL --retry 3 -C - -o "$S/$A" "$URL"; fi
          if ! echo "$SHA  $S/$A" | sha256sum -c --status; then rm -rf "$S"; echo "checksum mismatch: $A" >&2; exit 41; fi
          chmod 755 "$S/$A"
          mv -T "$S" "$V"
        fi
        C=""
        if [ -L "$R/current" ]; then C=$(readlink "$R/current"); fi
        if [ -n "$C" ] && [ "$C" != "versions/$T" ] && [ -d "$R/$C" ]; then ln -sfn "$C" "$R/.previous" && mv -T "$R/.previous" "$R/previous"; fi
        ln -sfn "versions/$T" "$R/.current" && mv -T "$R/.current" "$R/current"
        P=""
        if [ -L "$R/previous" ]; then P=$(readlink "$R/previous"); fi
        for d in "$R"/versions/* "$R"/versions/.*.partial; do
          if [ ! -d "$d" ]; then continue; fi
          n="versions/${d##*/}"
          if [ "$n" != "versions/$T" ] && [ "$n" != "$P" ]; then rm -rf "$d"; fi
        done
        """
    }

    public static func install(_ emulator: Emulator, tag: String, asset: GitHubAsset, runner: any CommandRunner,
                               onOutput: LocalProcess.Output? = nil) async throws -> Outcome {
        guard let source = emulator.appImage, asset.name == source.asset, CompatTools.isSafeName(asset.name), isSafeTag(tag) else {
            throw DeckError.unexpectedState("This release can't be installed: %@", tag)
        }
        guard let sha = sha256(asset) else { throw DeckError.unexpectedState("%@ has no published checksum, so it wasn't installed.", tag) }
        if try await status(emulator, runner: runner).current == tag { return .alreadyInstalled }
        if try await isOpen(emulator, runner: runner) { throw DeckError.unexpectedState("Close %@ first.", emulator.name) }
        let files = RemoteFiles(runner: runner)
        let home = try await files.home()
        let dir = root(home: home, id: emulator.id)
        try await files.ensureSpace(asset.size ?? 0, in: dir)
        let r = try await runner.run(RemoteCommand(installScript(root: dir, tag: tag, asset: asset, sha256: sha), timeout: 3600), onOutput: onOutput)
        if r.exitCode == 41 { throw DeckError.unexpectedState("The download of %@ didn't match its published checksum. Nothing was changed.", tag) }
        guard r.ok else { throw DeckError.commandFailed(command: "install \(emulator.id) \(tag)", result: r) }
        try await files.write(Data(launcherScript.utf8), to: dir + "/run.sh")
        try await runner.check("chmod 755 \(Shell.quote(dir + "/run.sh"))")
        guard try await status(emulator, runner: runner).current == tag else {
            throw DeckError.unexpectedState("Installing %@ finished, but the active version didn't change.", emulator.name)
        }
        return .done
    }

    /// Troca `current` e `previous`: repetir volta para a mais nova.
    public static func rollback(_ emulator: Emulator, runner: any CommandRunner) async throws -> Outcome {
        let before = try await status(emulator, runner: runner)
        guard let current = before.current else { return .notInstalled }
        guard let previous = before.previous else { return .nothingToRollBack }
        if try await isOpen(emulator, runner: runner) { throw DeckError.unexpectedState("Close %@ first.", emulator.name) }
        let dir = Shell.quote(root(home: try await RemoteFiles(runner: runner).home(), id: emulator.id))
        try await runner.check("""
        ln -sfn \(Shell.quote("versions/" + previous)) \(dir)/.current && mv -T \(dir)/.current \(dir)/current && \
        ln -sfn \(Shell.quote("versions/" + current)) \(dir)/.previous && mv -T \(dir)/.previous \(dir)/previous
        """)
        guard try await status(emulator, runner: runner) == Status(current: previous, previous: current) else {
            throw DeckError.unexpectedState("Rolling back %@ finished, but the active version didn't change.", emulator.name)
        }
        return .done
    }

    /// Sem `keepData`, apaga também `user/` (config, saves e chaves deste emulador). Nada fora da pasta dele é tocado.
    public static func remove(_ emulator: Emulator, keepData: Bool, runner: any CommandRunner) async throws -> Outcome {
        let home = try await RemoteFiles(runner: runner).home()
        let dir = root(home: home, id: emulator.id)
        guard try await runner.run("test -d \(Shell.quote(dir))").ok else { return .notInstalled }
        if try await isOpen(emulator, runner: runner) { throw DeckError.unexpectedState("Close %@ first.", emulator.name) }
        let r = Shell.quote(dir)
        var script = "rm -rf \(r)/versions \(r)/current \(r)/previous \(r)/.current \(r)/.previous \(r)/run.sh"
        if !keepData { script += " \(r)/user" }
        script += " && if [ -z \"$(ls -A \(r))\" ]; then rmdir \(r); fi"
        try await runner.check(script)
        guard try await !status(emulator, runner: runner).isInstalled else {
            throw DeckError.unexpectedState("Removing %@ finished, but it's still installed.", emulator.name)
        }
        return .done
    }
}
