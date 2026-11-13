@testable import BosunTerminal
import Darwin
import Testing

/// Every process the app starts inherits its exception ports, and so does
/// all they start: agent-deck's tmux server and every agent under it. The
/// engine must leave their faults, and the app's own aborts, to macOS.
@Suite struct GhosttyInitTests {
    @Test func startingTheEngineLeavesFaultsToMacOS() async throws {
        let abortBefore = abortHandler()
        #expect(GhosttyInit.run())
        // Sentry comes up on libghostty's own thread within a millisecond;
        // without the wait, a crash reporter left running could go unseen.
        try await Task.sleep(for: .milliseconds(100))
        #expect(!GhosttyInit.takesFaults())
        #expect(abortHandler() == abortBefore)
    }
}

private func abortHandler() -> Int {
    var action = sigaction()
    sigaction(SIGABRT, nil, &action)
    return unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self)
}
