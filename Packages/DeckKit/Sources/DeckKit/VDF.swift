import Foundation

/// Binary VDF, o formato de `shortcuts.vdf`. Só existem mapas, strings e inteiros de 32 bits;
/// a ordem das chaves importa para o Steam, por isso o mapa é uma lista de pares.
public indirect enum VDFValue: Equatable, Sendable {
    case map([(key: String, value: VDFValue)])
    case string(String)
    case int32(Int32)
    /// Tipos que o Steam grava em outros arquivos binários: preservados byte a byte no round-trip.
    case uint64(UInt64)
    case float32(UInt32)

    public static func == (a: VDFValue, b: VDFValue) -> Bool {
        switch (a, b) {
        case let (.map(x), .map(y)):
            x.count == y.count && zip(x, y).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        case let (.string(x), .string(y)): x == y
        case let (.int32(x), .int32(y)): x == y
        case let (.uint64(x), .uint64(y)): x == y
        case let (.float32(x), .float32(y)): x == y
        default: false
        }
    }

    public subscript(key: String) -> VDFValue? {
        guard case let .map(pairs) = self else { return nil }
        // O Steam compara chaves sem diferenciar caixa: `appid` e `AppName` variam entre versões.
        return pairs.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }
}

public enum VDFError: Error, Equatable, CustomStringConvertible {
    case truncated(offset: Int)
    case unknownType(UInt8, offset: Int)
    case invalidUTF8(offset: Int)
    case trailingBytes(offset: Int)

    public var description: String {
        switch self {
        case let .truncated(o): "VDF truncado no byte \(o)"
        case let .unknownType(t, o): "VDF com tipo desconhecido 0x\(String(t, radix: 16)) no byte \(o)"
        case let .invalidUTF8(o): "VDF com texto inválido no byte \(o)"
        case let .trailingBytes(o): "VDF com dados depois do fim, no byte \(o)"
        }
    }
}

public enum VDF {
    private static let map: UInt8 = 0x00, string: UInt8 = 0x01, int32: UInt8 = 0x02,
                       float: UInt8 = 0x03, uint64: UInt8 = 0x07, end: UInt8 = 0x08

    public static func parse(_ data: Data) throws -> VDFValue {
        var p = Parser(bytes: [UInt8](data))
        let root = try p.pairs()
        guard p.offset == p.bytes.count else { throw VDFError.trailingBytes(offset: p.offset) }
        return .map(root)
    }

    public static func serialize(_ value: VDFValue) -> Data {
        var out = [UInt8]()
        guard case let .map(pairs) = value else { return Data() }
        write(pairs, into: &out)
        return Data(out)
    }

    private static func write(_ pairs: [(key: String, value: VDFValue)], into out: inout [UInt8]) {
        for (key, value) in pairs {
            switch value {
            case let .map(inner):
                out.append(map); cstring(key, &out)
                write(inner, into: &out)
            case let .string(s):
                out.append(string); cstring(key, &out); cstring(s, &out)
            case let .int32(i):
                out.append(int32); cstring(key, &out)
                withUnsafeBytes(of: i.littleEndian) { out.append(contentsOf: $0) }
            case let .uint64(u):
                out.append(uint64); cstring(key, &out)
                withUnsafeBytes(of: u.littleEndian) { out.append(contentsOf: $0) }
            case let .float32(bits):
                out.append(float); cstring(key, &out)
                withUnsafeBytes(of: bits.littleEndian) { out.append(contentsOf: $0) }
            }
        }
        out.append(end)
    }

    private static func cstring(_ s: String, _ out: inout [UInt8]) {
        out.append(contentsOf: s.utf8.filter { $0 != 0 })
        out.append(0)
    }

    private struct Parser {
        let bytes: [UInt8]
        var offset = 0

        mutating func pairs() throws -> [(key: String, value: VDFValue)] {
            var result: [(key: String, value: VDFValue)] = []
            while true {
                guard offset < bytes.count else { throw VDFError.truncated(offset: offset) }
                let type = bytes[offset]
                offset += 1
                if type == VDF.end { return result }
                let typeOffset = offset - 1
                let key = try cstring()
                switch type {
                case VDF.map: result.append((key, .map(try pairs())))
                case VDF.string: result.append((key, .string(try cstring())))
                case VDF.int32: result.append((key, .int32(Int32(bitPattern: UInt32(try little(4))))))
                case VDF.float: result.append((key, .float32(UInt32(try little(4)))))
                case VDF.uint64: result.append((key, .uint64(try little(8))))
                default: throw VDFError.unknownType(type, offset: typeOffset)
                }
            }
        }

        mutating func cstring() throws -> String {
            let start = offset
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            guard offset < bytes.count else { throw VDFError.truncated(offset: start) }
            defer { offset += 1 }
            guard let s = String(bytes: bytes[start..<offset], encoding: .utf8) else {
                throw VDFError.invalidUTF8(offset: start)
            }
            return s
        }

        mutating func little(_ n: Int) throws -> UInt64 {
            guard offset + n <= bytes.count else { throw VDFError.truncated(offset: offset) }
            defer { offset += n }
            return (0..<n).reduce(UInt64(0)) { $0 | UInt64(bytes[offset + $1]) << (8 * UInt64($1)) }
        }
    }
}
