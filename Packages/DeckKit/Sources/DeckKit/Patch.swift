import Foundation

/// Patches de tradução e correção. IPS, UPS e BPS são aplicados aqui; xdelta precisa do `xdelta3`.
public enum ROMPatch {
    public static let extensions: Set<String> = ["ips", "ups", "bps", "xdelta", "vcdiff"]

    public enum Failure: Error, Equatable {
        case invalid
        /// O patch é de outra versão da ROM: UPS e BPS guardam o CRC32 da original.
        case wrongSource
        case corrupt
    }

    public static func isPatch(_ path: String) -> Bool {
        extensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Patch com o mesmo nome da ROM ganha dela; sem par pelo nome, só vale se houver uma ROM só.
    public static func pair(roms: [String], patches: [String]) -> [String: String] {
        func stem(_ p: String) -> String { ((p as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased() }
        var result: [String: String] = [:]
        for patch in patches {
            if let rom = roms.first(where: { stem($0) == stem(patch) }) {
                result[rom] = patch
            } else if roms.count == 1, result[roms[0]] == nil {
                result[roms[0]] = patch
            }
        }
        return result
    }

    /// Nome do arquivo traduzido: nunca o da original, que pode já estar no Deck.
    public static func patchedName(rom: String, patch: String) -> String {
        let r = (rom as NSString).lastPathComponent as NSString
        let p = ((patch as NSString).lastPathComponent as NSString).deletingPathExtension
        let tag = p.lowercased() == r.deletingPathExtension.lowercased() ? "Patched" : p
        return "\(r.deletingPathExtension) (\(tag)).\(r.pathExtension)"
    }

    public static func apply(_ patch: Data, to source: Data) throws -> Data {
        let p = [UInt8](patch)
        if p.starts(with: Array("PATCH".utf8)) { return try ips(p, source) }
        if p.starts(with: Array("UPS1".utf8)) { return try withHeaderRetry(source) { try ups(p, $0) } }
        if p.starts(with: Array("BPS1".utf8)) { return try withHeaderRetry(source) { try bps(p, $0) } }
        throw Failure.invalid
    }

    /// ROM de SNES com cabeçalho de copiadora (512 bytes) é a mesma ROM para quem fez o patch.
    private static func withHeaderRetry(_ source: Data, _ body: ([UInt8]) throws -> Data) throws -> Data {
        do { return try body([UInt8](source)) } catch Failure.wrongSource where source.count % 1024 == 512 {
            return try body([UInt8](source.dropFirst(512)))
        }
    }

    private static func ips(_ p: [UInt8], _ source: Data) throws -> Data {
        var out = [UInt8](source)
        var i = 5
        func take(_ n: Int) throws -> Int {
            guard i + n <= p.count else { throw Failure.corrupt }
            defer { i += n }
            return p[i..<i + n].reduce(0) { $0 << 8 | Int($1) }
        }
        while true {
            guard i + 3 <= p.count else { throw Failure.corrupt }
            if p[i..<i + 3].elementsEqual("EOF".utf8) {
                i += 3
                if i + 3 <= p.count { out = Array(out.prefix(try take(3))) }
                return Data(out)
            }
            let offset = try take(3)
            var size = try take(2)
            let bytes: [UInt8]
            if size == 0 {
                size = try take(2)
                bytes = Array(repeating: UInt8(try take(1)), count: size)
            } else {
                guard i + size <= p.count else { throw Failure.corrupt }
                bytes = Array(p[i..<i + size])
                i += size
            }
            if out.count < offset + size { out += Array(repeating: 0, count: offset + size - out.count) }
            out.replaceSubrange(offset..<offset + size, with: bytes)
        }
    }

    /// Inteiro de tamanho variável dos formatos UPS e BPS, do byuu.
    private static func number(_ p: [UInt8], _ i: inout Int, limit: Int) throws -> Int {
        var value = 0, shift = 1
        while true {
            guard i < limit, shift < 1 << 56 else { throw Failure.corrupt }
            let x = Int(p[i]); i += 1
            value += (x & 0x7F) * shift
            if x & 0x80 != 0 { return value }
            shift <<= 7
            value += shift
        }
    }

    private static func footer(_ p: [UInt8], _ source: [UInt8]) throws -> (target: UInt32, end: Int) {
        guard p.count >= 16 else { throw Failure.corrupt }
        func le(_ at: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(p[at + $1]) << (8 * $1) } }
        let end = p.count - 12
        guard CRC32.checksum(Data(p[..<(p.count - 4)])) == le(p.count - 4) else { throw Failure.corrupt }
        guard CRC32.checksum(Data(source)) == le(end) else { throw Failure.wrongSource }
        return (le(end + 4), end)
    }

    private static func ups(_ p: [UInt8], _ source: [UInt8]) throws -> Data {
        let (target, end) = try footer(p, source)
        var i = 4
        let sourceSize = try number(p, &i, limit: end), targetSize = try number(p, &i, limit: end)
        guard sourceSize == source.count else { throw Failure.wrongSource }
        var out = Array(source.prefix(targetSize)) + Array(repeating: 0, count: max(0, targetSize - source.count))
        var pos = 0
        while i < end {
            pos += try number(p, &i, limit: end)
            while true {
                guard i < end else { throw Failure.corrupt }
                let x = p[i]; i += 1
                if pos < targetSize { out[pos] ^= x }
                pos += 1
                if x == 0 { break }
            }
        }
        guard CRC32.checksum(Data(out)) == target else { throw Failure.corrupt }
        return Data(out)
    }

    private static func bps(_ p: [UInt8], _ source: [UInt8]) throws -> Data {
        let (target, end) = try footer(p, source)
        var i = 4
        let sourceSize = try number(p, &i, limit: end), targetSize = try number(p, &i, limit: end)
        i += try number(p, &i, limit: end)
        guard sourceSize == source.count else { throw Failure.wrongSource }
        guard i <= end else { throw Failure.corrupt }
        var out: [UInt8] = []
        out.reserveCapacity(targetSize)
        var sourceRel = 0, targetRel = 0
        func signed(_ v: Int) -> Int { (v & 1 == 1 ? -1 : 1) * (v >> 1) }
        while i < end {
            let d = try number(p, &i, limit: end)
            let length = (d >> 2) + 1
            switch d & 3 {
            case 0:
                guard out.count + length <= source.count else { throw Failure.corrupt }
                out += source[out.count..<out.count + length]
            case 1:
                guard i + length <= end else { throw Failure.corrupt }
                out += p[i..<i + length]; i += length
            case 2:
                sourceRel += signed(try number(p, &i, limit: end))
                guard sourceRel >= 0, sourceRel + length <= source.count else { throw Failure.corrupt }
                out += source[sourceRel..<sourceRel + length]; sourceRel += length
            default:
                targetRel += signed(try number(p, &i, limit: end))
                for _ in 0..<length {
                    guard targetRel >= 0, targetRel < out.count else { throw Failure.corrupt }
                    out.append(out[targetRel]); targetRel += 1
                }
            }
        }
        guard out.count == targetSize, CRC32.checksum(Data(out)) == target else { throw Failure.corrupt }
        return Data(out)
    }
}
