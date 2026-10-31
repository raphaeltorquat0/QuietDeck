import Foundation
import Testing
import DeckKit
@testable import DeckRemote

extension IntegrationTests {

    @Test func wrongPasswordIsRefusedAndPairingIsIdempotent() async throws {
        let r = try await Sim.runner()
        await #expect(throws: DeckError.self) { try await Pairing.installKey(config: Sim.config, password: "wrong") }
        try await Pairing.installKey(config: Sim.config, password: Sim.password)
        let keys = try await r.check("grep -c quietdeck ~/.ssh/authorized_keys").trimmed
        #expect(keys == "1")
    }

    @Test func probeReadsSimulatedDeck() async throws {
        let r = try await Sim.runner()
        let s = try await DeviceProbe.read(r)
        #expect(s.osVersion != nil)
        #expect((s.internalStorage?.total ?? 0) > 0)
        if Sim.hasHarness {
            #expect(s.osVersion == "3.9.4" && s.buildID == "20261021.100")
            #expect(s.mode == .game)
        }
    }

    @Test func manyCommandsShareOneConnection() async throws {
        let r = try await Sim.runner()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<12 { group.addTask { try await r.check("true") } }
            try await group.waitForAll()
        }
        let check = try await LocalProcess.run("/usr/bin/ssh", ["-o", "ControlPath=\(Sim.config.controlPath)", "-O", "check", "-p", String(Sim.port), Sim.config.destination])
        #expect(check.ok)
    }

    @Test func sudoUsesStdinAndRefusesWrongPassword() async throws {
        let r = try await Sim.runner()
        #expect(try await r.check(.sudo("id -u", password: Sim.password)).trimmed == "0")
        // O SteamOS real guarda a credencial por alguns minutos; sem isso, a senha errada passaria.
        await #expect(throws: DeckError.sudoRejected) { try await r.check(.sudo("id -u", password: "wrong", forgetCached: true)) }
    }

    @Test func recordedSessionReplaysWithoutTheDeck() async throws {
        let r = try await Sim.runner()
        let url = Sim.dir.appendingPathComponent("rec-\(UUID().uuidString).json")
        let recording = RecordingRunner(base: r, recorder: CommandRecorder(url: url, source: "container"))
        let live = try await DeviceProbe.read(recording)
        _ = try await recording.check(.sudo("id -u", password: Sim.password))
        let saved = try String(contentsOf: url, encoding: .utf8)
        #expect(!saved.contains(Sim.password))
        #expect(try await DeviceProbe.read(ReplayRunner(json: url)) == live)
    }
}
