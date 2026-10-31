import Foundation
import DeckKit

/// Primeiro contato: gera a chave dedicada e a instala no Deck com a senha do usuário.
public enum Pairing {
    public static func ensureKey(at path: String) async throws {
        guard !FileManager.default.fileExists(atPath: path) else { return }
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let r = try await LocalProcess.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "quietdeck", "-f", path])
        guard r.ok else { throw DeckError.commandFailed(command: "ssh-keygen", result: r) }
    }

    /// Idempotente: repetir não duplica a linha em `authorized_keys`.
    public static func installScript(publicKey: String) -> String {
        let key = Shell.quote(publicKey.trimmingCharacters(in: .whitespacesAndNewlines))
        return "umask 077; mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && (grep -qxF \(key) ~/.ssh/authorized_keys || echo \(key) >> ~/.ssh/authorized_keys)"
    }

    /// Usa `SSH_ASKPASS` só neste login: o helper lê a senha do ambiente do próprio processo.
    public static func installKey(config: SSHConfig, password: String) async throws {
        let publicKey = try String(contentsOfFile: config.identityFile + ".pub", encoding: .utf8)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quietdeck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let helper = dir.appendingPathComponent("askpass")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$QUIETDECK_ASKPASS\"\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)

        var env = ProcessInfo.processInfo.environment
        env["SSH_AUTH_SOCK"] = nil
        env["SSH_ASKPASS"] = helper.path
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["DISPLAY"] = ":0"
        env["QUIETDECK_ASKPASS"] = password
        let args = ["-o", "PubkeyAuthentication=no", "-o", "PreferredAuthentications=password,keyboard-interactive",
                    "-o", "NumberOfPasswordPrompts=1", "-o", "ControlPath=none"] + config.commonOptions
            + ["-p", String(config.port), config.destination, "--", installScript(publicKey: publicKey)]
        let r = try await LocalProcess.run("/usr/bin/ssh", args, environment: env, timeout: 30)
        guard r.ok else {
            throw r.stderr.contains("Permission denied") ? DeckError.authenticationFailed(r.stderr) : DeckError.unreachable(r.stderr)
        }
        // Prova que a chave funciona antes de dizer que terminou.
        let runner = SSHRunner(config: config)
        await runner.disconnect()
        _ = try await runner.check("true")
    }
}
