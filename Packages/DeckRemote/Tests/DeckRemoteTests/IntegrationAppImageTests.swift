import Foundation
import Testing
import DeckKit
@testable import DeckRemote

extension IntegrationTests {
    static let appImageName = "lichii-linux-x86_64-deck.AppImage"
    static let appImageRoot = "/home/deck/.local/share/quietdeck/emulators/lichii"

    /// AppImage falso servido por `file://`: como o runtime de verdade, põe `APPIMAGE=<caminho real>` no
    /// ambiente; grava a pasta atual e os argumentos que recebeu.
    func fakeAppImage(_ n: Int, runner r: SSHRunner) async throws -> GitHubAsset {
        let dir = "/tmp/li/build-\(n)", file = "/tmp/li/build-\(n)/" + Self.appImageName
        let script = """
        #!/bin/sh
        export APPIMAGE="$(readlink -f "$0")"
        if [ "$1" = "--hold" ]; then exec sleep 60; fi
        { pwd; printf '%s\\n' "$@"; } > "$HOME/.cache/qd-lichii-args"
        # build \(n)

        """
        try await r.check(RemoteCommand("mkdir -p \(dir) && cat > \(file)", stdin: Data(script.utf8), timeout: 30))
        let sha = try await r.check("sha256sum \(file) | cut -d' ' -f1").trimmed
        let size = try #require(Int64(try await r.check("stat -c %s \(file)").trimmed))
        return GitHubAsset(name: Self.appImageName, browser_download_url: "file://" + file, digest: "sha256:" + sha, size: size)
    }

    /// Instalação anterior com o asset sem PGO: atualizar para o PGO e voltar mantém o atalho abrindo.
    @Test func appImageRollbackAcrossAssetNames() async throws {
        let r = try await Sim.runner()
        let lichii = try #require(try Catalog.load().emulator("lichii"))
        let root = Self.appImageRoot
        let old = "\(root)/versions/build-0/lichii-linux-x86_64.AppImage"
        try await r.check("rm -rf \(root) /tmp/li ~/.cache/qd-lichii-args && mkdir -p ~/.cache \(root)/versions/build-0 \(root)/user")
        try await r.check(RemoteCommand("cat > \(old) && chmod 755 \(old) && ln -s versions/build-0 \(root)/current",
                                        stdin: Data("#!/bin/sh\necho old > \"$HOME/.cache/qd-lichii-args\"\n".utf8), timeout: 30))
        #expect(try await AppImages.install(lichii, tag: "build-1", asset: try await fakeAppImage(1, runner: r), runner: r) == .done)
        try await r.check("\(root)/run.sh -f")
        #expect(try await r.check("head -1 ~/.cache/qd-lichii-args").trimmed == root)
        #expect(try await AppImages.rollback(lichii, runner: r) == .done)
        try await r.check("\(root)/run.sh -f")
        #expect(try await r.check("cat ~/.cache/qd-lichii-args").trimmed == "old")
        try await r.check("rm -rf \(root) /tmp/li ~/.cache/qd-lichii-args")
    }

    @Test func appImageInstallUpdateRollbackAndRemove() async throws {
        let r = try await Sim.runner()
        let lichii = try #require(try Catalog.load().emulator("lichii"))
        let root = Self.appImageRoot
        try await r.check("rm -rf \(root) /tmp/li ~/.cache/qd-lichii-args && mkdir -p ~/.cache")
        func status() async throws -> AppImages.Status { try await AppImages.status(lichii, runner: r) }
        func versions() async throws -> String { try await r.check("ls -A \(root)/versions | tr '\\n' ' '").trimmed }

        // Primeira instalação, e repetir não refaz nada.
        let a1 = try await fakeAppImage(1, runner: r)
        #expect(try await AppImages.install(lichii, tag: "build-1", asset: a1, runner: r) == .done)
        #expect(try await status() == .init(current: "build-1"))
        #expect(try await AppImages.install(lichii, tag: "build-1", asset: a1, runner: r) == .alreadyInstalled)
        #expect(try await r.run("test -x \(root)/run.sh && test -d \(root)/user").ok)

        // O atalho chama o run.sh de qualquer pasta: ele entra na dele, onde está `user/`, e repassa os argumentos.
        let rom = "/home/deck/Emulation/roms/switch2/A Game (v1).xci"
        try await r.check("cd / && \(root)/run.sh -f -g \(Shell.quote(rom))")
        #expect(try await r.check("cat ~/.cache/qd-lichii-args").stdout == "\(root)\n-f\n-g\n\(rom)\n")

        // Hash errado: falha com mensagem própria, sem parcial nem troca de versão.
        let a2 = try await fakeAppImage(2, runner: r)
        var forged = a2
        forged.digest = a1.digest
        await #expect(throws: DeckError.unexpectedState("The download of %@ didn't match its published checksum. Nothing was changed.", "build-2")) {
            try await AppImages.install(lichii, tag: "build-2", asset: forged, runner: r)
        }
        #expect(try await status() == .init(current: "build-1"))
        #expect(try await versions() == "build-1")
        var unsigned = a2
        unsigned.digest = nil
        await #expect(throws: DeckError.self) { try await AppImages.install(lichii, tag: "build-2", asset: unsigned, runner: r) }

        // Download que caiu no meio retoma do parcial.
        try await r.check("mkdir -p \(root)/versions/.build-2.partial && head -c 20 /tmp/li/build-2/\(Self.appImageName) > \(root)/versions/.build-2.partial/\(Self.appImageName)")
        #expect(try await AppImages.install(lichii, tag: "build-2", asset: a2, runner: r) == .done)
        #expect(try await status() == .init(current: "build-2", previous: "build-1"))

        // Rollback troca as duas e preserva os saves.
        try await r.check("mkdir -p \(root)/user/nand/user/save/0 && echo slot > \(root)/user/nand/user/save/0/data")
        #expect(try await AppImages.rollback(lichii, runner: r) == .done)
        #expect(try await status() == .init(current: "build-1", previous: "build-2"))
        #expect(try await AppImages.rollback(lichii, runner: r) == .done)
        #expect(try await status() == .init(current: "build-2", previous: "build-1"))

        // Terceira versão: fica só ela e a anterior.
        let a3 = try await fakeAppImage(3, runner: r)
        #expect(try await AppImages.install(lichii, tag: "build-3", asset: a3, runner: r) == .done)
        #expect(try await status() == .init(current: "build-3", previous: "build-2"))
        #expect(try await versions() == "build-2 build-3")

        // Aberto: nada troca nem sai.
        try await r.check("cd / && (setsid \(root)/run.sh --hold > /dev/null 2>&1 &) && sleep 1")
        #expect(try await AppImages.isOpen(lichii, runner: r))
        await #expect(throws: DeckError.unexpectedState("Close %@ first.", "Lichii")) { try await AppImages.rollback(lichii, runner: r) }
        await #expect(throws: DeckError.self) { try await AppImages.remove(lichii, keepData: true, runner: r) }
        let pids = try await r.check(AppImages.runningScript(root: root)).trimmed
        try await r.check("kill \(pids.split(whereSeparator: \.isNewline).joined(separator: " ")) && sleep 1")
        #expect(try await !AppImages.isOpen(lichii, runner: r))

        // Sem espaço e download que falha: erro, e a versão ativa continua a mesma.
        var huge = try await fakeAppImage(4, runner: r)
        huge.size = 1 << 50
        await #expect(throws: DeckError.self) { try await AppImages.install(lichii, tag: "build-4", asset: huge, runner: r) }
        var missing = huge
        missing.size = 10
        missing.browser_download_url = "file:///tmp/li/none/" + Self.appImageName
        await #expect(throws: DeckError.self) { try await AppImages.install(lichii, tag: "build-4", asset: missing, runner: r) }
        #expect(try await status() == .init(current: "build-3", previous: "build-2"))

        // Remover mantendo os dados: o programa sai, os saves ficam e voltam com a próxima instalação.
        #expect(try await AppImages.remove(lichii, keepData: true, runner: r) == .done)
        #expect(try await r.check("cat \(root)/user/nand/user/save/0/data").stdout == "slot\n")
        #expect(try await !r.run("test -e \(root)/run.sh").ok)
        #expect(try await AppImages.install(lichii, tag: "build-3", asset: a3, runner: r) == .done)
        #expect(try await r.check("cat \(root)/user/nand/user/save/0/data").stdout == "slot\n")

        // Remover tudo apaga só a pasta do Lichii.
        try await r.check("mkdir -p ~/.local/share/quietdeck/emulators/other && echo keep > ~/.local/share/quietdeck/emulators/other/x")
        #expect(try await AppImages.remove(lichii, keepData: false, runner: r) == .done)
        #expect(try await !r.run("test -e \(root)").ok)
        #expect(try await r.check("cat ~/.local/share/quietdeck/emulators/other/x").stdout == "keep\n")
        #expect(try await AppImages.remove(lichii, keepData: false, runner: r) == .notInstalled)
        try await r.check("rm -rf ~/.local/share/quietdeck/emulators/other /tmp/li ~/.cache/qd-lichii-args")
    }

    /// Chaves vão do Ryubing para `user/keys`; uma chave diferente que já estava lá fica num backup.
    @Test func lichiiReceivesKeysWithBackup() async throws {
        let r = try await Sim.runner()
        let ryu = "~/.var/app/io.github.ryubing.Ryujinx/config/Ryujinx/system"
        let keys = Self.appImageRoot + "/user/keys"
        try await r.check("rm -rf \(Self.appImageRoot) && mkdir -p \(ryu) && echo new > \(ryu)/prod.keys && rm -f \(ryu)/title.keys")
        try await SwitchKeys.prepareLichii(runner: r)
        #expect(try await r.check("cat \(keys)/prod.keys; stat -c %a \(keys)/prod.keys \(keys)").stdout == "new\n600\n700\n")
        #expect(try await !r.run("test -e \(keys)/title.keys").ok)
        try await r.check("echo own > \(keys)/prod.keys")
        try await SwitchKeys.prepareLichii(runner: r)
        #expect(try await r.check("cat \(keys)/prod.keys \(keys)/prod.keys.quietdeck-backup").stdout == "new\nown\n")
        try await r.check("rm -rf \(Self.appImageRoot)")
    }
}
