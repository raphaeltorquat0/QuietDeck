import Foundation
import DeckKit

/// Um comando para o shell do Deck. `stdin` nunca é gravado pelo record/replay: pode ser a senha.
public struct RemoteCommand: Sendable, Equatable {
    public var script: String
    public var stdin: Data?
    public var timeout: TimeInterval

    public init(_ script: String, stdin: Data? = nil, timeout: TimeInterval = 30) {
        self.script = script
        self.stdin = stdin
        self.timeout = timeout
    }

    /// `sudo -S` lê a senha da entrada padrão; ela nunca aparece em argv nem no `ps` do Deck.
    public static func sudo(_ script: String, password: String, timeout: TimeInterval = 120) -> RemoteCommand {
        RemoteCommand("sudo -S -p '' sh -c \(Shell.quote(script))",
                      stdin: Data((password + "\n").utf8), timeout: timeout)
    }
}

public enum DeckError: Error, Equatable, CustomStringConvertible {
    case unreachable(String)
    case authenticationFailed(String)
    case sudoRejected
    case sudoPasswordMissing
    case commandFailed(command: String, result: CommandResult)
    case unexpectedState(String)

    public var description: String {
        switch self {
        case let .unreachable(m): "Couldn't reach the Deck: \(m)"
        case let .authenticationFailed(m): "The Deck refused the login: \(m)"
        case .sudoRejected: "The Deck refused the sudo password."
        case .sudoPasswordMissing: "This action needs the password of the deck user."
        case let .commandFailed(c, r):
            "Command failed (\(r.exitCode)): \(c.prefix(120))\n\(r.stderr.suffix(500))"
        case let .unexpectedState(m): m
        }
    }
}

public protocol CommandRunner: Sendable {
    func run(_ command: RemoteCommand, onOutput: LocalProcess.Output?) async throws -> CommandResult
}

extension CommandRunner {
    public func run(_ script: String, timeout: TimeInterval = 30) async throws -> CommandResult {
        try await run(RemoteCommand(script, timeout: timeout), onOutput: nil)
    }

    /// Para o que precisa ter dado certo: exit ≠ 0 vira erro com o comando e o stderr.
    @discardableResult
    public func check(_ command: RemoteCommand, onOutput: LocalProcess.Output? = nil) async throws -> CommandResult {
        let r = try await run(command, onOutput: onOutput)
        guard r.ok else {
            if command.script.hasPrefix("sudo -S"), r.stderr.contains("incorrect password") || r.stderr.contains("Sorry, try again") {
                throw DeckError.sudoRejected
            }
            throw DeckError.commandFailed(command: command.script, result: r)
        }
        return r
    }

    @discardableResult
    public func check(_ script: String, timeout: TimeInterval = 30) async throws -> CommandResult {
        try await check(RemoteCommand(script, timeout: timeout))
    }
}

public struct SSHConfig: Codable, Hashable, Sendable {
    public var host: String
    public var port: Int
    public var user: String
    public var identityFile: String
    public var knownHostsFile: String

    public init(host: String, port: Int = 22, user: String = "deck",
                identityFile: String, knownHostsFile: String) {
        self.host = host
        self.port = port
        self.user = user
        self.identityFile = identityFile
        self.knownHostsFile = knownHostsFile
    }

    public var destination: String { "\(user)@\(host)" }

    /// Sockets Unix têm limite de 104 bytes no macOS; `%C` é um hash fixo e `~/.ssh` é curto.
    var controlPath: String {
        URL(fileURLWithPath: identityFile).deletingLastPathComponent().path + "/qd-%C"
    }

    /// Opções comuns a `ssh`, `rsync -e` e `sftp`. `accept-new` fixa a chave do host no primeiro contato.
    public var commonOptions: [String] {
        ["-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=accept-new",
         "-o", "UserKnownHostsFile=\(knownHostsFile)", "-o", "ConnectTimeout=8",
         "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", "-o", "LogLevel=ERROR"]
    }

    /// Reaproveita o master; se ele tiver caído, o comando conecta sozinho em vez de falhar.
    public var keyOptions: [String] {
        ["-i", identityFile, "-o", "BatchMode=yes", "-o", "ControlMaster=no", "-o", "ControlPath=\(controlPath)"] + commonOptions
    }

    public func sshArguments(_ script: String) -> [String] {
        keyOptions + ["-p", String(port), destination, "--", script]
    }

    public func masterArguments() -> [String] {
        ["-i", identityFile, "-o", "BatchMode=yes", "-o", "ControlMaster=yes", "-o", "ControlPath=\(controlPath)",
         "-o", "ControlPersist=120"] + commonOptions + ["-p", String(port), "-fN", destination]
    }

    /// Valor de `rsync -e`. Caminhos com espaço vão entre aspas: o rsync parte esta string sozinho.
    public var rsyncShell: String {
        ([ "/usr/bin/ssh", "-p", String(port)] + keyOptions).map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
    }
}

/// Canal real: `/usr/bin/ssh` multiplexado por ControlMaster.
public final class SSHRunner: CommandRunner {
    public let config: SSHConfig
    private let ssh = "/usr/bin/ssh"
    private let environment: [String: String]

    public init(config: SSHConfig) {
        self.config = config
        var env = ProcessInfo.processInfo.environment
        env["SSH_AUTH_SOCK"] = nil
        env["LC_ALL"] = "C.UTF-8"
        environment = env
    }

    /// O master sobe separado, sem pipes do app: em background ele herdaria o stderr de quem
    /// o criou e nenhum comando veria EOF.
    public func connect() async throws {
        let check = try await LocalProcess.run(ssh, ["-o", "ControlPath=\(config.controlPath)", "-O", "check", "-p", String(config.port), config.destination],
                                               environment: environment, timeout: 5)
        if check.ok { return }
        let stderr = FileManager.default.temporaryDirectory.appendingPathComponent("quietdeck-ssh-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: stderr) }
        let status = try await spawnDetached(config.masterArguments() + ["-E", stderr.path])
        guard status == 0 else {
            let message = (try? String(contentsOf: stderr, encoding: .utf8)) ?? ""
            let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
            throw text.contains("Permission denied") || text.contains("Too many authentication failures")
                ? DeckError.authenticationFailed(text) : DeckError.unreachable(text)
        }
    }

    private func spawnDetached(_ arguments: [String]) async throws -> Int32 {
        try await withCheckedThrowingContinuation { c in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ssh)
            p.arguments = arguments
            p.environment = environment
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { c.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { c.resume(throwing: error) }
        }
    }

    public func disconnect() async {
        _ = try? await LocalProcess.run(ssh, ["-o", "ControlPath=\(config.controlPath)", "-O", "exit", "-p", String(config.port), config.destination],
                                        environment: environment, timeout: 5)
    }

    public func run(_ command: RemoteCommand, onOutput: LocalProcess.Output?) async throws -> CommandResult {
        try await connect()
        let result = try await LocalProcess.run(ssh, config.sshArguments(command.script), environment: environment,
                                                stdin: command.stdin, timeout: command.timeout, onOutput: onOutput)
        if result.exitCode == 255 { throw DeckError.unreachable(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return result
    }
}
