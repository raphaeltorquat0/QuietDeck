import Foundation
import Testing
@testable import DeckRemote

@Suite struct SwitchFirmwareTests {
    private func folder(ncas: Int, extra: String? = nil) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("Firmware 19.0.1")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<ncas {
            let name = i == 0 ? "aa\(i).cnmt.nca" : "aa\(i).nca"
            try Data("nca\(i)".utf8).write(to: dir.appendingPathComponent(name))
        }
        // NCA fragmentada, como alguns dumps gravam.
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("bb.nca"), withIntermediateDirectories: true)
        try Data("frag".utf8).write(to: dir.appendingPathComponent("bb.nca/00"))
        if let extra { try Data().write(to: dir.appendingPathComponent(extra)) }
        return dir
    }

    @Test func namesFollowRyubing() {
        #expect(SwitchFirmware.registeredName("x/0a1b.cnmt.nca") == "0a1b.nca")
        #expect(SwitchFirmware.registeredName("0a1b.nca") == "0a1b.nca")
        #expect(SwitchFirmware.registeredName("fw/0a1b.nca/00") == "0a1b.nca")
        #expect(SwitchFirmware.registeredName("prod.keys") == nil)
    }

    @Test func detectsOnlyFirmwareFolders() async throws {
        #expect(await SwitchFirmware.isFirmware(try folder(ncas: 30)))
        #expect(await !SwitchFirmware.isFirmware(try folder(ncas: 3)))
        #expect(await !SwitchFirmware.isFirmware(try folder(ncas: 30, extra: "Game.nsp")))
    }

    @Test func stagesTheRegisteredLayout() async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let staged = try await SwitchFirmware.stage(try folder(ncas: 30), work: work)
        #expect(staged.count == 31)
        let reg = staged.directory
        #expect(try Data(contentsOf: reg.appendingPathComponent("aa0.nca/00")) == Data("nca0".utf8))
        #expect(try Data(contentsOf: reg.appendingPathComponent("bb.nca/00")) == Data("frag".utf8))
        #expect(!FileManager.default.fileExists(atPath: reg.appendingPathComponent("aa0.cnmt.nca").path))
        await #expect(throws: DeckError.self) { _ = try await SwitchFirmware.stage(try folder(ncas: 2), work: work) }
    }
}
