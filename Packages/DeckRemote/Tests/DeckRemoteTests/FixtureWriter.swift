import Foundation
import Testing
import DeckKit
@testable import DeckRemote

/// Gera `Fixtures/steamos-3.9.4-demo.json` (`QUIETDECK_WRITE_FIXTURE=<arquivo> swift test --filter FixtureWriter`).
/// É sintética: formatos conferidos na imagem 3.9.4, valores inventados. Gravações de um Deck real
/// entram na mesma pasta com `source: steamos-real` (SMOKE_TEST.md).
@Suite struct FixtureWriter {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QUIETDECK_WRITE_FIXTURE"] != nil)) func write() throws {
        let home = "/home/deck", paths = EmulationPaths(root: home + "/Emulation")
        let flatpaks = """
        org.libretro.RetroArch\t1.21.0\tstable\tuser
        org.DolphinEmu.dolphin-emu\t2412\tstable\tuser
        net.pcsx2.PCSX2\tv2.2.0\tstable\tuser
        org.ppsspp.PPSSPP\t1.18.1\tstable\tuser
        """ + "\n"
        let library = ["41943040\tgba/Golden Sun.gba", "524288000\tpsx/Chrono Cross (Disc 1).chd", "519045120\tpsx/Chrono Cross (Disc 2).chd",
                       "48\tpsx/Chrono Cross.m3u", "2147483648\tps2/Okami.chd", "1459978240\tgc/Wind Waker.rvz", "4294967\tsnes/Super Metroid.sfc"].joined(separator: "\n") + "\n"
        let table = try Catalog.load().bios.entries
        func sha(_ f: String) -> String { table.first { $0.file == f }!.sha1 }
        let bios = "\(sha("scph5501.bin"))  ./scph5501.bin\n\(sha("gba_bios.bin"))  ./gba_bios.bin\n\(String(repeating: "ab", count: 20))  ./dc/dc_boot.bin\n"
        let entries: [(String, String)] = [
            (DeviceProbe.osRelease, "NAME=\"SteamOS\"\nID=steamos\nID_LIKE=arch\nVERSION_CODENAME=holo\nVARIANT_ID=steamdeck\nVERSION_ID=3.9.4\nBUILD_ID=20261021.100\n"),
            (DeviceProbe.board, "Galileo\n"),
            (DeviceProbe.battery, "78\nDischarging\n"),
            (DeviceProbe.disks, "Filesystem Mounted on 1B-blocks Avail\n/dev/nvme0n1p8 /home 981000000000 412000000000\nFilesystem Mounted on 1B-blocks Avail\n/dev/mmcblk0p1 /run/media/deck/Games SD 1023000000000 655000000000\n"),
            (DeviceProbe.temperatures, "amdgpu 48000\nacpitz 54000\nnvme 39850\nsteamdeck_hwmon 41000\n"),
            (DeviceProbe.session, "game\n"),
            (Flatpaks.list, flatpaks),
            (Flatpaks.updates, "net.pcsx2.PCSX2\tv2.2.1\n"),
            ("printf %s \"$HOME\"", home),
            (Emulation.emuDeckSettings, ""),
            (Library.listing(paths: paths), library),
            (BIOS.scan(paths: paths), bios),
            (SteamControl.userList, "12345678\n"),
            (Decky.stateScript, "installed\nv3.1.5\n\nactive\n"),
            (Decky.pluginList, "[{\"name\":\"PowerTools\",\"version\":\"2.0.3\",\"folder\":\"PowerTools\"},{\"name\":\"SteamGridDB\",\"version\":\"1.3.1\",\"folder\":\"decky-steamgriddb\"}]\n"),
            (CompatTools.list, "GE-Proton11-11\nGE-Proton10-34\n"),
        ]
        let file = RecordingFile(source: "sintética", commands: entries.map { RecordedCommand(command: $0.0, stdout: $0.1, stderr: "", exitCode: 0) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(file).write(to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["QUIETDECK_WRITE_FIXTURE"]!))
    }
}
