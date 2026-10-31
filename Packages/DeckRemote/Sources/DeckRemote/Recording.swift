import Foundation

/// Uma linha de fixture. `stdin` fica de fora de propósito.
public struct RecordedCommand: Codable, Equatable, Sendable {
    public var command: String
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32
}

public struct RecordingFile: Codable, Equatable, Sendable {
    /// `steamos-real`, `container` ou `sintética`: uma fixture nunca finge vir de um Deck que não a gravou.
    public var source: String
    public var commands: [RecordedCommand]

    public init(source: String, commands: [RecordedCommand]) {
        self.source = source
        self.commands = commands
    }
}

/// Grava o que passa pelo canal num JSON, a cada comando, para sobreviver a uma queda do app.
public actor CommandRecorder {
    private let url: URL
    private var file: RecordingFile

    public init(url: URL, source: String) {
        self.url = url
        file = RecordingFile(source: source, commands: [])
    }

    func add(_ entry: RecordedCommand) throws {
        file.commands.append(entry)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(file).write(to: url, options: .atomic)
    }
}

public struct RecordingRunner: CommandRunner {
    let base: any CommandRunner
    let recorder: CommandRecorder

    public init(base: any CommandRunner, recorder: CommandRecorder) {
        self.base = base
        self.recorder = recorder
    }

    public func run(_ command: RemoteCommand, onOutput: LocalProcess.Output?) async throws -> CommandResult {
        let r = try await base.run(command, onOutput: onOutput)
        try await recorder.add(RecordedCommand(command: command.script, stdout: r.stdout, stderr: r.stderr, exitCode: r.exitCode))
        return r
    }
}

/// Responde pelo texto exato do comando; o que não foi gravado é erro, nunca sucesso silencioso.
/// Comandos repetidos consomem as gravações em ordem e a última se repete.
public final class ReplayRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String: [CommandResult]] = [:]
    private var log: [RemoteCommand] = []

    public struct Unrecorded: Error, CustomStringConvertible {
        public let command: String
        public var description: String { "Comando sem gravação: \(command)" }
    }

    public init(_ file: RecordingFile) {
        for c in file.commands {
            pending[c.command, default: []].append(CommandResult(stdout: c.stdout, stderr: c.stderr, exitCode: c.exitCode))
        }
    }

    public convenience init(json url: URL) throws {
        self.init(try JSONDecoder().decode(RecordingFile.self, from: Data(contentsOf: url)))
    }

    public convenience init(_ responses: [String: CommandResult]) {
        self.init(RecordingFile(source: "sintética", commands: responses.map {
            RecordedCommand(command: $0.key, stdout: $0.value.stdout, stderr: $0.value.stderr, exitCode: $0.value.exitCode)
        }))
    }

    /// Comandos na ordem em que chegaram: a prova de que o estado foi lido antes do efeito.
    public var executed: [String] { lock.withLock { log.map(\.script) } }
    public var received: [RemoteCommand] { lock.withLock { log } }

    public func run(_ command: RemoteCommand, onOutput: LocalProcess.Output?) async throws -> CommandResult {
        try lock.withLock {
            log.append(command)
            guard var queue = pending[command.script], let first = queue.first else {
                throw Unrecorded(command: command.script)
            }
            if queue.count > 1 {
                queue.removeFirst()
                pending[command.script] = queue
            }
            return first
        }
    }
}
