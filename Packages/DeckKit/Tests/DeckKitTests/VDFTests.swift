import Foundation
import Testing
@testable import DeckKit

private func hex(_ s: String) -> Data {
    let digits = s.filter { !$0.isWhitespace }
    return Data(stride(from: 0, to: digits.count, by: 2).map {
        let a = digits.index(digits.startIndex, offsetBy: $0)
        return UInt8(digits[a...digits.index(after: a)], radix: 16)!
    })
}

@Suite struct VDFTests {
    // Montado à mão pelo formato: 00 mapa, 01 string, 02 int32, 08 fim.
    let sample = hex("""
    00 73686f727463757473 00
      00 30 00
        02 6170706964 00 78563412
        01 417070 4e616d65 00 4a6f676f 00
        00 74616773 00 08
      08
    08 08
    """)

    @Test func parsesKnownBytes() throws {
        let root = try VDF.parse(sample)
        let entry = try #require(root["shortcuts"]?["0"])
        #expect(entry["appid"] == .int32(0x12345678))
        #expect(entry["AppName"] == .string("Jogo"))
        #expect(entry["tags"] == .map([]))
    }

    @Test func roundTripKeepsBytes() throws {
        #expect(VDF.serialize(try VDF.parse(sample)) == sample)
    }

    @Test func roundTripKeepsOrderTypesAndNegativeInts() throws {
        let value = VDFValue.map([("b", .string("ção ✓")), ("a", .int32(-2)), ("c", .uint64(.max)), ("d", .float32(0x3f800000)),
                                  ("m", .map([("z", .map([]))]))])
        #expect(try VDF.parse(VDF.serialize(value)) == value)
    }

    @Test func keysIgnoreCase() throws {
        #expect(try VDF.parse(sample)["SHORTCUTS"]?["0"]?["APPNAME"] == .string("Jogo"))
    }

    @Test func rejectsDamagedFiles() {
        #expect(throws: VDFError.self) { try VDF.parse(sample.dropLast(4)) }
        #expect(throws: VDFError.self) { try VDF.parse(hex("09 6100")) }
        #expect(throws: VDFError.self) { try VDF.parse(sample + Data([1, 2, 3])) }
        #expect(throws: VDFError.self) { try VDF.parse(hex("01 61 00 ff fe 00 08")) }
    }
}
