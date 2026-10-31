import Foundation
import DeckKit

public struct GitHubAsset: Codable, Hashable, Sendable {
    public var name: String
    public var browser_download_url: String
}

public struct GitHubRelease: Codable, Equatable, Identifiable, Sendable {
    public var tag_name: String
    public var prerelease: Bool
    public var assets: [GitHubAsset]
    public var id: String { tag_name }
}

public enum CompatTools {
    public static func releases(repo: String) async throws -> [GitHubRelease] {
        try await PublicAPI.get("https://api.github.com/repos/\(repo)/releases?per_page=15")
    }

    /// `~/.steam/root` é um symlink para `~/.local/share/Steam`; aqui não dependemos do link.
    public static let directorySuffix = "/.local/share/Steam/compatibilitytools.d"
    public static let list = "ls -1 ~/.local/share/Steam/compatibilitytools.d 2>/dev/null"

    public static func installed(_ runner: any CommandRunner) async throws -> [String] {
        try await runner.run(list).stdout.split(whereSeparator: \.isNewline).map(String.init)
    }

    public static func assets(in release: GitHubRelease, source: CompatToolSource) -> (archive: GitHubAsset, checksum: GitHubAsset?)? {
        guard let archive = release.assets.first(where: { $0.name.hasSuffix(source.assetSuffix) }) else { return nil }
        let base = archive.name.replacingOccurrences(of: source.assetSuffix, with: "")
        let checksum = release.assets.first { $0.name.hasPrefix(base) && $0.name.hasSuffix(source.checksumSuffix) && !$0.name.contains("_v3") }
        return (archive, checksum)
    }

    static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }

    public enum Outcome: Equatable, Sendable { case done, alreadyInstalled, notInstalled }

    /// Baixa no próprio Deck, confere o sha512 e só depois extrai; o tar fica fora do destino até acabar.
    public static func install(archive: GitHubAsset, checksum: GitHubAsset?, folderName: String, runner: any CommandRunner, onOutput: LocalProcess.Output? = nil) async throws -> Outcome {
        guard isSafeName(folderName) else { throw DeckError.unexpectedState("Invalid tool name: %@", folderName) }
        if try await installed(runner).contains(folderName) { return .alreadyInstalled }
        let home = try await RemoteFiles(runner: runner).home()
        let target = home + directorySuffix
        let work = home + "/.cache/quietdeck/compat"
        let tar = Shell.quote(archive.name)
        var script = "mkdir -p \(Shell.quote(work)) \(Shell.quote(target)) && cd \(Shell.quote(work)) && rm -rf extract && mkdir extract && curl -fsSL -o \(tar) \(Shell.quote(archive.browser_download_url))"
        if let checksum {
            script += " && curl -fsSL -o sum \(Shell.quote(checksum.browser_download_url)) && test \"$(cut -d' ' -f1 sum)\" = \"$(sha512sum \(tar) | cut -d' ' -f1)\""
        }
        script += " && tar -xf \(tar) -C extract && mv extract/* \(Shell.quote(target + "/")) && rm -rf extract sum \(tar)"
        try await runner.check(RemoteCommand(script, timeout: 3600), onOutput: onOutput)
        return .done
    }

    public static func remove(_ name: String, runner: any CommandRunner) async throws -> Outcome {
        guard isSafeName(name) else { throw DeckError.unexpectedState("Invalid tool name: %@", name) }
        guard try await installed(runner).contains(name) else { return .notInstalled }
        let home = try await RemoteFiles(runner: runner).home()
        try await runner.check("rm -rf \(Shell.quote(home + directorySuffix + "/" + name))")
        return .done
    }
}

/// Backup de saves: pastas de `Emulation/saves` e as que cada emulador guarda em `~/.var/app`.
public enum Saves {
    public static func sources(paths: EmulationPaths, emulators: [Emulator], home: String) -> [(label: String, path: String)] {
        var result = [("emulation", paths.saves)]
        for e in emulators {
            for (i, p) in (e.saves ?? []).enumerated() { result.append(("\(e.id)-\(i)", home + "/" + p)) }
        }
        return result
    }

    public static func backup(paths: EmulationPaths, emulators: [Emulator], to folder: URL, config: SSHConfig, runner: any CommandRunner,
                              onProgress: (@Sendable (TransferProgress) -> Void)? = nil) async throws -> Int {
        let home = try await RemoteFiles(runner: runner).home()
        var copied = 0
        for source in sources(paths: paths, emulators: emulators, home: home) {
            guard try await runner.run("test -d \(Shell.quote(source.path))").ok else { continue }
            let dest = folder.appendingPathComponent(source.label)
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            try await Transfer.download(remoteDirectory: source.path, to: dest, config: config, onProgress: onProgress)
            copied += 1
        }
        return copied
    }

    /// Só repõe o que existe no backup; nada no Deck é apagado.
    public static func restore(paths: EmulationPaths, emulators: [Emulator], from folder: URL, config: SSHConfig, runner: any CommandRunner,
                               onProgress: (@Sendable (TransferProgress) -> Void)? = nil) async throws -> Int {
        let home = try await RemoteFiles(runner: runner).home()
        var restored = 0
        for source in sources(paths: paths, emulators: emulators, home: home) {
            let local = folder.appendingPathComponent(source.label)
            guard let items = try? FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil) else { continue }
            try await runner.check("mkdir -p \(Shell.quote(source.path))")
            for item in items { try await Transfer.upload(item, to: source.path, config: config, onProgress: onProgress) }
            restored += 1
        }
        return restored
    }
}
