import Foundation
import Testing
@testable import DeckRemote

@Suite struct SwitchModsTests {
    @Test func findsTitleFoldersLikeAtmosphere() {
        let entries = ["Tradução RE0/atmosphere/contents/010097000BC10000/romfs/text/msg.bin",
                       "Tradução RE0/atmosphere/contents/010097000BC10000/romfs/text/menu.bin",
                       "Tradução RE0/atmosphere/contents/010097000bc10000/exefs/main.npdm",
                       "Tradução RE0/LEIA-ME.txt",
                       "outro/0100000000000000/cheats/a.txt"]
        #expect(SwitchMods.titleFolders(in: entries) == ["Tradução RE0/atmosphere/contents/010097000BC10000",
                                                        "Tradução RE0/atmosphere/contents/010097000bc10000"])
        #expect(SwitchMods.titleFolders(in: ["0100ABCDEF000000/romfs/a.bin"]) == ["0100ABCDEF000000"])
        #expect(SwitchMods.titleFolders(in: ["Game.nsp", "romfs/a.bin"]).isEmpty)
    }

    @Test func modNameComesFromWhatWasDropped() {
        #expect(SwitchMods.modName(URL(fileURLWithPath: "/d/RE0 PT-BR v1.2.zip")) == "RE0 PT-BR v1.2")
        #expect(SwitchMods.modName(URL(fileURLWithPath: "/d/RE0 PT-BR")) == "RE0 PT-BR")
    }

    @Test func detectsAFolderPack() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("RE0 PT-BR")
        let romfs = dir.appendingPathComponent("atmosphere/contents/010097000BC10000/romfs")
        try FileManager.default.createDirectory(at: romfs, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: romfs.appendingPathComponent("msg.bin"))
        #expect(await SwitchMods.isModPack(dir))
        #expect(await !SwitchFirmware.isFirmware(dir))
    }
}
