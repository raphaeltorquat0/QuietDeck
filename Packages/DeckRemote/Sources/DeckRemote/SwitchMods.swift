import Foundation
import DeckKit

/// Tradução ou mod de Switch no formato LayeredFS (`<TitleID>/romfs`, `<TitleID>/exefs`, como no
/// `atmosphere/contents` do console). Vai para onde o `ModLoader.cs` do Ryubing procura:
/// `mods/contents/<TitleID>/<nome do mod>/`, ligado por padrão.
public enum SwitchMods {
    static let deckDirectory = ".var/app/io.github.ryubing.Ryujinx/config/Ryujinx/mods/contents"
    static let flatpak = "io.github.ryubing.Ryujinx"

    /// Caminhos relativos `…/<TitleID>` que têm `romfs/` ou `exefs/` logo abaixo.
    static func titleFolders(in entries: [String]) -> [String] {
        let pattern = #"(?i)^(.*?)([0-9a-f]{16})/(romfs|exefs)/"#
        var found: [String] = []
        for entry in entries {
            guard let m = entry.range(of: pattern, options: .regularExpression) else { continue }
            let prefix = String(entry[m]).split(separator: "/").dropLast().joined(separator: "/")
            if !found.contains(prefix) { found.append(prefix) }
        }
        return found
    }

    public static func isModPack(_ url: URL) async -> Bool {
        guard let entries = try? await SwitchFirmware.entries(url) else { return false }
        return !titleFolders(in: entries).isEmpty
    }

    /// Nome do mod no Ryubing: o da pasta ou do `.zip` que o usuário soltou.
    static func modName(_ url: URL) -> String {
        url.pathExtension.lowercased() == "zip" ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
    }

    /// Devolve os Title IDs instalados.
    public static func install(_ source: URL, config: SSHConfig, runner: any CommandRunner, work: URL,
                               progress: @escaping @Sendable (Int?, String?) -> Void) async throws -> [String] {
        let open = try await runner.check("flatpak ps --columns=application").stdout.split(whereSeparator: \.isNewline)
        if open.contains(where: { $0.trimmingCharacters(in: .whitespaces) == flatpak }) {
            throw DeckError.unexpectedState("Close %@ first: it rewrites its settings when it exits.", "Ryubing")
        }
        var root = source
        if source.pathExtension.lowercased() == "zip" {
            try? FileManager.default.removeItem(at: work)
            root = work.appendingPathComponent("extracted")
            let r = try await LocalProcess.run("/usr/bin/unzip", ["-o", "-q", source.path, "-d", root.path])
            guard r.ok else { throw DeckError.commandFailed(command: "unzip", result: r) }
        }
        defer { try? FileManager.default.removeItem(at: work) }
        let folders = titleFolders(in: try await SwitchFirmware.entries(root))
        guard !folders.isEmpty else { throw DeckError.unexpectedState("%@ has no romfs or exefs folder under a Switch title ID.", source.lastPathComponent) }
        let files = RemoteFiles(runner: runner)
        let base = try await files.home() + "/" + deckDirectory
        let name = modName(source)
        var titles: [String] = []
        for (i, folder) in folders.enumerated() {
            let local = root.appendingPathComponent(folder)
            let title = local.lastPathComponent.uppercased()
            let target = "\(base)/\(title)"
            try await files.ensureSpace(ROMScanner.folderSize(local), in: target)
            // Reinstalar substitui o mod inteiro: sobra de outra versão misturaria arquivos.
            try await runner.check("rm -rf \(Shell.quote(target + "/" + name))")
            try await Transfer.upload(local, to: target, named: name, config: config) { p in
                progress((i * 100 + p.percent) / folders.count, "Sending")
            }
            titles.append(title)
        }
        return titles
    }
}
