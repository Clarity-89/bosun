import Testing
@testable import BosunCore

/// Calls and waits, recorded instead of slept.
private actor Trace {
    var calls = 0
    var waits: [Duration] = []

    func call() -> Int {
        calls += 1
        return calls
    }

    func wait(_ delay: Duration) { waits.append(delay) }
}

/// gh's requests, tried again while GitHub is out of reach.
@Suite struct BackoffTests {
    static let dialTimeout = GitHubCLIError.failed(#"Post "https://api.github.com/graphql": dial tcp 140.82.121.5:443: i/o timeout"#)

    @Test func waitsLongerBeforeEachRetryThenGivesUp() async {
        let trace = Trace()
        await #expect(throws: Self.dialTimeout) {
            try await Backoff().run(retrying: GitHubCLI.isTransient, sleep: { await trace.wait($0) }) {
                _ = await trace.call()
                throw Self.dialTimeout
            }
        }
        #expect(await trace.calls == 4)
        #expect(await trace.waits == [.seconds(1), .seconds(2), .seconds(4)])
    }

    @Test func aRequestThatGetsThroughReturnsItsAnswer() async throws {
        let trace = Trace()
        let answer = try await Backoff().run(retrying: GitHubCLI.isTransient, sleep: { await trace.wait($0) }) {
            if await trace.call() < 3 { throw SubprocessError.timedOut(command: "gh") }
            return "data"
        }
        #expect(answer == "data")
        #expect(await trace.waits == [.seconds(1), .seconds(2)])
    }

    /// Another try cannot install gh or sign in.
    @Test(arguments: [GitHubCLIError.notInstalled, .signedOut])
    func whatATryCannotFixFailsAtOnce(error: GitHubCLIError) async {
        let trace = Trace()
        await #expect(throws: error) {
            try await Backoff().run(retrying: GitHubCLI.isTransient, sleep: { await trace.wait($0) }) {
                _ = await trace.call()
                throw error
            }
        }
        #expect(await trace.calls == 1)
        #expect(await trace.waits.isEmpty)
    }

    /// Quitting mid-wait must not leave gh to run again.
    @Test func cancellingAWaitStopsTheRetries() async {
        let trace = Trace()
        await #expect(throws: CancellationError.self) {
            try await Backoff().run(retrying: GitHubCLI.isTransient, sleep: { _ in throw CancellationError() }) {
                _ = await trace.call()
                throw Self.dialTimeout
            }
        }
        #expect(await trace.calls == 1)
    }
}
