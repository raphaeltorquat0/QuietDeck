import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import DeckKit

public struct DeckyState: Equatable, Sendable {
    public var installed: Bool
    public var version: String?
    public var serviceActive: Bool
}

public struct InstalledPlugin: Codable, Equatable, Identifiable, Sendable {
    public var name: String
    public var version: String?
    public var folder: String
    public var id: String { name }
}

public struct StorePlugin: Codable, Equatable, Identifiable, Sendable {
    public struct Version: Codable, Hashable, Sendable {
        public var name: String
        public var hash: String
        public var artifact: String?
    }

    public var id: Int
    public var name: String
    public var author: String
    public var description: String
    public var tags: [String]
    public var versions: [Version]
    public var image_url: String?

    /// Mesmo fallback de `pluginUrl` em `frontend/src/store.tsx` do decky-loader.
    public static func artifactURL(_ v: Version) -> String {
        v.artifact ?? "https://cdn.tzatzikiweeb.moe/file/steam-deck-homebrew/versions/\(v.hash).zip"
    }
}

public enum Decky {
    public static let storeURL = "https://plugins.deckbrew.xyz/plugins"
    public static let installerURL = "https://github.com/SteamDeckHomebrew/decky-installer/releases/latest/download/install_release.sh"
    public static let stateScript = "test -x ~/homebrew/services/PluginLoader && echo installed; cat ~/homebrew/services/.loader.version 2>/dev/null; echo; systemctl is-active plugin_loader 2>/dev/null"

    public static func parseState(_ text: String) -> DeckyState {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let installed = lines.first == "installed"
        let rest = installed ? Array(lines.dropFirst()) : lines
        let status = rest.last
        let version = rest.first { $0 != status && $0.hasPrefix("v") }
        return DeckyState(installed: installed, version: version, serviceActive: status == "active")
    }

    public static func state(_ runner: any CommandRunner) async throws -> DeckyState {
        parseState(try await runner.run(stateScript).stdout)
    }

    /// O instalador é o oficial e grava em `/etc/systemd/system`: exceção registrada, ver DECISIONS.md.
    public static func install(_ runner: any CommandRunner, password: String, onOutput: LocalProcess.Output? = nil) async throws {
        let dir = "$HOME/.cache/quietdeck"
        try await runner.check(RemoteCommand("mkdir -p \(dir) && curl -fsSL -o \(dir)/install_release.sh \(Shell.quote(installerURL))", timeout: 60))
        let home = try await RemoteFiles(runner: runner).home()
        try await runner.check(.sudo("sh \(Shell.quote(home + "/.cache/quietdeck/install_release.sh"))", password: password, timeout: 600), onOutput: onOutput)
        guard try await state(runner).installed else { throw DeckError.unexpectedState("The installer finished, but Decky isn't there.") }
    }

    static let pluginList = #"""
    python3 -c 'import json,os,glob
    out=[]
    for p in glob.glob(os.path.expanduser("~/homebrew/plugins/*/plugin.json")):
        d=os.path.dirname(p)
        try:
            n=json.load(open(p))["name"]
        except Exception:
            continue
        try:
            v=json.load(open(d+"/package.json")).get("version")
        except Exception:
            v=None
        out.append({"name":n,"version":v,"folder":os.path.basename(d)})
    print(json.dumps(out))'
    """#

    public static func plugins(_ runner: any CommandRunner) async throws -> [InstalledPlugin] {
        try JSONDecoder().decode([InstalledPlugin].self, from: Data(try await runner.check(pluginList).stdout.utf8))
    }

    /// Reproduz `PluginBrowser._install` e `set_plugin_dir_permissions` de `backend/decky_loader/browser.py`,
    /// inclusive o sha256 e o `remote_binary`, sem depender da porta local do loader, que exige sessão do Steam.
    static func installScript(name: String, url: String, hash: String, pluginsDir: String, user: String) -> String {
        let python = #"""
        import hashlib, io, json, os, shutil, sys, urllib.request, zipfile
        name, url, want, root, user = sys.argv[1:6]
        data = urllib.request.urlopen(url, timeout=120).read()
        if hashlib.sha256(data).hexdigest() != want:
            sys.exit("sha256 mismatch")
        def find():
            for f in os.listdir(root):
                try:
                    if json.load(open(os.path.join(root, f, "plugin.json")))["name"] == name:
                        return f
                except Exception:
                    pass
        old = find()
        if old:
            shutil.rmtree(os.path.join(root, old))
        zipfile.ZipFile(io.BytesIO(data)).extractall(root)
        folder = find()
        if not folder:
            sys.exit("plugin.json not found in the archive")
        d = os.path.join(root, folder)
        pkg = os.path.join(d, "package.json")
        if os.path.exists(pkg):
            for b in json.load(open(pkg)).get("remote_binary", []):
                blob = urllib.request.urlopen(b["url"], timeout=300).read()
                if hashlib.sha256(blob).hexdigest() != b["sha256hash"]:
                    sys.exit("sha256 mismatch in " + b["name"])
                os.makedirs(os.path.join(d, "bin"), exist_ok=True)
                open(os.path.join(d, "bin", os.path.basename(b["name"])), "wb").write(blob)
        import pwd
        meta = json.load(open(os.path.join(d, "plugin.json")))
        owner = 0 if "root" in meta.get("flags", []) else pwd.getpwnam(user).pw_uid
        for base, dirs, files in os.walk(d):
            for x in dirs + files:
                os.chown(os.path.join(base, x), owner, owner)
        os.chown(d, 0, 0)
        os.chmod(d, 0o755)
        os.chown(os.path.join(d, "plugin.json"), 0, 0)
        os.chmod(os.path.join(d, "plugin.json"), 0o755)
        """#
        return "python3 -c \(Shell.quote(python)) " + [name, url, hash, pluginsDir, user].map(Shell.quote).joined(separator: " ")
    }

    static func removeScript(name: String, pluginsDir: String) -> String {
        let python = #"""
        import json, os, shutil, sys
        name, root = sys.argv[1:3]
        for f in os.listdir(root):
            try:
                if json.load(open(os.path.join(root, f, "plugin.json")))["name"] == name:
                    shutil.rmtree(os.path.join(root, f))
            except FileNotFoundError:
                pass
        """#
        return "python3 -c \(Shell.quote(python)) \(Shell.quote(name)) \(Shell.quote(pluginsDir))"
    }

    public enum Outcome: Equatable, Sendable { case done, alreadyCurrent, notInstalled }

    public static func installPlugin(name: String, version: StorePlugin.Version, runner: any CommandRunner, password: String) async throws -> Outcome {
        let installed = try await plugins(runner).first { $0.name == name }
        if installed?.version == version.name { return .alreadyCurrent }
        let home = try await RemoteFiles(runner: runner).home()
        let user = try await runner.check("id -un").trimmed
        try await runner.check(.sudo(installScript(name: name, url: StorePlugin.artifactURL(version), hash: version.hash,
                                                   pluginsDir: home + "/homebrew/plugins", user: user), password: password, timeout: 600))
        try await runner.check(.sudo("systemctl restart plugin_loader", password: password))
        return .done
    }

    public static func removePlugin(name: String, runner: any CommandRunner, password: String) async throws -> Outcome {
        guard try await plugins(runner).contains(where: { $0.name == name }) else { return .notInstalled }
        let home = try await RemoteFiles(runner: runner).home()
        try await runner.check(.sudo(removeScript(name: name, pluginsDir: home + "/homebrew/plugins"), password: password))
        try await runner.check(.sudo("systemctl restart plugin_loader", password: password))
        return .done
    }
}

extension Decky {
    /// A descrição de alguns plugins traz caractere de controle cru, que o JSONDecoder recusa.
    public static func store() async throws -> [StorePlugin] {
        guard let url = URL(string: storeURL) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("3.0.0", forHTTPHeaderField: "X-Decky-Version")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode([StorePlugin].self, from: Data(data.map { $0 < 0x20 ? 0x20 : $0 }))
    }
}
