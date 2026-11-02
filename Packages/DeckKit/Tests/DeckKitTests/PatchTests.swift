import Foundation
import Testing
@testable import DeckKit

/// Patches gerados por um codificador à parte, escrito a partir da especificação de cada formato.
/// O BPS usa os quatro comandos, inclusive cópia sobreposta do próprio alvo.
@Suite struct PatchTests {
    let source = Data((0..<4096).map { UInt8(($0 * 31 + 7) % 251) })
    var target: Data {
        var t = source
        t.replaceSubrange(100..<110, with: Data("TRADUZIDO!".utf8))
        return t + Data(repeating: 0x41, count: 300) + source.prefix(256)
    }

    static let ips = "UEFUQ0gAAGQAClRSQURVWklETyEAEAAAAAEsQQARLAEAByZFZIOiweAEI0JhgJ++3QEgP159nLva+R08W3qZuNf2GjlYd5a11PMXNlV0k7LR8BQzUnGQr87tETBPbo2sy+oOLUxriqnI5wsqSWiHpsXkCCdGZYSjwuEFJENigaC/3gIhQF9+nbzb+h49XHuaudj3GzpZeJe21fQYN1Z1lLPS8RU0U3KRsM/uEjFQb46tzOsPLk1si6rJ6AwrSmmIp8blCShHZoWkw+IGJURjgqHA3wMiQWB/nr3cAB8+XXybutn4HDtaeZi31vUZOFd2lbTT8hY1VHOSsdDvEzJRcI+uzewQL05tjKvK6Q0sS2qJqMfmCilIZ4alxOMHJkVkg0VPRg=="
    static let ups = "VVBTMQCfLKPkCyzc+I6gV3kTWgARnkFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQQcmRWSDosHgBCNCYYCfvt0BID9efZy72vkdPFt6mbjX9ho5WHeWtdTzFzZVdJOy0fAUM1JxkK/O7REwT26NrMvqDi1Ma4qpyOcLKkloh6bF5AgnRmWEo8LhBSRDYoGgv94CIUBffp282/oePVx7mrnY9xs6WXiXttX0GDdWdZSz0vEVNFNykbDP7hIxUG+OrczrDy5NbIuqyegMK0ppiKfG5QkoR2aFpMPiBiVEY4KhwN8DIkFgf5693ACAHz5dfJu62fgcO1p5mLfW9Rk4V3aVtNPyFjVUc5Kx0O8TMlFwj67N7BAvTm2Mq8rpDSxLaomox+YKKUhnhqXE4wcmRWSDAJ1jHDHg8cK80R2Rxw=="
    static let bps = "QlBTMQCfLKOADIKlVFJBRFVaSURPIUb7XICBQSuIAL9+hgG/nWMcMeDxwryV6EA0"

    func patch(_ b64: String) -> Data { Data(base64Encoded: b64)! }

    @Test func appliesEachFormat() throws {
        for p in [Self.ips, Self.ups, Self.bps] {
            #expect(try ROMPatch.apply(patch(p), to: source) == target)
        }
    }

    @Test func rejectsAnotherVersionOfTheROM() {
        var other = source
        other[0] ^= 1
        for p in [Self.ups, Self.bps] {
            #expect(throws: ROMPatch.Failure.wrongSource) { try ROMPatch.apply(patch(p), to: other) }
        }
    }

    @Test func ignoresCopierHeader() throws {
        #expect(try ROMPatch.apply(patch(Self.bps), to: Data(count: 512) + source) == target)
    }

    @Test func rejectsDamagedPatches() {
        var broken = patch(Self.bps)
        broken[10] ^= 0xFF
        #expect(throws: ROMPatch.Failure.corrupt) { try ROMPatch.apply(broken, to: source) }
        #expect(throws: ROMPatch.Failure.invalid) { try ROMPatch.apply(Data("hello".utf8), to: source) }
        #expect(throws: ROMPatch.Failure.corrupt) { try ROMPatch.apply(patch(Self.ips).prefix(40), to: source) }
    }

    @Test func pairsPatchWithROM() {
        let roms = ["/a/Chrono Trigger (USA).sfc", "/a/Earthbound (USA).sfc"]
        #expect(ROMPatch.pair(roms: roms, patches: ["/b/earthbound (usa).ips"]) == [roms[1]: "/b/earthbound (usa).ips"])
        #expect(ROMPatch.pair(roms: roms, patches: ["/b/CT PT-BR.bps"]).isEmpty)
        #expect(ROMPatch.pair(roms: [roms[0]], patches: ["/b/CT PT-BR.bps"]) == [roms[0]: "/b/CT PT-BR.bps"])
        #expect(ROMPatch.patchedName(rom: roms[0], patch: "/b/CT PT-BR.bps") == "Chrono Trigger (USA) (CT PT-BR).sfc")
        #expect(ROMPatch.patchedName(rom: roms[0], patch: "/b/Chrono Trigger (USA).ips") == "Chrono Trigger (USA) (Patched).sfc")
    }
}
