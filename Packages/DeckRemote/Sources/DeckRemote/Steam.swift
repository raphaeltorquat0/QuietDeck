import Foundation
import DeckKit

/// Parar o Steam, gravar o VDF e subir de novo sem perder a gravação.
///
/// Dois fatos mandam aqui: o Steam regrava `shortcuts.vdf` da memória ao sair, então só se grava com
/// ele morto, e no Game Mode `gamescope-session.target` tem `Upholds=steam-launcher.service`, que o
/// relança na hora. Por isso a unidade é mascarada em `/run` antes de parar: o máscara some sozinho
/// num reboot, e um app que cair no meio não deixa o Deck sem Steam para sempre.
public struct SteamControl: Sendable {
    public let runner: any CommandRunner
    public var pollInterval: Duration = .seconds(1)
    public var stopTimeoutPolls = 75
    public var startTimeoutPolls = 90

    public init(runner: any CommandRunner) { self.runner = runner }

    static let unit = "steam-launcher.service"
    static let isRunning = "pgrep -x steam >/dev/null"
    static let isGameOpen = "ps -eo args | grep -q '[r]eaper SteamLaunch'"
    static let mask = DeviceProbe.userBus + "systemctl --user mask --runtime \(unit)"
    static let unmask = DeviceProbe.userBus + "systemctl --user unmask --runtime \(unit)"
    static let stopUnit = DeviceProbe.userBus + "systemctl --user stop \(unit)"
    static let startUnit = DeviceProbe.userBus + "systemctl --user start \(unit)"
    static let restartUnit = DeviceProbe.userBus + "systemctl --user restart \(unit)"
    static let term = "pkill -TERM -x steam"
    /// O ambiente gráfico (Wayland no 3.9, `XAUTHORITY` com nome aleatório) só existe no `systemd --user`.
    static let startDesktop = DeviceProbe.userBus + "systemd-run --user --collect --quiet steam -silent"

    public static let userList = "ls -1t ~/.local/share/Steam/userdata 2>/dev/null"

    /// Mais recente primeiro; `0` é o usuário anônimo do Steam.
    public static func parseUsers(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty && $0 != "0" && $0.allSatisfy(\.isNumber) }
    }

    public func users() async throws -> [String] {
        Self.parseUsers(try await runner.run(Self.userList).stdout)
    }

    public func configDirectory(user: String) async throws -> String {
        try await RemoteFiles(runner: runner).home() + "/.local/share/Steam/userdata/\(user)/config"
    }

    public func running() async throws -> Bool { try await runner.run(Self.isRunning).ok }
    public func gameOpen() async throws -> Bool { try await runner.run(Self.isGameOpen).ok }

    func wait(untilRunning target: Bool, polls: Int) async throws -> Bool {
        for _ in 0..<polls {
            if try await running() == target { return true }
            try await Task.sleep(for: pollInterval)
        }
        return false
    }

    public struct WriteResult: Equatable, Sendable {
        public var added: [Shortcut]
        public var backup: String?
    }

    public func hasShortcuts(user: String) async throws -> Bool {
        let path = try await configDirectory(user: user) + "/shortcuts.vdf"
        let root = try ShortcutsFile.parse(try await RemoteFiles(runner: runner).read(path) ?? Data())
        return !ShortcutsFile.existing(in: root).isEmpty
    }

    /// Lê antes de tudo: sem nada novo, não encosta no Steam nem fecha o jogo de ninguém.
    public func addShortcuts(_ shortcuts: [Shortcut], user: String) async throws -> WriteResult {
        var added: [Shortcut] = []
        let edited = try await edit(user: user) { root in
            let merged = try ShortcutsFile.merge(shortcuts, into: root)
            added = merged.added
            return merged.added.isEmpty ? nil : merged.root
        }
        guard let edited else { return WriteResult(added: [], backup: nil) }
        let names = try await currentNames(user: user)
        guard added.allSatisfy({ names.contains($0.name) }) else {
            throw DeckError.unexpectedState("Steam overwrote shortcuts.vdf while restarting. Restore %@ and try again.", edited.path ?? "the backup")
        }
        return WriteResult(added: added, backup: edited.path)
    }

    /// Nome do atalho → último jogo, para sugerir o que remover quando faltar espaço.
    public func lastPlayed(user: String) async throws -> [String: Int64] {
        let path = try await configDirectory(user: user) + "/shortcuts.vdf"
        let root = try ShortcutsFile.parse(try await RemoteFiles(runner: runner).read(path) ?? Data())
        return Dictionary(ShortcutsFile.existing(in: root).map { ($0.name, $0.lastPlayed) }, uniquingKeysWith: max)
    }

    public func removeShortcuts(names: [String], user: String) async throws -> Bool {
        try await edit(user: user) { root in
            let result = ShortcutsFile.remove(names: names, from: root)
            return result.removed == 0 ? nil : result.root
        } != nil
    }

    /// Atalhos do QuietDeck com ROM apagada saem e o resto ganha o nome limpo. Sem mudança, o Steam
    /// nem é tocado; com jogo aberto, fica para a próxima vez (reiniciar o Steam fecharia o jogo).
    public func tidyShortcuts(user: String) async throws -> (removed: Int, renamed: Int)? {
        let path = try await configDirectory(user: user) + "/shortcuts.vdf"
        let all = ShortcutsFile.existing(in: try ShortcutsFile.parse(try await RemoteFiles(runner: runner).read(path) ?? Data()))
        let roms = all.filter(\.isEmulatorGame).compactMap(\.romPath)
        guard !roms.isEmpty else { return (0, 0) }
        let check = roms.map { "[ -e \(Shell.quote($0)) ] || printf '%s\\n' \(Shell.quote($0))" }.joined(separator: "; ")
        let missing = Set(try await runner.check(check).stdout.split(whereSeparator: \.isNewline).map(String.init))
        let plan = ShortcutsFile.tidyPlan(all, missing: missing)
        guard !plan.remove.isEmpty || !plan.rename.isEmpty else { return (0, 0) }
        if try await gameOpen() { return nil }
        var removed = 0, renamed = 0
        _ = try await edit(user: user) { root in
            let r = ShortcutsFile.remove(names: plan.remove, from: root)
            let n = ShortcutsFile.rename(plan.rename, in: r.root)
            removed = r.removed
            renamed = n.renamed
            return removed + renamed == 0 ? nil : n.root
        }
        return (removed, renamed)
    }

    private func currentNames(user: String) async throws -> Set<String> {
        let path = try await configDirectory(user: user) + "/shortcuts.vdf"
        guard let data = try await RemoteFiles(runner: runner).read(path) else {
            throw DeckError.unexpectedState("shortcuts.vdf disappeared after restarting Steam.")
        }
        return Set(ShortcutsFile.existing(in: try VDF.parse(data)).map(\.name))
    }

    struct Edited { var path: String? }

    /// Para o Steam, aplica `change` no arquivo já regravado por ele e sobe de novo.
    /// `change` devolve `nil` quando não há o que fazer, e aí o Steam nem é tocado.
    private func edit(user: String, change: (VDFValue) throws -> VDFValue?) async throws -> Edited? {
        let files = RemoteFiles(runner: runner)
        let path = try await configDirectory(user: user) + "/shortcuts.vdf"
        guard try change(try ShortcutsFile.parse(try await files.read(path) ?? Data())) != nil else { return nil }
        // Gravar exige reiniciar o Steam, o que fecharia o jogo: quem pode esperar (Add to Steam) espera antes.
        if try await gameOpen() { throw DeckError.unexpectedState("A game is open on the Deck. Close it and try again.") }

        let mode = try await sessionMode()
        let wasRunning = try await running()
        if mode == .game { try await runner.check(Self.mask) }
        do {
            if mode == .game { _ = try await runner.run(RemoteCommand(Self.stopUnit, timeout: 75), onOutput: nil) }
            if wasRunning || mode == .game { _ = try await runner.run(Self.term) }
            guard try await wait(untilRunning: false, polls: stopTimeoutPolls) else {
                throw DeckError.unexpectedState("Steam didn't stop, so shortcuts.vdf was left untouched.")
            }
            // Só agora o arquivo é definitivo: o Steam acabou de regravá-lo ao sair.
            let current = try await files.read(path)
            let root = try ShortcutsFile.parse(current ?? Data())
            let updated = try change(root) ?? root
            let backup = path + ".quietdeck-\(Int(Date().timeIntervalSince1970)).bak"
            if current != nil { try await runner.check("cp -p \(Shell.quote(path)) \(Shell.quote(backup)) && ls -1t \(Shell.quote(path)).quietdeck-*.bak | tail -n +11 | xargs -r -d '\\n' rm -f") }
            let bytes = VDF.serialize(updated)
            if try await running() { throw DeckError.unexpectedState("Steam came back before the write, so shortcuts.vdf was left untouched.") }
            try await files.write(bytes, to: path)
            guard try await files.read(path) == bytes else { throw DeckError.unexpectedState("shortcuts.vdf on the Deck doesn't match what was written.") }
            try await startAgain(mode: mode, wasRunning: wasRunning)
            return Edited(path: current == nil ? nil : backup)
        } catch {
            if mode == .game { _ = try? await runner.run(Self.unmask) }
            _ = try? await startAgain(mode: mode, wasRunning: wasRunning)
            throw error
        }
    }

    func sessionMode() async throws -> SessionMode {
        SessionMode(rawValue: try await runner.check(DeviceProbe.session).trimmed) ?? .unknown
    }

    private func startAgain(mode: SessionMode, wasRunning: Bool) async throws {
        if mode == .game {
            try await runner.check(Self.unmask)
            try await runner.check(RemoteCommand(Self.startUnit, timeout: 30))
        } else if wasRunning {
            try await runner.check(Self.startDesktop)
        } else {
            return
        }
        guard try await wait(untilRunning: true, polls: startTimeoutPolls) else {
            throw DeckError.unexpectedState("Steam didn't come back. Check the Deck's screen.")
        }
    }

    /// Fecha o jogo aberto: a UI só chama isto depois de confirmar.
    public func restart() async throws {
        let mode = try await sessionMode()
        if mode == .game {
            try await runner.check(RemoteCommand(Self.restartUnit, timeout: 90))
        } else {
            _ = try await runner.run(Self.term)
            guard try await wait(untilRunning: false, polls: stopTimeoutPolls) else {
                throw DeckError.unexpectedState("Steam didn't stop.")
            }
            try await runner.check(Self.startDesktop)
        }
        guard try await wait(untilRunning: true, polls: startTimeoutPolls) else {
            throw DeckError.unexpectedState("Steam didn't come back. Check the Deck's screen.")
        }
    }
}

public enum Art {
    public static func script(url: String, kind: ArtKind, appID: UInt32, gridDirectory: String) -> String {
        let ext = (URL(string: url)?.pathExtension.lowercased()).flatMap { ["png", "jpg", "jpeg", "webp", "ico"].contains($0) ? $0 : nil } ?? "png"
        let dest = gridDirectory + "/" + kind.fileName(appID: appID, extension: ext)
        return "mkdir -p \(Shell.quote(gridDirectory)) && curl -fsSL -o \(Shell.quote(dest + ".tmp")) \(Shell.quote(url)) && mv -f \(Shell.quote(dest + ".tmp")) \(Shell.quote(dest))"
    }
}

public enum QuickAction: String, Codable, CaseIterable, Sendable {
    case restartSteam, switchToGameMode, reboot, powerOff

    public var title: String {
        switch self {
        case .restartSteam: "Restart Steam"
        case .switchToGameMode: "Switch to Game Mode"
        case .reboot: "Reboot"
        case .powerOff: "Shut Down"
        }
    }

    public var closesRunningGame: Bool { true }

    public func run(_ runner: any CommandRunner, password: String?) async throws {
        switch self {
        case .restartSteam: try await SteamControl(runner: runner).restart()
        case .switchToGameMode:
            if try await SteamControl(runner: runner).sessionMode() == .game { return }
            // `steamos-session-select` virou um wrapper obsoleto do `steamosctl`, mas segue em imagens antigas.
            try await runner.check(DeviceProbe.userBus + "if command -v steamosctl >/dev/null; then steamosctl set-default-login-mode game; steamosctl switch-to-game-mode; else steamos-session-select gamescope; fi")
        case .reboot, .powerOff:
            guard let password else { throw DeckError.sudoPasswordMissing }
            // A conexão cai junto; exit 255 aqui é o sucesso esperado.
            do { try await runner.check(.sudo(self == .reboot ? "systemctl reboot" : "systemctl poweroff", password: password)) }
            catch DeckError.unreachable { return }
        }
    }
}
