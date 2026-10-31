import Foundation
import DeckKit

/// Pareamento pelo `steamos-devkit-service` da Valve, sem Desktop Mode nem teclado no Deck.
///
/// O serviço fica na porta 32000. `POST /register` com a chave pública mostra um pedido no Steam e
/// só responde depois da decisão, em até 30 s. Ao aprovar, o hook `approve-ssh-key` liga o sshd e
/// `install-ssh-key` grava a chave em `authorized_keys`. Referência: `/usr/share/steamos-devkit`
/// no SteamOS 3.9.5 e `devkit_client/__init__.py` do SteamOS Devkit Client.
public enum DevkitPairing {
    /// Trecho da resposta do Steam fora do modo de pareamento: "Settings -> Developer -> Pair new host".
    public static func needsPairingMode(_ message: String) -> Bool { message.contains("pairing mode") }
    public static func steamIsClosed(_ message: String) -> Bool { message.contains("Steam is not running") }

    public static let serviceType = "_steamos-devkit._tcp"
    public static let port = 32000
    /// Constante do cliente da Valve; o serviço guarda só os dois primeiros campos da chave.
    static let magicPhrase = "900b919520e4cf601998a71eec318fec"

    public enum Outcome: Equatable, Sendable {
        case approved
        /// Texto do serviço: Steam fechado, pedido negado ou tempo esgotado.
        case refused(String)
        case unreachable
    }

    /// O serviço recusa tudo que não começa com `ssh-rsa `, por isso a chave dedicada não é a ed25519.
    public static func ensureKey(at path: String) async throws {
        guard !FileManager.default.fileExists(atPath: path) else { return }
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let r = try await LocalProcess.run("/usr/bin/ssh-keygen", ["-q", "-t", "rsa", "-b", "4096", "-N", "", "-C", "quietdeck", "-f", path])
        guard r.ok else { throw DeckError.commandFailed(command: "ssh-keygen", result: r) }
    }

    /// `ssh-rsa <base64> <comentário> <frase>`: o comentário é o nome que aparece no pedido do Steam.
    public static func registerBody(publicKey: String, comment: String) -> String? {
        let fields = publicKey.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count >= 2, fields[0] == "ssh-rsa" else { return nil }
        let name = comment.filter { !$0.isWhitespace }
        return "ssh-rsa \(fields[1]) \(name.isEmpty ? "quietdeck" : name) \(magicPhrase)\n"
    }

    public static func parseResponse(status: Int, body: String) -> Outcome {
        if status == 200 { return .approved }
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let error = json["error"] as? String {
            return .refused(error)
        }
        return status == 0 ? .unreachable : .refused(body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func curl(_ arguments: [String], stdin: Data? = nil) async throws -> (status: Int, body: String) {
        let r = try await LocalProcess.run("/usr/bin/curl", ["-s", "-w", "\n%{http_code}"] + arguments, stdin: stdin)
        let lines = r.stdout.components(separatedBy: "\n")
        return (Int(lines.last ?? "") ?? 0, lines.dropLast().joined(separator: "\n"))
    }

    public static func isAvailable(host: String, port: Int = port) async -> Bool {
        let r = try? await curl(["-m", "3", "http://\(host):\(port)/?command=ping"])
        return r?.status == 200 && r?.body.hasPrefix("pong") == true
    }

    /// Usuário que o serviço autoriza; só existe `root` quando há vários usuários configurados.
    public static func loginName(host: String, port: Int = port) async -> String? {
        guard let r = try? await curl(["-m", "3", "http://\(host):\(port)/login-name"]), r.status == 200 else { return nil }
        let name = r.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Espera a decisão no Deck: o tempo limite cobre os 30 s do hook.
    public static func register(host: String, port: Int = port, keyPath: String, comment: String) async throws -> Outcome {
        let key = try String(contentsOfFile: keyPath + ".pub", encoding: .utf8)
        guard let body = registerBody(publicKey: key, comment: comment) else { return .refused("The pairing key isn't RSA.") }
        let r = try await curl(["-m", "45", "-X", "POST", "-H", "Content-Type: text/plain", "--data-binary", "@-", "http://\(host):\(port)/register"],
                               stdin: Data(body.utf8))
        return parseResponse(status: r.status, body: r.body)
    }

    /// O sshd liga logo depois da aprovação, mas não no mesmo instante.
    public static func waitForSSH(config: SSHConfig, polls: Int = 30, interval: Duration = .seconds(1)) async -> Bool {
        let runner = SSHRunner(config: config)
        for _ in 0..<polls {
            if (try? await runner.run("true").ok) == true { return true }
            try? await Task.sleep(for: interval)
        }
        return false
    }
}

public enum SudoPassword {
    public enum Status: Equatable, Sendable { case set, none, locked, unknown }

    static let statusCommand = "passwd -S \"$(id -un)\""

    /// `deck NP ...`: NP sem senha, P com senha, L bloqueado.
    public static func parseStatus(_ text: String) -> Status {
        let fields = text.split(separator: " ").map(String.init)
        guard fields.count >= 2 else { return .unknown }
        switch fields[1] {
        case "P", "PS": return .set
        case "NP": return .none
        case "L", "LK": return .locked
        default: return .unknown
        }
    }

    public static func status(_ runner: any CommandRunner) async throws -> Status {
        parseStatus(try await runner.run(statusCommand).stdout)
    }

    /// O `passwd` lê do terminal e descarta o que chega antes do prompt, então a senha só vai depois
    /// de cada pergunta, por um pty. Nunca passa por argv nem pelo gravador de comandos.
    public static func set(_ password: String, config: SSHConfig) async throws {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var seen = ""
            private var sent = 0
            func next(_ chunk: String) -> Bool {
                lock.withLock {
                    seen += chunk.lowercased()
                    let asked = seen.components(separatedBy: "new password").count - 1
                    guard asked > sent else { return false }
                    sent = asked
                    return true
                }
            }
        }
        let counter = Counter()
        let args = config.keyOptions + ["-tt", "-p", String(config.port), config.destination, "--", "LC_ALL=C passwd"]
        let r = try await LocalProcess.run("/usr/bin/ssh", args, timeout: 30, respond: { chunk in
            counter.next(chunk) ? Data((password + "\n").utf8) : nil
        })
        guard r.ok else {
            let reason = r.stdout.split(whereSeparator: \.isNewline).last.map(String.init) ?? "passwd failed"
            throw DeckError.unexpectedState(reason)
        }
    }
}
