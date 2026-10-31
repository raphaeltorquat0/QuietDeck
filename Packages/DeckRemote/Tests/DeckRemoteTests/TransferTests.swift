import Foundation
import Testing
@testable import DeckRemote

@Suite struct TransferTests {
    let config = SSHConfig(host: "deck.local", identityFile: "/k", knownHostsFile: "/Users/a b/known")

    @Test func progressFromBothRsyncs() {
        #expect(Transfer.parseProgress("       20938752  67%   39,67MB/s   00:00:00\r") == TransferProgress(percent: 67, rate: "39,67MB/s"))
        #expect(Transfer.parseProgress("  1,234,567  45%   12.34MB/s    0:00:12\r 2,000,000  90%   12.00MB/s    0:00:01")?.percent == 90)
        #expect(Transfer.parseProgress("it's a game 100% final.iso\n") == nil)
    }

    @Test func quotingFollowsClientProtocol() {
        #expect(!Transfer.clientQuotesPaths(versionOutput: "openrsync: protocol version 29\nrsync version 2.6.9 compatible"))
        #expect(Transfer.clientQuotesPaths(versionOutput: "rsync  version 3.5.1  protocol version 33"))
        #expect(Transfer.remoteSpec(config, path: "/run/media/my sd/", clientQuotes: false) == "deck@deck.local:'/run/media/my sd/'")
        #expect(Transfer.remoteSpec(config, path: "/run/media/my sd/", clientQuotes: true) == "deck@deck.local:/run/media/my sd/")
    }

    @Test func fallbackOnlyForMissingSupport() {
        #expect(Transfer.needsFallback(CommandResult(stderr: "rsync: unrecognized option `--partial-dir'", exitCode: 1)))
        #expect(Transfer.needsFallback(CommandResult(stderr: "bash: rsync: command not found", exitCode: 127)))
        #expect(!Transfer.needsFallback(CommandResult(stderr: "No space left on device", exitCode: 11)))
        #expect(!Transfer.needsFallback(CommandResult()))
    }

    @Test func rsyncShellKeepsPathWithSpaceTogether() {
        #expect(config.rsyncShell.contains("\"UserKnownHostsFile=/Users/a b/known\""))
    }

    @Test func sftpBatchEscapes() {
        #expect(Transfer.sftpBatch(local: "/a/it's \"x\".iso", remotePath: "/r/y", isDirectory: false) == "reput \"/a/it's \\\"x\\\".iso\" \"/r/y\"\n")
    }
}
