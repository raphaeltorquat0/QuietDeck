import Foundation
import DeckKit

/// Varredura incremental: só calcula hash do que mudou de tamanho ou data.
public enum ShelfScanner {
    static let headBytes = 0x11000
    static let textExtensions: Set<String> = ["cue", "gdi"]

    public typealias Cache = [String: ScanRecord]

    public static func cache(_ records: [ScanRecord]) -> Cache {
        Dictionary(records.map { ($0.path, $0) }, uniquingKeysWith: { _, b in b })
    }

    /// Pastas reconhecidas dispensam ler o início do arquivo.
    static func knownFolders(_ systems: [GameSystem]) -> Set<String> {
        Set(systems.flatMap { [$0.id] + $0.aliases })
    }

    public static func scanFolder(_ root: URL, systems: [GameSystem], cache: Cache) async throws -> [ScanRecord] {
        let known = knownFolders(systems)
        let urls = walk(root)
        var records: [ScanRecord] = []
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]), v.isRegularFile == true else { continue }
            let size = Int64(v.fileSize ?? 0), mtime = Int64(v.contentModificationDate?.timeIntervalSince1970 ?? 0)
            if let old = cache[url.path], old.size == size, old.mtime == mtime {
                records.append(old)
                continue
            }
            // Arquivo ilegível fica de fora; não derruba a varredura do resto.
            guard let sha1 = try? await LocalHash.compute(url.path, algorithm: 1), let crc = try? crc32(url) else { continue }
            var record = ScanRecord(path: url.path, size: size, mtime: mtime, crc: crc, sha1: sha1)
            let ext = url.pathExtension.lowercased()
            if textExtensions.contains(ext) { record.text = try? String(contentsOf: url, encoding: .utf8) }
            if !known.contains(url.deletingLastPathComponent().lastPathComponent.lowercased()) {
                record.head = ROMScanner.prefix(url.path).prefix(headBytes).base64EncodedString()
            }
            if ROMScanner.prefix(url.path).starts(with: [0x4E, 0x45, 0x53, 0x1A]) { record.headerless = try? await headerlessSHA1(url.path) }
            records.append(record)
        }
        return records
    }

    private static func headerlessSHA1(_ path: String) async throws -> String? {
        let r = try await LocalProcess.run("/bin/sh", ["-c", "tail -c +17 \"$1\" | /usr/bin/shasum -a 1", "sh", path])
        return r.ok ? r.stdout.split(separator: " ").first.map(String.init) : nil
    }

    /// O `enumerator` do Foundation não vê nada num CIFS montado no Linux e não avisa quando desiste.
    /// Pasta ilegível fica de fora sozinha; link para pasta não é seguido, para não entrar em laço.
    private static func walk(_ root: URL) -> [URL] {
        var pending = [root], files: [URL] = []
        while let folder = pending.popLast() {
            let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            for entry in entries {
                if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { pending.append(entry) } else { files.append(entry) }
            }
        }
        return files
    }

    static func crc32(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var crc = ~UInt32(0)
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { crc = CRC32.update(crc, chunk) }
        return String(format: "%08x", ~crc)
    }

    /// Mesma varredura no servidor: o cache vai pela entrada padrão e os hashes são calculados lá.
    static let remoteScript = #"""
    import base64, hashlib, json, os, sys, zlib
    root, known = sys.argv[1], set(sys.argv[2].split(","))
    cache = json.load(sys.stdin)
    for base, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for name in files:
            if name.startswith("."):
                continue
            p = os.path.join(base, name)
            try:
                st = os.stat(p)
                old = cache.get(p)
                if old and old["size"] == st.st_size and old["mtime"] == int(st.st_mtime):
                    print(json.dumps(old))
                    continue
                sha, crc = hashlib.sha1(), 0
                with open(p, "rb") as f:
                    head = f.read(0x11000)
                    raw, skip = (hashlib.sha1(), 16) if head[:4] == b"NES\x1a" else (None, 0)
                    chunk = head
                    while chunk:
                        sha.update(chunk)
                        crc = zlib.crc32(chunk, crc)
                        if raw:
                            raw.update(chunk[skip:])
                            skip = 0
                        chunk = f.read(1 << 20)
            except OSError:
                continue
            r = {"path": p, "size": st.st_size, "mtime": int(st.st_mtime), "crc": "%08x" % (crc & 0xffffffff), "sha1": sha.hexdigest()}
            if raw:
                r["headerless"] = raw.hexdigest()
            if os.path.basename(base).lower() not in known:
                r["head"] = base64.b64encode(head).decode()
            if name.lower().rsplit(".", 1)[-1] in ("cue", "gdi"):
                r["text"] = head.decode("utf-8", "replace")
            print(json.dumps(r))
    """#

    public static func scanRemote(_ runner: any CommandRunner, root: String, systems: [GameSystem], cache: Cache) async throws -> [ScanRecord] {
        let known = knownFolders(systems).sorted().joined(separator: ",")
        let payload = Dictionary(uniqueKeysWithValues: cache.map { ($0.key, $0.value) })
        let stdin = try JSONEncoder().encode(payload)
        let r = try await runner.check(RemoteCommand("python3 -c \(Shell.quote(remoteScript)) \(Shell.quote(root)) \(Shell.quote(known))", stdin: stdin, timeout: 3600))
        return try r.stdout.split(whereSeparator: \.isNewline).map { try JSONDecoder().decode(ScanRecord.self, from: Data($0.utf8)) }
    }

    /// Com o serviço, o índice já está pronto no servidor.
    public static func scanService(_ url: String, token: String) async throws -> [ScanRecord] {
        try await PublicAPI.get(url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/index", headers: ["Authorization": "Bearer \(token)"])
    }

    /// DATs fornecidos pelo usuário ficam em `~/Library/Application Support/QuietDeck/dats`.
    public static func loadDats(_ folder: URL) -> DatIndex {
        var index = DatIndex()
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where ["dat", "xml"].contains(file.pathExtension.lowercased()) {
            if let data = try? Data(contentsOf: file) { index.load(data) }
        }
        return index
    }
}
