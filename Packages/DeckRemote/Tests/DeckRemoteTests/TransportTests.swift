import Foundation
import Testing
import DeckKit
@testable import DeckRemote

@Suite struct TransportTests {
    let config = SSHConfig(host: "steamdeck.local", identityFile: "/Users/a/.ssh/quietdeck_ed25519", knownHostsFile: "/k")

    @Test func sshUsesTheKeyAndTheSharedMaster() {
        let a = config.sshArguments("uname -r")
        #expect(a.contains("IdentitiesOnly=yes") && a.contains("BatchMode=yes") && a.contains("ControlMaster=no"))
        #expect(a.suffix(3) == ["deck@steamdeck.local", "--", "uname -r"])
        let m = config.masterArguments()
        #expect(m.contains("ControlMaster=yes") && m.contains("ControlPersist=120") && m.contains("-fN"))
    }

    @Test func controlSocketFitsMacOSLimit() {
        // 104 bytes de sockaddr_un, com os 40 de `%C`.
        #expect(config.controlPath.count - 2 + 40 < 104)
    }

    @Test func shellQuotingSurvivesHostileNames() {
        #expect(Shell.quote("it's; rm -rf ~") == "'it'\\''s; rm -rf ~'")
    }

    @Test func pairingKeepsAuthorizedKeysIdempotent() {
        let s = Pairing.installScript(publicKey: "ssh-ed25519 AAAA quietdeck\n")
        #expect(s.contains("grep -qxF 'ssh-ed25519 AAAA quietdeck'"))
        #expect(s.contains(">> ~/.ssh/authorized_keys"))
    }

    @Test func sudoNeverLeaksPasswordIntoScript() {
        let c = RemoteCommand.sudo("id -u", password: "s3cr3t")
        #expect(!c.script.contains("s3cr3t"))
        #expect(c.stdin == Data("s3cr3t\n".utf8))
    }

    @Test func disksWithSpaceInLabelAndNoCard() {
        var s = DeviceStatus()
        DeviceProbe.parseDisks("Filesystem Mounted on 1B-blocks Avail\n/dev/nvme0n1p8 /home 100 40\n", into: &s)
        #expect(s.internalStorage?.free == 40 && s.sdCard == nil)
    }

    @Test func batteryMissingOnDesktopHardware() {
        var s = DeviceStatus()
        DeviceProbe.parseBattery("", into: &s)
        #expect(s.batteryPercent == nil)
    }
}
