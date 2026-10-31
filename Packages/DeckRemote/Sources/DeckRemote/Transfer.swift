import Foundation
import DeckKit

public struct TransferProgress: Equatable, Sendable {
    public var percent: Int
    public var rate: String?
}

public enum Transfer {
    public static let partialDir = ".quietdeck-partial"

    /// Lê a linha de progresso de `rsync --progress`, igual no openrsync e no rsync 3.x.
    public static func parseProgress(_ chunk: String) -> TransferProgress? {
        let lines = chunk.split(whereSeparator: { $0 == "\r" || $0 == "\n" })
        for line in lines.reversed() {
            let fields = line.split(separator: " ")
            guard fields.count >= 3, fields[1].hasSuffix("%"),
                  fields[0].allSatisfy({ $0.isNumber || $0 == "," || $0 == "." }),
                  let percent = Int(fields[1].dropLast()) else { continue }
            return TransferProgress(percent: percent, rate: String(fields[2]))
        }
        return nil
    }

    /// Clientes antigos (openrsync do macOS, protocolo 29) entregam o caminho ao shell remoto, e um
    /// espaço cria a pasta errada sem erro nenhum. Do rsync 3.2.4 em diante o próprio cliente protege.
    public static func clientQuotesPaths(versionOutput: String) -> Bool {
        guard let range = versionOutput.range(of: "protocol version "),
              let protocolVersion = Int(versionOutput[range.upperBound...].prefix { $0.isNumber }) else { return false }
        return protocolVersion >= 31
    }

    static func rsyncArguments(config: SSHConfig, source: String, destination: String) -> [String] {
        ["-rt", "--partial", "--partial-dir=\(partialDir)", "--progress", "-e", config.rsyncShell, source, destination]
    }

    public static func remoteSpec(_ config: SSHConfig, path: String, clientQuotes: Bool) -> String {
        "\(config.destination):" + (clientQuotes ? path : Shell.quote(path))
    }

    /// Flags recusadas pelo cliente ou rsync ausente no Deck: nesses casos, e só neles, cai para sftp.
    static func needsFallback(_ r: CommandResult) -> Bool {
        guard !r.ok else { return false }
        let e = r.stderr.lowercased()
        return ["unknown option", "unrecognized option", "illegal option", "command not found", "usage: rsync", "protocol version mismatch"]
            .contains { e.contains($0) }
    }

    /// Envia um arquivo ou pasta para dentro de `remoteDirectory`, retomando o que ficou pela metade.
    @discardableResult
    public static func upload(_ local: URL, to remoteDirectory: String, config: SSHConfig,
                              onProgress: (@Sendable (TransferProgress) -> Void)? = nil) async throws -> CommandResult {
        let directory = remoteDirectory.hasSuffix("/") ? remoteDirectory : remoteDirectory + "/"
        let spec = remoteSpec(config, path: directory, clientQuotes: await clientQuotes())
        let result = try await rsync(rsyncArguments(config: config, source: local.path, destination: spec), onProgress)
        guard needsFallback(result) else {
            guard result.ok else { throw DeckError.commandFailed(command: "rsync \(local.lastPathComponent)", result: result) }
            return result
        }
        return try await sftpUpload(local, to: directory, config: config, onProgress: onProgress)
    }

    /// Traz o conteúdo de uma pasta do Deck para `local`, sem apagar nada do que já existe lá.
    @discardableResult
    public static func download(remoteDirectory: String, to local: URL, config: SSHConfig,
                                onProgress: (@Sendable (TransferProgress) -> Void)? = nil) async throws -> CommandResult {
        let source = remoteDirectory.hasSuffix("/") ? remoteDirectory : remoteDirectory + "/"
        let spec = remoteSpec(config, path: source, clientQuotes: await clientQuotes())
        let result = try await rsync(rsyncArguments(config: config, source: spec, destination: local.path + "/"), onProgress)
        guard result.ok else { throw DeckError.commandFailed(command: "rsync \(source)", result: result) }
        return result
    }

    static func clientQuotes() async -> Bool {
        let v = try? await LocalProcess.run("/usr/bin/rsync", ["--version"], timeout: 5)
        return clientQuotesPaths(versionOutput: v?.stdout ?? "")
    }

    /// Puxa um arquivo de um servidor; falha com o stderr do rsync.
    static func run(_ arguments: [String]) async throws {
        let r = try await rsync(arguments, nil)
        guard r.ok else { throw DeckError.commandFailed(command: "rsync", result: r) }
    }

    private static func rsync(_ arguments: [String], _ onProgress: (@Sendable (TransferProgress) -> Void)?) async throws -> CommandResult {
        try await LocalProcess.run("/usr/bin/rsync", arguments, onOutput: { chunk in
            if let p = parseProgress(chunk) { onProgress?(p) }
        })
    }

    /// `reput` retoma, mas exige o destino já existente e com o nome final.
    /// No modo batch o sftp não mostra percentual.
    static func sftpBatch(local: String, remotePath: String, isDirectory: Bool) -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        return "reput\(isDirectory ? " -r" : "") \(q(local)) \(q(remotePath))\n"
    }

    static func sftpUpload(_ local: URL, to directory: String, config: SSHConfig,
                           onProgress: (@Sendable (TransferProgress) -> Void)?) async throws -> CommandResult {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: local.path, isDirectory: &isDirectory)
        let remote = (directory.hasSuffix("/") ? directory : directory + "/") + local.lastPathComponent
        let prepare = isDirectory.boolValue ? "mkdir -p \(Shell.quote(remote))" : "touch \(Shell.quote(remote))"
        try await SSHRunner(config: config).check(prepare)
        let args = config.keyOptions + ["-P", String(config.port), "-b", "-", config.destination]
        let batch = sftpBatch(local: local.path, remotePath: remote, isDirectory: isDirectory.boolValue)
        let r = try await LocalProcess.run("/usr/bin/sftp", args, stdin: Data(batch.utf8))
        guard r.ok else { throw DeckError.commandFailed(command: "sftp \(local.lastPathComponent)", result: r) }
        onProgress?(TransferProgress(percent: 100, rate: nil))
        return r
    }
}
