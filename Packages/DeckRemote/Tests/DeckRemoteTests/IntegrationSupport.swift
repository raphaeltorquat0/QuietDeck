import Foundation
import Testing
import DeckKit
@testable import DeckRemote

/// Contra o Deck simulado de `Harness/` (`make integration`). Sem `QUIETDECK_TEST_HOST`, ficam desligados.
enum Sim {
    static let env = ProcessInfo.processInfo.environment
    static let enabled = env["QUIETDECK_TEST_HOST"] != nil
    static let host = env["QUIETDECK_TEST_HOST"] ?? "127.0.0.1"
    static let port = Int(env["QUIETDECK_TEST_PORT"] ?? "2222") ?? 2222
    static let password = env["QUIETDECK_TEST_PASSWORD"] ?? "deck-password"
    /// Só no harness: o QEMU roda SteamOS de verdade e não tem Steam falso nem `deck-sim`.
    static let hasHarness = env["QUIETDECK_TEST_REAL_OS"] == nil
    static let flatpak = env["QUIETDECK_TEST_FLATPAK"] ?? "org.quietdeck.Hello"
    static let user = "12345"
    static let vdf = "/home/deck/.local/share/Steam/userdata/12345/config/shortcuts.vdf"

    static let dir: URL = {
        let d = URL(fileURLWithPath: "/tmp/qd-it-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return d
    }()
    static let config = SSHConfig(host: host, port: port, identityFile: dir.appendingPathComponent("key").path,
                                  knownHostsFile: dir.appendingPathComponent("known hosts").path)

    /// Primeiro uso pareia de verdade, com senha; o resto já entra por chave.
    static let pairing = Task<SSHRunner, Error> {
        try await Pairing.ensureKey(at: config.identityFile)
        try await Pairing.installKey(config: config, password: password)
        return SSHRunner(config: config)
    }

    static func runner() async throws -> SSHRunner { try await pairing.value }
    static func shortcutNames(_ r: SSHRunner) async throws -> [String] {
        let data = try await RemoteFiles(runner: r).read(vdf) ?? Data()
        return ShortcutsFile.existing(in: try VDF.parse(data)).map(\.name)
    }
    static func steam(_ r: SSHRunner) -> SteamControl {
        var s = SteamControl(runner: r)
        s.pollInterval = .milliseconds(100)
        return s
    }
    static func waitForSteam(_ r: SSHRunner) async throws {
        _ = try await steam(r).wait(untilRunning: true, polls: 100)
    }
    /// Um ciclo completo do Steam: se o que está na memória dele não tem a entrada, o arquivo perde aqui.
    static func cycleSteam(_ r: SSHRunner) async throws {
        try await r.check("pkill -TERM -x steam")
        try await Task.sleep(for: .milliseconds(1200))
        try await waitForSteam(r)
    }
    static func tempFile(_ name: String, bytes: Int) throws -> URL {
        let d = dir.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let f = d.appendingPathComponent(name)
        try Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ bytes) }).write(to: f)
        return f
    }
}

@Suite("Integration", .serialized, .enabled(if: Sim.enabled)) struct IntegrationTests {}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    var value: T? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Faz o `df` falso de `~/bin` valer, sem tocar no PATH do Deck simulado.
struct PathRunner: CommandRunner {
    let base: any CommandRunner
    func run(_ command: RemoteCommand, onOutput: LocalProcess.Output?) async throws -> CommandResult {
        var c = command
        c.script = "PATH=$HOME/bin:$PATH; " + c.script
        return try await base.run(c, onOutput: onOutput)
    }
}
