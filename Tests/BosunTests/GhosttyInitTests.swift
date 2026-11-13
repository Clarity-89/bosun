@testable import BosunTerminal
import Foundation
import Testing

/// Every process the app starts inherits its exception ports, and so does
/// all they start: agent-deck's tmux server and every agent under it. The
/// engine must leave their faults, and the app's own aborts, to macOS.
@Suite struct GhosttyInitTests {
    /// In a process of its own: ghostty_init runs once per process, and it
    /// changes the locale, the signal dispositions and the file limit of
    /// whichever process that is.
    @Test func startingTheEngineLeavesFaultsToMacOS() async {
        await #expect(processExitsWith: .success) {
            // Sentry keeps its runs in Ghostty's own cache folder, the
            // user's, unless XDG names another.
            let cache = FileManager.default.temporaryDirectory.appending(path: "bosun-ghostty-init-\(getpid())")
            setenv("XDG_CACHE_HOME", cache.path, 1)
            defer { try? FileManager.default.removeItem(at: cache) }
            let abortBefore = abortHandler()
            #expect(GhosttyInit.run())
            // Sentry comes up on libghostty's own thread within a millisecond;
            // without the wait, a crash reporter left running could go unseen.
            usleep(100_000)
            #expect(!GhosttyInit.takesFaults())
            #expect(abortHandler() == abortBefore)
        }
    }
}

private func abortHandler() -> Int {
    var action = sigaction()
    sigaction(SIGABRT, nil, &action)
    return unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self)
}
