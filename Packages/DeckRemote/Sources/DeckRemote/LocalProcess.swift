import Foundation
import DeckKit

/// Resultado de um comando, no mesmo formato gravado nas fixtures do modo record/replay.
public struct CommandResult: Codable, Equatable, Sendable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32

    public init(stdout: String = "", stderr: String = "", exitCode: Int32 = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }

    public var ok: Bool { exitCode == 0 }
    public var trimmed: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Roda um binário do sistema e junta a saída. Entrega pedaços ao vivo para quem mostra progresso.
public enum LocalProcess {
    public typealias Output = @Sendable (String) -> Void

    public static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                           stdin: Data? = nil, timeout: TimeInterval? = nil, onOutput: Output? = nil,
                           respond: (@Sendable (String) -> Data?)? = nil) async throws -> CommandResult {
        signal(SIGPIPE, SIG_IGN) // ssh pode sair antes de ler a senha; isso não pode derrubar o app.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let out = Pipe(), err = Pipe(), input = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = stdin == nil && respond == nil ? FileHandle.nullDevice : input

        let handle = ProcessHandle(process)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<CommandResult, Error>) in
                let group = DispatchGroup()
                // Conversa por pty: cada pedaço de saída pode gerar uma resposta na entrada padrão.
                let sink = conversation(onOutput, respond, input.fileHandleForWriting)
                let stdoutBox = Collector(sink), stderrBox = Collector(sink)
                drain(out.fileHandleForReading, into: stdoutBox, group)
                drain(err.fileHandleForReading, into: stderrBox, group)
                process.terminationHandler = { p in
                    handle.timer?.cancel()
                    group.notify(queue: .global()) {
                        let timedOut = handle.timedOut
                        c.resume(returning: CommandResult(
                            stdout: stdoutBox.string,
                            stderr: timedOut ? stderrBox.string + "\n[QuietDeck] timed out" : stderrBox.string,
                            exitCode: timedOut ? 124 : p.terminationStatus))
                    }
                }
                do {
                    try process.run()
                } catch {
                    c.resume(throwing: error)
                    return
                }
                if let stdin {
                    DispatchQueue.global().async {
                        try? input.fileHandleForWriting.write(contentsOf: stdin)
                        try? input.fileHandleForWriting.close()
                    }
                }
                if let timeout { handle.arm(timeout) }
                if Task.isCancelled { process.terminate() }
            }
        } onCancel: {
            handle.terminate()
        }
    }

    private static func conversation(_ onOutput: Output?, _ respond: (@Sendable (String) -> Data?)?, _ writer: FileHandle) -> Output? {
        guard let respond else { return onOutput }
        return { chunk in
            onOutput?(chunk)
            if let reply = respond(chunk) { try? writer.write(contentsOf: reply) }
        }
    }

    private static func drain(_ file: FileHandle, into box: Collector, _ group: DispatchGroup) {
        group.enter()
        DispatchQueue.global().async {
            while true {
                let chunk = file.availableData
                if chunk.isEmpty { break }
                box.append(chunk)
            }
            group.leave()
        }
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private let onOutput: Output?
        init(_ onOutput: Output?) { self.onOutput = onOutput }

        func append(_ chunk: Data) {
            lock.withLock { data.append(chunk) }
            onOutput?(String(decoding: chunk, as: UTF8.self))
        }

        var string: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }

    private final class ProcessHandle: @unchecked Sendable {
        let process: Process
        var timer: DispatchSourceTimer?
        private let lock = NSLock()
        private var expired = false
        init(_ process: Process) { self.process = process }

        var timedOut: Bool { lock.withLock { expired } }

        func arm(_ seconds: TimeInterval) {
            let t = DispatchSource.makeTimerSource(queue: .global())
            t.schedule(deadline: .now() + seconds)
            t.setEventHandler { [self] in
                lock.withLock { expired = true }
                terminate()
            }
            t.resume()
            timer = t
        }

        func terminate() { if process.isRunning { process.terminate() } }
    }
}
