import Foundation
import DeckKit

/// Ferramentas do Mac usadas pelo pipeline. Apps abertos pelo Finder não herdam o PATH do Homebrew.
public enum LocalTools {
    static let prefixes = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", NSHomeDirectory() + "/.local/bin"]

    public static func find(_ names: String...) -> String? {
        for prefix in prefixes {
            for name in names where FileManager.default.isExecutableFile(atPath: "\(prefix)/\(name)") { return "\(prefix)/\(name)" }
        }
        return nil
    }

    /// `chdman` vem na fórmula `rom-tools`; `7zz` na `sevenzip`.
    public static func require(_ names: [String], formula: String, onOutput: LocalProcess.Output? = nil) async throws -> String {
        func found() -> String? { names.lazy.compactMap { find($0) }.first }
        if let path = found() { return path }
        guard let brew = find("brew") else {
            throw DeckError.unexpectedState("%@ is missing and Homebrew isn't installed. Install Homebrew from brew.sh, then try again.", names[0])
        }
        let r = try await LocalProcess.run(brew, ["install", formula], onOutput: onOutput)
        guard r.ok, let path = found() else { throw DeckError.commandFailed(command: "brew install \(formula)", result: r) }
        return path
    }

    /// `nsz` não tem fórmula: vem do PyPI pelo pipx, na versão conferida.
    public static func nsz() async throws -> String {
        if let path = find("nsz") { return path }
        let pipx = try await require(["pipx"], formula: "pipx")
        let r = try await LocalProcess.run(pipx, ["install", "nsz==5.0.0"])
        guard r.ok, let path = find("nsz") else { throw DeckError.commandFailed(command: "pipx install nsz", result: r) }
        return path
    }
}

/// Chaves do console do usuário: o app nunca baixa. `prod.keys` (o `nsz` procura em `~/.switch`) e
/// `title.keys` (jogos sem ticket), guardadas só para o dono e copiadas ao Ryubing.
public enum SwitchKeys {
    public static let files = ["prod.keys", "title.keys"]

    /// O que identifica cada arquivo: `header_key` no `prod.keys`, pares `rights id = title key` no `title.keys`.
    static func isValid(_ text: String, name: String) -> Bool {
        let pattern = name == "title.keys" ? #"(?m)^\s*[0-9a-fA-F]{32}\s*=\s*[0-9a-fA-F]{32}\s*$"# : #"(?m)^\s*header_key\s*=\s*[0-9a-fA-F]{64}\s*$"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    public static func install(from source: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let name = source.lastPathComponent.lowercased()
        let data = try Data(contentsOf: source)
        guard files.contains(name), isValid(String(decoding: data, as: UTF8.self), name: name) else {
            throw DeckError.unexpectedState("%@ isn't a Switch keys file.", source.lastPathComponent)
        }
        let directory = home.appendingPathComponent(".switch")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = directory.appendingPathComponent(name)
        try data.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    /// Sem chaves no Mac, o emulador pode já ter as dele: não é falha.
    public static func send(config: SSHConfig, runner: any CommandRunner, home: URL = FileManager.default.homeDirectoryForCurrentUser) async throws {
        let local = files.map { home.appendingPathComponent(".switch/" + $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !local.isEmpty else { return }
        let directory = try await RemoteFiles(runner: runner).home() + "/" + deckDirectory
        try await runner.check("mkdir -p \(Shell.quote(directory)) && chmod 700 \(Shell.quote(directory))")
        for file in local {
            try await Transfer.upload(file, to: directory, config: config) { _ in }
            try await runner.check("chmod 600 \(Shell.quote(directory + "/" + file.lastPathComponent))")
        }
    }

    static let deckDirectory = ".var/app/io.github.ryubing.Ryujinx/config/Ryujinx/system"

    /// O Eden lê as mesmas chaves e o mesmo firmware, em outro formato: copia do Ryubing, no próprio Deck.
    /// Firmware do Ryubing é `registered/<id>.nca/00`; o do Eden, `registered/<id>.nca` (como o yuzu).
    public static func prepareEden(runner: any CommandRunner) async throws {
        let ryu = ".var/app/io.github.ryubing.Ryujinx/config/Ryujinx"
        let eden = ".var/app/dev.eden_emu.eden/data/eden"
        let script = """
        cd ~ && mkdir -p \(eden)/keys \(eden)/nand/system/Contents/registered && \
        for k in prod.keys title.keys; do if [ -f \(ryu)/system/$k ]; then cp \(ryu)/system/$k \(eden)/keys/$k && chmod 600 \(eden)/keys/$k; fi; done && \
        if [ -d \(ryu)/bis/system/Contents/registered ]; then \
          for d in \(ryu)/bis/system/Contents/registered/*.nca; do n=$(basename "$d"); \
            if [ ! -f "\(eden)/nand/system/Contents/registered/$n" ]; then cp "$d/00" "\(eden)/nand/system/Contents/registered/$n"; fi; done && \
          for f in \(eden)/nand/system/Contents/registered/*.nca; do \
            if [ ! -d "\(ryu)/bis/system/Contents/registered/$(basename "$f")" ]; then rm -f "$f"; fi; done; fi
        """
        try await runner.check(RemoteCommand(script, timeout: 300))
    }
}

/// Patch `.pkg` e firmware `PS3UPDAT.PUP` do PS3 entram pelo próprio RPCS3, sem janela
/// (`--headless --installpkg/--installfw`, `rpcs3.cpp`). O arquivo vai para o cache do flatpak e sai depois.
public enum PS3Install {
    public enum Kind: String { case package = "installpkg", firmware = "installfw" }
    static let flatpak = "net.rpcs3.RPCS3"

    public static func run(_ source: URL, kind: Kind, config: SSHConfig, runner: any CommandRunner,
                           progress: @escaping @Sendable (Int?, String?) -> Void) async throws {
        _ = try await Flatpaks.install(flatpak, runner: runner)
        let files = RemoteFiles(runner: runner)
        let dir = try await files.home() + "/.var/app/\(flatpak)/cache/quietdeck"
        let size = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int64) ?? 0
        try await files.ensureSpace(size * 2, in: dir)
        try await Transfer.upload(source, to: dir, config: config) { p in progress(p.percent, "Sending") }
        let remote = dir + "/" + source.lastPathComponent
        progress(nil, kind == .firmware ? "Installing PS3 firmware" : "Installing the PS3 package")
        // Nesta ordem: `--headless` antes faz o parser do Qt recusar a opção (0.0.43 do Flathub).
        let r = try await runner.run(RemoteCommand("flatpak run \(flatpak) --\(kind.rawValue) \(Shell.quote(remote)) --headless", timeout: 1800), onOutput: nil)
        try await runner.check("rm -f \(Shell.quote(remote))")
        // O RPCS3 cai ao encerrar (`~manual_typemap`) mesmo depois de instalar: vale o que ficou no disco.
        let base = "~/.var/app/\(flatpak)/config/rpcs3"
        let proof = switch kind {
        case .firmware: "\(base)/dev_flash/vsh/etc/version.txt"
        case .package: "\(base)/dev_hdd0/game/\(try packageTitleID(source))/PARAM.SFO"
        }
        guard try await runner.run("test -f \(proof) && test $(( $(date +%s) - $(stat -c %Y \(proof)) )) -lt 3600").ok else {
            throw DeckError.commandFailed(command: "rpcs3 --\(kind.rawValue)", result: r)
        }
    }

    /// Content ID no cabeçalho do `.pkg` (offset 0x30, `EP9000-BCES00791_00-…`): o Title ID vem depois do `-`.
    static func packageTitleID(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 0x60) ?? Data()
        guard head.count >= 0x54 else { throw DeckError.unexpectedState("%@ isn't a PS3 package.", url.lastPathComponent) }
        let contentID = String(decoding: head[0x30..<0x54], as: UTF8.self)
        let parts = contentID.split(separator: "-")
        guard parts.count >= 2, parts[1].count >= 9 else { throw DeckError.unexpectedState("%@ isn't a PS3 package.", url.lastPathComponent) }
        return String(parts[1].prefix(9))
    }
}

/// Update de Switch no Deck passa a valer no Ryubing: `games/<TitleID base>/updates.json`, o mesmo arquivo
/// que a janela "Gerenciar atualizações" grava (`TitleUpdatesHelper.cs` da 1.3.3), com o mais novo escolhido.
public enum SwitchUpdates {
    static let gamesDirectory = ".var/app/io.github.ryubing.Ryujinx/config/Ryujinx/games"

    /// Title ID base → caminho do update de maior `[vN]`.
    static func latest(_ games: [Library.Game]) -> [String: String] {
        var best: [String: (Int, String)] = [:]
        for game in games where game.systemID == "switch" {
            guard let id = game.name.range(of: #"\[[0-9A-Fa-f]{16}\]"#, options: .regularExpression).map({ game.name[$0].dropFirst().dropLast().lowercased() }),
                  id.hasSuffix("800") else { continue }
            let version = game.name.range(of: #"\[v[0-9]+\]"#, options: .regularExpression).flatMap { Int(game.name[$0].dropFirst(2).dropLast()) } ?? 0
            let base = String(id.dropLast(3)) + "000"
            if (best[base]?.0 ?? -1) < version { best[base] = (version, game.path) }
        }
        return best.mapValues(\.1)
    }

    /// Mantém os caminhos que o usuário já tinha e escolhe o mais novo. Devolve quantos jogos mudaram.
    public static func register(_ games: [Library.Game], runner: any CommandRunner) async throws -> Int {
        let updates = latest(games)
        guard !updates.isEmpty else { return 0 }
        let files = RemoteFiles(runner: runner)
        let base = try await files.home() + "/" + gamesDirectory
        var changed = 0
        for (id, path) in updates {
            let file = "\(base)/\(id)/updates.json"
            var paths: [String] = []
            var selected = ""
            if let data = try await files.read(file), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                paths = json["paths"] as? [String] ?? []
                selected = json["selected"] as? String ?? ""
            }
            guard selected != path || !paths.contains(path) else { continue }
            if !paths.contains(path) { paths.append(path) }
            let out = try JSONSerialization.data(withJSONObject: ["selected": path, "paths": paths], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try await files.write(out, to: file)
            changed += 1
        }
        return changed
    }
}

public struct ROMCandidate: Equatable, Sendable {
    public var path: String
    public var size: Int64
    public var detection: ROMDetection
}

public enum ROMScanner {
    static func prefix(_ path: String) -> Data {
        guard let h = FileHandle(forReadingAtPath: path) else { return Data() }
        defer { try? h.close() }
        return (try? h.read(upToCount: ROMDetector.prefixLength)) ?? Data()
    }

    /// Aceita arquivos e pastas (Finder, seletor, pasta sincronizada, SMB/NFS montado).
    /// Faixas citadas por um `.cue`/`.gdi` viajam com ele e não viram jogos separados.
    /// O que não é reconhecido volta como `.unknown`: quem chama avisa, não some em silêncio.
    public static func scan(_ urls: [URL], catalog: Catalog) -> [ROMCandidate] {
        let detector = ROMDetector(systems: catalog.systems)
        var files: [URL] = []
        var folders: [ROMCandidate] = []
        func folderGame(_ url: URL) -> Bool {
            guard let system = GameFolder.system(url) else { return false }
            folders.append(ROMCandidate(path: url.path, size: folderSize(url), detection: .system(system)))
            // Patch `.pkg` que veio junto na raiz da pasta do disco também vale.
            let loose = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            files += loose.filter { $0.pathExtension.lowercased() == "pkg" }
            return true
        }
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if folderGame(url) { continue }
                let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey], options: [.skipsHiddenFiles])
                while let item = walker?.nextObject() as? URL {
                    let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
                    if values?.isDirectory == true, folderGame(item) { walker?.skipDescendants() }
                    if values?.isRegularFile == true { files.append(item) }
                }
            } else {
                files.append(url)
            }
        }
        var members = Set<String>()
        for file in files where ["cue", "gdi"].contains(file.pathExtension.lowercased()) {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            for name in ROMPlan.referencedFiles(cueSheet: text, extension: file.pathExtension) {
                members.insert(file.deletingLastPathComponent().appendingPathComponent(name).standardizedFileURL.path)
            }
        }
        return folders + files.compactMap { file in
            guard !members.contains(file.standardizedFileURL.path) else { return nil }
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
            var head = prefix(file.path)
            if ["cue", "gdi"].contains(file.pathExtension.lowercased()) {
                // O cabeçalho de um disco está na primeira faixa, não no índice.
                let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                if let first = ROMPlan.referencedFiles(cueSheet: text, extension: file.pathExtension).first {
                    head = prefix(file.deletingLastPathComponent().appendingPathComponent(first).path)
                }
            }
            return ROMCandidate(path: file.path, size: size, detection: detector.detect(path: file.path, prefix: head, size: size))
        }
    }
}

extension ROMScanner {
    static func folderSize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        while let item = walker?.nextObject() as? URL {
            total += Int64((try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Separa o que é BIOS conhecida pelo hash; o tamanho evita ler jogos inteiros à toa.
    public static func biosFiles(_ urls: [URL], table: [BIOSEntry]) async -> [String] {
        let sizes = Set(table.map { Int64($0.size) })
        var files: [URL] = []
        for url in urls {
            if let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                while let item = walker.nextObject() as? URL { files.append(item) }
            } else {
                files.append(url)
            }
        }
        var found: [String] = []
        for file in files {
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? -1
            guard sizes.contains(size), let sha1 = try? await LocalHash.compute(file.path, algorithm: 1) else { continue }
            if BIOS.match(sha1: sha1, table: table) != nil { found.append(file.path) }
        }
        return found
    }
}

public struct ROMImportResult: Equatable, Sendable {
    public var remotePath: String
    public var skippedAsDuplicate: Bool
    /// Tudo que este jogo ocupa no Deck, para poder remover depois.
    public var files: [String] = []
}

public struct RomImporter: Sendable {
    public let runner: any CommandRunner
    public let config: SSHConfig
    public let catalog: Catalog
    public let workRoot: URL

    public init(runner: any CommandRunner, config: SSHConfig, catalog: Catalog, workRoot: URL) {
        self.runner = runner
        self.config = config
        self.catalog = catalog
        self.workRoot = workRoot
    }

    public typealias Progress = @Sendable (Int?, String?) -> Void
    static let indexPath = ".local/share/quietdeck/rom-index.tsv"

    /// Mapa `hash da origem → arquivo no Deck`. Conferido no Deck: um arquivo apagado à mão reenvia.
    func duplicate(of hash: String, files: RemoteFiles, home: String) async throws -> String? {
        guard let data = try await files.read(home + "/" + Self.indexPath) else { return nil }
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let f = line.split(separator: "\t").map(String.init)
            guard f.count == 3, f[0] == hash else { continue }
            let size = try await runner.run("stat -c %s \(Shell.quote(f[1])) 2>/dev/null")
            if size.trimmed == f[2] { return f[1] }
        }
        return nil
    }

    func record(hash: String, path: String, size: Int64, home: String) async throws {
        let index = Shell.quote(home + "/" + Self.indexPath)
        let line = Shell.quote("\(hash)\t\(path)\t\(size)")
        try await runner.check("mkdir -p \"$(dirname \(index))\" && printf '%s\\n' \(line) >> \(index)")
    }

    private func run(_ tool: String, _ args: [String], _ label: String) async throws {
        let r = try await LocalProcess.run(tool, args)
        guard r.ok else { throw DeckError.commandFailed(command: label, result: r) }
    }

    /// Pasta de trabalho por hash: repetir aproveita a extração e o CHD já prontos.
    private func extract(_ source: URL, to dir: URL) async throws {
        let marker = dir.appendingPathComponent(".done")
        if FileManager.default.fileExists(atPath: marker.path) { return }
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if source.pathExtension.lowercased() == "zip" {
            try await run("/usr/bin/unzip", ["-o", "-q", source.path, "-d", dir.path], "unzip")
        } else {
            let tool = try await LocalTools.require(["7zz", "7z"], formula: "sevenzip")
            try await run(tool, ["x", "-y", "-o\(dir.path)", source.path], "7z")
        }
        FileManager.default.createFile(atPath: marker.path, contents: nil)
    }

    private func convert(_ input: URL, mode: ROMPlan.Conversion, work: URL) async throws -> URL {
        let output = work.appendingPathComponent(input.deletingPathExtension().lastPathComponent + ".chd")
        if FileManager.default.fileExists(atPath: output.path) { return output }
        let tool = try await LocalTools.require(["chdman"], formula: "rom-tools")
        // Só um CHD completo ganha o nome final: chdman interrompido deixa arquivo pela metade.
        let partial = output.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)
        try await run(tool, [mode.rawValue, "-i", input.path, "-o", partial.path, "-f"], "chdman \(mode.rawValue)")
        try FileManager.default.moveItem(at: partial, to: output)
        return output
    }

    /// `.nsz` vira `.nsp` e `.xcz` vira `.xci`. Só um resultado completo ganha a pasta final.
    static func decompress(_ input: URL, work: URL, tool: String? = nil) async throws -> URL {
        let stem = input.deletingPathExtension().lastPathComponent
        let extensions = ["nsp", "xci"]
        func output(in dir: URL) -> URL? {
            try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first { extensions.contains($0.pathExtension.lowercased()) }
        }
        let done = work.appendingPathComponent("decompressed-" + stem)
        if let ready = output(in: done) { return ready }
        let partial = work.appendingPathComponent("decompressing-" + stem)
        try? FileManager.default.removeItem(at: partial)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        let nsz = if let tool { tool } else { try await LocalTools.nsz() }
        let r = try await LocalProcess.run(nsz, ["-D", "--verify", "-o", partial.path, input.path])
        if r.stdout.contains("Could not load keys file") || r.stderr.contains("Could not load keys file") {
            throw DeckError.unexpectedState("Switch keys are missing. Drop your own prod.keys on Library, then try again.")
        }
        guard r.ok else { throw DeckError.commandFailed(command: "nsz -D", result: r) }
        guard output(in: partial) != nil else { throw DeckError.unexpectedState("nsz finished without creating a game from %@.", input.lastPathComponent) }
        try? FileManager.default.removeItem(at: done)
        try FileManager.default.moveItem(at: partial, to: done)
        guard let ready = output(in: done) else { throw DeckError.unexpectedState("nsz finished without creating a game from %@.", input.lastPathComponent) }
        return ready
    }

    /// Aplica o patch numa cópia com nome próprio: a original não muda e pode já estar no Deck.
    /// Num `.cue`/`.gdi` o patch vale para a primeira faixa, e as faixas ganham o novo nome.
    static func patched(_ entry: URL, with patch: URL, named name: String, work: URL, xdelta: String? = nil) async throws -> URL {
        let ext = entry.pathExtension.lowercased()
        guard !["chd", "rvz", "wia", "gcz", "cso", "wbfs", "nsp", "nsz", "xci", "xcz"].contains(ext) else {
            throw DeckError.unexpectedState("A patch can't be applied to %@. Use the original .bin, .iso or .cue instead.", entry.lastPathComponent)
        }
        let dir = work.appendingPathComponent("patched-" + (name as NSString).deletingPathExtension)
        let output = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: output.path) { return output }
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard ["cue", "gdi"].contains(ext) else {
            try await apply(patch, to: entry, output: output, xdelta: xdelta)
            return output
        }
        let sheet = try String(contentsOf: entry, encoding: .utf8)
        let tracks = ROMPlan.referencedFiles(cueSheet: sheet, extension: ext)
        let stem = (name as NSString).deletingPathExtension
        var renamed: [String: String] = [:]
        for (i, track) in tracks.enumerated() {
            let new = "\(stem) (Track \(i + 1)).\((track as NSString).pathExtension)"
            renamed[track] = new
            let from = entry.deletingLastPathComponent().appendingPathComponent(track)
            if i == 0 {
                try await apply(patch, to: from, output: dir.appendingPathComponent(new), xdelta: xdelta)
            } else {
                try FileManager.default.copyItem(at: from, to: dir.appendingPathComponent(new))
            }
        }
        // Uma troca por linha: cada linha cita um arquivo só, e o nome novo contém o antigo.
        let lines = sheet.components(separatedBy: "\n").map { line in
            guard let track = tracks.sorted(by: { $0.count > $1.count }).first(where: { line.contains($0) }) else { return line }
            return line.replacingOccurrences(of: track, with: renamed[track]!)
        }
        // A folha vai por último: ela existir é o sinal de que tudo ficou pronto.
        try lines.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8)
        return output
    }

    private static func apply(_ patch: URL, to source: URL, output: URL, xdelta: String?) async throws {
        let label = patch.lastPathComponent
        if ["xdelta", "vcdiff"].contains(patch.pathExtension.lowercased()) {
            let tool = if let xdelta { xdelta } else { try await LocalTools.require(["xdelta3"], formula: "xdelta") }
            let partial = output.appendingPathExtension("partial")
            let r = try await LocalProcess.run(tool, ["-d", "-f", "-s", source.path, patch.path, partial.path])
            guard r.ok else {
                try? FileManager.default.removeItem(at: partial)
                // 3.2 confere o BLAKE3 da origem; patches de 3.0 só acusam no checksum da janela.
                if r.stderr.contains("mismatch") || r.stderr.contains("does not match") { throw DeckError.unexpectedState("%@ was made for another version of this game. Check the CRC32 or SHA-1 its readme asks for.", label) }
                throw DeckError.commandFailed(command: "xdelta3 -d", result: r)
            }
            try FileManager.default.moveItem(at: partial, to: output)
            return
        }
        do {
            try ROMPatch.apply(try Data(contentsOf: patch), to: try Data(contentsOf: source)).write(to: output, options: .atomic)
        } catch ROMPatch.Failure.wrongSource {
            throw DeckError.unexpectedState("%@ was made for another version of this game. Check the CRC32 or SHA-1 its readme asks for.", label)
        } catch is ROMPatch.Failure {
            throw DeckError.unexpectedState("%@ is damaged or isn't a patch QuietDeck can apply.", label)
        }
    }

    /// Arquivos que acompanham o ponto de entrada quando ele vai sem conversão.
    private func companions(of entry: URL) -> [URL] {
        guard ["cue", "gdi"].contains(entry.pathExtension.lowercased()),
              let text = try? String(contentsOf: entry, encoding: .utf8) else { return [entry] }
        let dir = entry.deletingLastPathComponent()
        return [entry] + ROMPlan.referencedFiles(cueSheet: text, extension: entry.pathExtension).map { dir.appendingPathComponent($0) }
    }

    public func importGame(path: String, systemID: String, paths: EmulationPaths, patch: String? = nil, progress: @escaping Progress) async throws -> ROMImportResult {
        guard let system = catalog.system(systemID) else { throw DeckError.unexpectedState("Unknown system: %@", systemID) }
        let source = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            throw DeckError.unexpectedState("%@ isn't there anymore. Check that the network share is mounted.", source.lastPathComponent)
        }
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        // Pasta de jogo (PS3, PS4) e `.pkg`; o resto (ISO de PS3) segue o caminho de arquivo.
        if system.entry != nil, isDirectory.boolValue || source.pathExtension.lowercased() == "pkg" {
            guard patch == nil else { throw DeckError.unexpectedState("Patches aren't supported for %@ games.", system.name) }
            return try await importFolder(source, system: system, paths: paths, progress: progress)
        }
        let files = RemoteFiles(runner: runner)
        let home = try await files.home()

        progress(nil, "Checking for duplicates")
        var hash = try await LocalHash.compute(path, algorithm: 256)
        if let patch {
            guard FileManager.default.fileExists(atPath: patch) else {
                throw DeckError.unexpectedState("%@ isn't there anymore. Check that the network share is mounted.", (patch as NSString).lastPathComponent)
            }
            // Traduzida e original são jogos diferentes no índice.
            hash += "+" + (try await LocalHash.compute(patch, algorithm: 256)).prefix(16)
        }
        if let existing = try await duplicate(of: hash, files: files, home: home) {
            progress(100, "Already on the Deck")
            return ROMImportResult(remotePath: existing, skippedAsDuplicate: true, files: [existing])
        }

        let work = workRoot.appendingPathComponent(hash)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        // Cancelado pelo usuário: extração e conversão no Mac não vão ser retomadas.
        defer { if Task.isCancelled { try? FileManager.default.removeItem(at: work) } }
        var entries = [source]
        var patches: [URL: URL] = [:]
        let archive = ["zip", "7z"].contains(source.pathExtension.lowercased())
        // O patch vale para a ROM, não para o compactado: com patch, sempre extrai.
        if ROMPlan.mustExtract(system: system, fileExtension: source.pathExtension) || (archive && patch != nil) {
            progress(nil, "Extracting")
            let dir = work.appendingPathComponent("extracted")
            try await extract(source, to: dir)
            let found = ROMScanner.scan([dir], catalog: catalog)
            entries = found.filter { $0.detection != .unknown }.map { URL(fileURLWithPath: $0.path) }
            guard !entries.isEmpty else { throw DeckError.unexpectedState("No game found inside %@.", source.lastPathComponent) }
            // Pacote de tradução costuma trazer o patch junto da ROM.
            let inside = patch.map { [$0] } ?? found.map(\.path).filter(ROMPatch.isPatch)
            for (rom, p) in ROMPatch.pair(roms: entries.map(\.path), patches: inside) {
                patches[URL(fileURLWithPath: rom)] = URL(fileURLWithPath: p)
            }
        } else if let patch {
            patches[source] = URL(fileURLWithPath: patch)
        }
        if !patches.isEmpty {
            progress(nil, "Applying patch")
            for (i, entry) in entries.enumerated() {
                guard let p = patches[entry] else { continue }
                // O nome segue o que a Biblioteca mostrou, para o atalho achar o jogo. Patch que veio
                // dentro do pacote faz do pacote o jogo traduzido, então fica o nome dele.
                let shown = entries.count == 1 ? source.deletingPathExtension().lastPathComponent + "." + entry.pathExtension : entry.lastPathComponent
                let name = patch == nil ? shown : ROMPatch.patchedName(rom: shown, patch: p.path)
                entries[i] = try await Self.patched(entry, with: p, named: name, work: work)
            }
        }

        var outputs: [URL] = []
        for entry in entries {
            let size = (try? FileManager.default.attributesOfItem(atPath: entry.path)[.size] as? Int64) ?? 0
            if ROMPlan.mustDecompress(fileExtension: entry.pathExtension) {
                progress(nil, "Decompressing")
                outputs.append(try await Self.decompress(entry, work: work))
            } else if let mode = ROMPlan.conversion(for: system, fileExtension: entry.pathExtension, size: size) {
                progress(nil, "Converting to CHD")
                outputs.append(try await convert(entry, mode: mode, work: work))
            } else {
                outputs += companions(of: entry)
            }
        }

        let directory = "\(paths.roms)/\(system.folder)"
        let total = outputs.reduce(Int64(0)) { $0 + ((try? FileManager.default.attributesOfItem(atPath: $1.path)[.size] as? Int64) ?? 0) }
        try await files.ensureSpace(total, in: directory)
        for (i, output) in outputs.enumerated() {
            let count = outputs.count
            try await Transfer.upload(output, to: directory, config: config) { p in
                progress((i * 100 + p.percent) / count, "Sending")
            }
        }

        let main = directory + "/" + outputs[0].lastPathComponent
        let mainSize = (try? FileManager.default.attributesOfItem(atPath: outputs[0].path)[.size] as? Int64) ?? 0
        let verified = try await runner.run("stat -c %s \(Shell.quote(main))").trimmed
        guard verified == String(mainSize) else { throw DeckError.unexpectedState("The file on the Deck has %@ bytes instead of %@. Try again.", verified, String(mainSize)) }
        try await record(hash: hash, path: main, size: mainSize, home: home)
        let playlist = try await updatePlaylist(for: outputs[0].lastPathComponent, directory: directory)
        // Pastas de trabalho crescem como as ROMs: depois de confirmar no Deck, não servem mais.
        try? FileManager.default.removeItem(at: work)
        return ROMImportResult(remotePath: playlist ?? main, skippedAsDuplicate: false, files: outputs.map { directory + "/" + $0.lastPathComponent })
    }

    /// Jogo em pasta (PS4) vai inteiro, com o nome tirado do `param.sfo`. O `.pkg` precisa ser
    /// extraído antes: o shadPS4 não instala pacotes pela linha de comando.
    func importFolder(_ source: URL, system: GameSystem, paths: EmulationPaths, progress: @escaping Progress) async throws -> ROMImportResult {
        if system.id == "ps3", source.pathExtension.lowercased() == "pkg" {
            try await PS3Install.run(source, kind: .package, config: config, runner: runner, progress: progress)
            return ROMImportResult(remotePath: "", skippedAsDuplicate: false, files: [])
        }
        guard let entryName = system.entry, GameFolder.system(source) == system.id else {
            throw DeckError.unexpectedState("%@ isn't an extracted %@ game. Drop the game folder (CUSA…, with eboot.bin and sce_sys) instead of the .pkg.", source.lastPathComponent, system.name)
        }
        let files = RemoteFiles(runner: runner)
        let home = try await files.home()
        let entry = source.appendingPathComponent(entryName)
        progress(nil, "Checking for duplicates")
        let hash = try await LocalHash.compute(entry.path, algorithm: 256)
        if let existing = try await duplicate(of: hash, files: files, home: home) {
            progress(100, "Already on the Deck")
            return ROMImportResult(remotePath: existing, skippedAsDuplicate: true, files: [(existing as NSString).deletingLastPathComponent])
        }
        let name = GameFolder.folderName(source)
        let directory = "\(paths.roms)/\(system.folder)"
        try await files.ensureSpace(ROMScanner.folderSize(source), in: directory)
        try await Transfer.upload(source, to: directory, named: name, config: config) { p in progress(p.percent, "Sending") }
        let remoteEntry = "\(directory)/\(name)/\(entryName)"
        let size = (try? FileManager.default.attributesOfItem(atPath: entry.path)[.size] as? Int64) ?? 0
        let verified = try await runner.run("stat -c %s \(Shell.quote(remoteEntry))").trimmed
        guard verified == String(size) else { throw DeckError.unexpectedState("The file on the Deck has %@ bytes instead of %@. Try again.", verified, String(size)) }
        try await record(hash: hash, path: remoteEntry, size: size, home: home)
        return ROMImportResult(remotePath: remoteEntry, skippedAsDuplicate: false, files: ["\(directory)/\(name)"])
    }

    /// Olha a pasta real: os discos podem ter chegado em trabalhos diferentes.
    func updatePlaylist(for fileName: String, directory: String) async throws -> String? {
        guard let base = ROMPlan.discInfo(fileName)?.base else { return nil }
        let listing = try await runner.check("ls -1 \(Shell.quote(directory))").stdout.split(whereSeparator: \.isNewline).map(String.init)
        let discs = listing.filter { ROMPlan.discInfo($0)?.base == base && !$0.lowercased().hasSuffix(".m3u") }
        guard let playlist = ROMPlan.playlists(for: discs).first else { return nil }
        let path = directory + "/" + playlist.name
        let files = RemoteFiles(runner: runner)
        if try await files.read(path) != Data(playlist.contents.utf8) { try await files.write(Data(playlist.contents.utf8), to: path) }
        return path
    }
}

public enum Library {
    public static func listing(paths: EmulationPaths) -> String {
        // Pasta ainda inexistente (nada enviado para aquele destino) é biblioteca vazia, não erro.
        "if [ -d \(Shell.quote(paths.roms)) ]; then cd \(Shell.quote(paths.roms)) && find . -mindepth 2 -maxdepth 4 -type f -printf '%s\\t%P\\n'; fi"
    }

    public struct Game: Equatable, Identifiable, Sendable {
        public var systemID: String
        public var name: String
        public var path: String
        public var size: Int64
        public var id: String { path }
    }

    public static func parse(_ text: String, systems: [GameSystem], paths: EmulationPaths) -> [Game] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard f.count == 2, let size = Int64(f[0]) else { return nil }
            let relative = f[1], name = (relative as NSString).lastPathComponent
            // Escondido é envio em andamento (`.quietdeck-partial/`, `.<nome>.XXXXXX` do rsync): virava atalho
            // apontando para um arquivo pela metade.
            guard !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }),
                  let system = systems.first(where: { relative.hasPrefix($0.folder + "/") }) else { return nil }
            // Jogo em pasta: o nome é o da pasta, e só o arquivo de entrada conta.
            if let entry = system.entry {
                // `<pasta do sistema>/<jogo>/<entry>`; entry pode ter subpastas (PS3_GAME/PARAM.SFO).
                let parts = relative.split(separator: "/").map(String.init)
                let depth = entry.split(separator: "/").count
                if parts.count == 2 + depth, parts.suffix(depth).joined(separator: "/") == entry, parts[0] == system.folder {
                    return Game(systemID: system.id, name: parts[1], path: "\(paths.roms)/\(relative)", size: size)
                }
                // Arquivo solto ao lado (ISO de PS3) segue a regra da extensão; o resto da pasta não é jogo.
                guard parts.count == 2 else { return nil }
            }
            guard system.extensions.contains((name as NSString).pathExtension.lowercased()) else { return nil }
            return Game(systemID: system.id, name: name, path: "\(paths.roms)/\(relative)", size: size)
        }
    }

    /// O `.m3u` representa o conjunto de discos; sem ele, o primeiro arquivo do título.
    public static func pick(_ ref: GameRef, in games: [Game]) -> Game? {
        let matches = games.filter { $0.systemID == ref.systemID && ROMPlan.displayName($0.name) == ref.title && !ROMPlan.isSwitchAddon($0.name) }
        return matches.first { $0.name.lowercased().hasSuffix(".m3u") } ?? matches.sorted { $0.name < $1.name }.first
    }

    /// Exe, diretório e argumentos do atalho. Steam interpreta aspas duplas em `LaunchOptions`.
    public static func shortcut(name: String, romPath: String, system: GameSystem, catalog: Catalog, corePath: String?) -> Shortcut? {
        guard let emulator = catalog.emulator(system.emulator(for: (romPath as NSString).lastPathComponent)), emulator.isAvailable,
              let template = emulator.launch else { return nil }
        func q(_ s: String) -> String { "\"\(s)\"" }
        // Jogo em pasta: o emulador abre `boot` (PS3: o EBOOT.BIN), e a Biblioteca acha o jogo por `entry`.
        var romPath = romPath
        if let entry = system.entry, let boot = system.boot, romPath.hasSuffix("/" + entry) {
            romPath = String(romPath.dropLast(entry.count)) + boot
        }
        let options = template.replacingOccurrences(of: "{rom}", with: q(romPath)).replacingOccurrences(of: "{core}", with: q(corePath ?? ""))
        return Shortcut(name: name, exe: "/usr/bin/flatpak", startDir: "/usr/bin", launchOptions: options, tags: [system.name])
    }
}
