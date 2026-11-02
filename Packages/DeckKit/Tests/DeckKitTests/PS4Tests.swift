import Foundation
import Testing
@testable import DeckKit

@Suite struct PS4Tests {
    /// `param.sfo` mínimo, no layout do PS4: duas chaves de texto e uma numérica.
    static func sfo(_ entries: [(String, String)], number: (String, UInt32)? = nil) -> Data {
        func le(_ v: Int, _ n: Int) -> [UInt8] { (0..<n).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        var keys: [UInt8] = [], values: [UInt8] = [], index: [UInt8] = []
        for (k, v) in entries {
            let bytes = Array(v.utf8) + [0], max = (bytes.count + 3) / 4 * 4
            index += le(keys.count, 2) + le(0x0204, 2) + le(bytes.count, 4) + le(max, 4) + le(values.count, 4)
            keys += Array(k.utf8) + [0]
            values += bytes + Array(repeating: 0, count: max - bytes.count)
        }
        if let (k, v) = number {
            index += le(keys.count, 2) + le(0x0404, 2) + le(4, 4) + le(4, 4) + le(values.count, 4)
            keys += Array(k.utf8) + [0]
            values += le(Int(v), 4)
        }
        let count = entries.count + (number == nil ? 0 : 1)
        while keys.count % 4 != 0 { keys.append(0) }
        let keyStart = 20 + count * 16
        return Data([0, 0x50, 0x53, 0x46] + le(0x101, 4) + le(keyStart, 4) + le(keyStart + keys.count, 4) + le(count, 4) + index + keys + values)
    }

    @Test func readsTitleAndID() {
        let data = Self.sfo([("TITLE", "Bloodborne"), ("TITLE_ID", "CUSA00900")], number: ("APP_TYPE", 1))
        let sfo = ParamSFO.parse(data)
        #expect(sfo?["TITLE"] == "Bloodborne")
        #expect(sfo?["TITLE_ID"] == "CUSA00900")
        #expect(sfo?["APP_TYPE"] == nil)
        #expect(ParamSFO.parse(Data("not an sfo file".utf8)) == nil)
        #expect(ParamSFO.parse(Data([0, 0x50, 0x53, 0x46] + Array(repeating: 0xFF, count: 16))) == nil)
    }

    @Test func folderGetsTitleName() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("CUSA00900")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sce_sys"), withIntermediateDirectories: true)
        #expect(!PS4Game.isGameFolder(dir))
        try Data().write(to: dir.appendingPathComponent("eboot.bin"))
        try Self.sfo([("TITLE", "Game: The/Return"), ("TITLE_ID", "CUSA00900")]).write(to: dir.appendingPathComponent("sce_sys/param.sfo"))
        #expect(PS4Game.isGameFolder(dir))
        #expect(PS4Game.folderName(dir) == "Game  The Return [CUSA00900]")
        #expect(ROMPlan.displayName(PS4Game.folderName(dir)) == "Game  The Return")
    }

    @Test func catalogKnowsPS4() throws {
        let catalog = try Catalog.load()
        let ps4 = try #require(catalog.system("ps4"))
        #expect(ps4.entry == "eboot.bin" && ps4.folder == "ps4")
        #expect(catalog.emulator(ps4.emulator)?.launch == "run --command=shadps4 net.shadps4.shadPS4 -f true -g {rom}")
    }
}
