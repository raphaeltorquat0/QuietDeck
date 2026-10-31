import Foundation
import Testing
import DeckKit
@testable import DeckRemote

@Suite struct DevkitUnitTests {
    @Test func bodyMatchesValveClient() {
        let body = DevkitPairing.registerBody(publicKey: "ssh-rsa AAAAB3Nza quietdeck\n", comment: "My Mac")
        #expect(body == "ssh-rsa AAAAB3Nza MyMac 900b919520e4cf601998a71eec318fec\n")
    }

    @Test func serviceOnlyAcceptsRSA() {
        #expect(DevkitPairing.registerBody(publicKey: "ssh-ed25519 AAAA x", comment: "m") == nil)
    }

    @Test func responses() {
        #expect(DevkitPairing.parseResponse(status: 200, body: "Registered\n") == .approved)
        #expect(DevkitPairing.parseResponse(status: 403, body: #"{"error": "Steam is not running"}"#) == .refused("Steam is not running"))
        #expect(DevkitPairing.parseResponse(status: 500, body: "install-ssh-key:\nboom\n") == .refused("install-ssh-key:\nboom"))
        #expect(DevkitPairing.parseResponse(status: 0, body: "") == .unreachable)
    }

    @Test func passwordStatusFromPasswdS() {
        #expect(SudoPassword.parseStatus("deck NP 2026-04-26 0 99999 7 -1\n") == .none)
        #expect(SudoPassword.parseStatus("deck P 2026-04-26 0 99999 7 -1\n") == .set)
        #expect(SudoPassword.parseStatus("deck L 2026-04-26 0 99999 7 -1\n") == .locked)
        #expect(SudoPassword.parseStatus("") == .unknown)
    }
}

extension IntegrationTests {
    @Test func devkitRoutesAndRegisterInstallRSAKey() async throws {
        guard Sim.hasHarness else { return }
        #expect(await DevkitPairing.isAvailable(host: Sim.host))
        #expect(await DevkitPairing.loginName(host: Sim.host) == "deck")
        let key = Sim.dir.appendingPathComponent("devkit_rsa").path
        try await DevkitPairing.ensureKey(at: key)
        try await DevkitPairing.ensureKey(at: key)
        let r = try await Sim.runner()

        try await r.check("touch /run/deck-sim/devkit-deny")
        #expect(try await DevkitPairing.register(host: Sim.host, keyPath: key, comment: "test") == .refused("Pairing denied"))
        try await r.check("rm /run/deck-sim/devkit-deny")

        #expect(try await DevkitPairing.register(host: Sim.host, keyPath: key, comment: "test") == .approved)
        var config = Sim.config
        config.identityFile = key
        #expect(await DevkitPairing.waitForSSH(config: config, polls: 3))
        await SSHRunner(config: config).disconnect()
    }

    @Test func passwordIsSetThroughPtyWhenUserHasNone() async throws {
        guard Sim.hasHarness else { return }
        let r = try await Sim.runner()
        try await r.check(.sudo("passwd -d nopass; cp /home/deck/.ssh/authorized_keys /home/nopass/.ssh/ && chown -R nopass /home/nopass/.ssh", password: Sim.password))
        var config = Sim.config
        config.user = "nopass"
        let nopass = SSHRunner(config: config)
        #expect(try await SudoPassword.status(nopass) == .none)
        try await SudoPassword.set("Qd!simulated-pass-42", config: config)
        #expect(try await SudoPassword.status(nopass) == .set)
        await nopass.disconnect()
    }
}
