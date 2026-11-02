import Foundation
import Testing
@testable import DeckRemote

@MainActor @Suite struct JobQueueTests {
    let deck = UUID()
    func job(_ id: String) -> Job { Job(deckID: deck, title: id, action: .installEmulator(appID: id)) }
    var store: URL { FileManager.default.temporaryDirectory.appendingPathComponent("jobs-\(UUID().uuidString).json") }

    @Test func runsInOrderOnePerDeckAndReportsFailure() async {
        let order = Order()
        let q = JobQueue(storeURL: nil) { job, progress in
            await order.add(job.title)
            progress(50, nil)
            if job.title == "b" { throw DeckError.unexpectedState("quebrou") }
        }
        q.enqueue(job("a")); q.enqueue(job("b")); q.enqueue(job("c"))
        await q.waitUntilIdle()
        #expect(await order.items == ["a", "b", "c"])
        #expect(q.jobs.map(\.state) == [.succeeded, .failed("quebrou"), .succeeded])
    }

    @Test func duplicateWhilePendingIsIgnoredAndRetryWorks() async {
        let attempts = Order()
        let q = JobQueue(storeURL: nil) { job, _ in
            await attempts.add(job.title)
            if await attempts.items.count == 1 { throw DeckError.unexpectedState("rede") }
        }
        let first = q.enqueue(job("a"))
        #expect(q.enqueue(job("a")) == first)
        await q.waitUntilIdle()
        #expect(q.jobs.count == 1)
        q.retry(first)
        await q.waitUntilIdle()
        #expect(q.jobs[0].state == .succeeded)
    }

    @Test func lostDeckPausesAndResumes() async {
        let attempts = Order()
        let q = JobQueue(storeURL: nil) { job, _ in
            await attempts.add(job.title)
            if job.title == "a", await attempts.items.count == 1 {
                throw DeckError.commandFailed(command: "rsync", result: CommandResult(stderr: "rsync(314): error: unexpected end of file", exitCode: 255))
            }
        }
        q.enqueue(job("a")); q.enqueue(job("b"))
        await q.waitUntilIdle()
        // Pausou no primeiro: nada falhou e o segundo não rodou com o Deck fora do ar.
        #expect(q.jobs.map(\.state) == [.queued, .queued])
        #expect(q.jobs[0].detail == "Waiting for the Deck")
        q.resume(deckID: deck)
        await q.waitUntilIdle()
        #expect(q.jobs.map(\.state) == [.succeeded, .succeeded])
        #expect(await attempts.items == ["a", "a", "b"])
    }

    @Test func cancelStopsRunningJob() async {
        let q = JobQueue(storeURL: nil) { _, _ in try await Task.sleep(for: .seconds(30)) }
        let id = q.enqueue(job("a"))
        while q.jobs[0].state != .running { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
        q.cancel(id)
        await q.waitUntilIdle()
        #expect(q.jobs[0].state == .cancelled)
    }

    @Test func survivesRelaunchWithoutRestartingWhatWasRunning() async throws {
        let url = store
        let waiting = [Job(deckID: deck, title: "espera", action: .prepareEmulation(sdMount: nil))]
        var running = job("meio do caminho")
        running.state = .running
        try JSONEncoder().encode([running] + waiting).write(to: url)
        let q = JobQueue(storeURL: url) { _, _ in }
        #expect(q.jobs.map(\.state) == [.interrupted, .queued])
    }
}

actor Order {
    var items: [String] = []
    func add(_ s: String) { items.append(s) }
}
