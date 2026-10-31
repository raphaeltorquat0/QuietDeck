import Foundation
import Testing
import DeckKit
@testable import DeckRemote

/// Lê as fixtures de record/replay. Toda gravação em `Fixtures/` passa pelos mesmos parsers.
@Suite struct ReplayTests {
    static let fixtures: [URL] = {
        let dir = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
        return (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "json" } ?? []
    }()

    @Test func thereIsAtLeastOneFixtureAndEachSaysWhereItCameFrom() throws {
        #expect(!Self.fixtures.isEmpty)
        for url in Self.fixtures {
            let file = try JSONDecoder().decode(RecordingFile.self, from: Data(contentsOf: url))
            #expect(["steamos-real", "container", "sintética"].contains(file.source))
        }
    }

    @Test(arguments: fixtures) func deviceStatus(url: URL) async throws {
        let s = try await DeviceProbe.read(ReplayRunner(json: url))
        #expect(s.osVersion?.hasPrefix("3.") == true)
        #expect(s.internalStorage?.mountPoint == "/home")
        #expect((s.batteryPercent ?? -1) >= 0)
    }

    @Test func demoFixtureValues() async throws {
        let url = try #require(Self.fixtures.first { $0.lastPathComponent == "steamos-3.9.4-demo.json" })
        let r = try ReplayRunner(json: url)
        let s = try await DeviceProbe.read(r)
        #expect(s.osVersion == "3.9.4" && s.buildID == "20261021.100" && s.model == "Steam Deck OLED")
        #expect(s.batteryPercent == 78 && s.batteryState == "Discharging")
        #expect(s.sdCard?.mountPoint == "/run/media/deck/Games SD" && s.sdCard?.free == 655_000_000_000)
        #expect(s.temperatures["CPU"] == 54 && s.temperatures["SSD"] == 39.85)
        #expect(s.mode == .game)
        #expect(try await Flatpaks.installed(r).map(\.appID).contains("net.pcsx2.PCSX2"))
    }
}

@Suite struct OrderTests {
    let existing = RecordedCommand(command: Flatpaks.list, stdout: "a.b.C\t1\tstable\tuser\n", stderr: "", exitCode: 0)

    @Test func installReadsStateFirstAndDoesNothingWhenPresent() async throws {
        let r = ReplayRunner(RecordingFile(source: "sintética", commands: [existing]))
        #expect(try await Flatpaks.install("a.b.C", runner: r) == .alreadyInstalled)
        #expect(r.executed == [Flatpaks.list])
    }

    @Test func systemWideInstallIsNeverTouched() async throws {
        let line = RecordedCommand(command: Flatpaks.list, stdout: "a.b.C\t1\tstable\tsystem\n", stderr: "", exitCode: 0)
        let r = ReplayRunner(RecordingFile(source: "sintética", commands: [line]))
        #expect(try await Flatpaks.remove("a.b.C", runner: r) == .systemInstall)
        #expect(r.executed == [Flatpaks.list])
    }

    @Test func addingNothingNeverStopsSteam() async throws {
        let game = Shortcut(name: "G", exe: "/x", startDir: "/")
        let root = try ShortcutsFile.merge([game], into: ShortcutsFile.emptyFile).root
        let b64 = VDF.serialize(root).base64EncodedString()
        let r = ReplayRunner(["printf %s \"$HOME\"": CommandResult(stdout: "/home/deck"),
                              "base64 -w0 '/home/deck/.local/share/Steam/userdata/1/config/shortcuts.vdf' 2>/dev/null": CommandResult(stdout: b64)])
        #expect(try await SteamControl(runner: r).addShortcuts([game], user: "1").added.isEmpty)
        #expect(!r.executed.contains { $0.contains("systemctl") || $0.contains("pkill") })
    }

    @Test func unrecordedCommandIsAnError() async {
        await #expect(throws: ReplayRunner.Unrecorded.self) { try await ReplayRunner([:]).run("rm -rf /") }
    }

    @Test func repeatedCommandsConsumeRecordingsInOrder() async throws {
        let r = ReplayRunner(RecordingFile(source: "sintética", commands: [
            RecordedCommand(command: "x", stdout: "1", stderr: "", exitCode: 0),
            RecordedCommand(command: "x", stdout: "2", stderr: "", exitCode: 0)]))
        #expect(try await r.run("x").stdout == "1")
        #expect(try await r.run("x").stdout == "2")
        #expect(try await r.run("x").stdout == "2")
    }
}
