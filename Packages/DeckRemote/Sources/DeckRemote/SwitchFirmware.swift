import Foundation
import DeckKit

/// Firmware do Switch, do console do usuário: o app nunca baixa. Repete o `InstallFirmware` do Ryubing
/// (`Ryujinx.HLE/FileSystem/ContentManager.cs`): cada `.nca` vira `registered/<id>.nca/00` e a pasta
/// `registered` inteira é trocada de uma vez.
public enum SwitchFirmware {
    static let deckDirectory = ".var/app/io.github.ryubing.Ryujinx/config/Ryujinx/bis/system/Contents"
    static let flatpak = "io.github.ryubing.Ryujinx"
    /// Um firmware tem centenas de `.nca`; um jogo extraído, poucos.
    static let minimum = 20

    /// Nome no Ryubing: sem `.cnmt`, e `x.nca/00` (NCA fragmentada) vira `x.nca`.
    static func registeredName(_ entry: String) -> String? {
        var parts = entry.replacingOccurrences(of: ".cnmt", with: "").split(separator: "/").map(String.init)
        if parts.last == "00" { parts.removeLast() }
        guard let name = parts.last, name.hasSuffix(".nca") else { return nil }
        return name
    }

    /// Pasta ou `.zip` só com `.nca`, em quantidade de firmware.
    public static func isFirmware(_ url: URL) async -> Bool {
        guard let entries = try? await entries(url) else { return false }
        return entries.count >= minimum && entries.allSatisfy { registeredName($0) != nil }
    }

    static func entries(_ url: URL) async throws -> [String] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
        if isDir.boolValue {
            var found: [String] = []
            let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            while let item = walker?.nextObject() as? URL {
                guard (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                found.append(String(item.standardizedFileURL.path.dropFirst(url.standardizedFileURL.path.count + 1)))
            }
            return found
        }
        guard url.pathExtension.lowercased() == "zip" else { return [] }
        let r = try await LocalProcess.run("/usr/bin/zipinfo", ["-1", url.path])
        guard r.ok else { return [] }
        return r.stdout.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.hasSuffix("/") && !$0.hasPrefix("__MACOSX/") }
    }

    /// Monta `registered` no Mac, no formato final.
    static func stage(_ source: URL, work: URL) async throws -> (directory: URL, count: Int) {
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        var root = source
        if source.pathExtension.lowercased() == "zip" {
            root = work.appendingPathComponent("extracted")
            let r = try await LocalProcess.run("/usr/bin/unzip", ["-o", "-q", source.path, "-d", root.path])
            guard r.ok else { throw DeckError.commandFailed(command: "unzip", result: r) }
        }
        let registered = work.appendingPathComponent("registered")
        var count = 0
        for entry in try await entries(root) {
            guard let name = registeredName(entry) else { continue }
            let folder = registered.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: root.appendingPathComponent(entry), to: folder.appendingPathComponent("00"))
            count += 1
        }
        guard count >= minimum else {
            throw DeckError.unexpectedState("%@ doesn't look like Switch firmware: it has %@ .nca files.", source.lastPathComponent, String(count))
        }
        return (registered, count)
    }

    /// Envia ao lado e troca numa operação só: firmware pela metade não abre jogo nenhum.
    public static func install(_ source: URL, config: SSHConfig, runner: any CommandRunner, work: URL,
                               progress: @escaping @Sendable (Int?, String?) -> Void) async throws -> Int {
        let open = try await runner.check("flatpak ps --columns=application").stdout.split(whereSeparator: \.isNewline)
        if open.contains(where: { $0.trimmingCharacters(in: .whitespaces) == flatpak }) {
            throw DeckError.unexpectedState("Close %@ first: it rewrites its settings when it exits.", "Ryubing")
        }
        progress(nil, "Preparing the firmware")
        let staged = try await stage(source, work: work)
        defer { try? FileManager.default.removeItem(at: work) }
        let files = RemoteFiles(runner: runner)
        let base = try await files.home() + "/" + deckDirectory
        try await files.ensureSpace(ROMScanner.folderSize(staged.directory), in: base)
        // Sobra de um envio interrompido misturaria arquivos de outra versão.
        try await runner.check("rm -rf \(Shell.quote(base + "/registered.quietdeck-new"))")
        try await Transfer.upload(staged.directory, to: base, named: "registered.quietdeck-new", config: config) { p in
            progress(p.percent, "Sending")
        }
        let b = Shell.quote(base)
        try await runner.check("cd \(b) && rm -rf registered.quietdeck-old && if [ -d registered ]; then mv registered registered.quietdeck-old; fi && mv registered.quietdeck-new registered && rm -rf registered.quietdeck-old")
        let installed = try await runner.check("find \(b)/registered -mindepth 2 -maxdepth 2 -name 00 -type f | wc -l").trimmed
        guard installed == String(staged.count) else {
            throw DeckError.unexpectedState("The Deck has %@ firmware files instead of %@. Try again.", installed, String(staged.count))
        }
        return staged.count
    }
}
