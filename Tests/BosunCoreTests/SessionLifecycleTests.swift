import Testing
@testable import BosunCore

/// Replies as agent-deck v1.16.34 prints them for a throwaway shell session.
@Suite struct SessionLifecycleReplyTests {
    @Test func restartThatRanPasses() throws {
        let result = ProcessResult(command: "agent-deck session restart --json", status: 0, stdout: """
            {
              "id": "92d81845-1793166953",
              "success": true,
              "title": "bosun-lc-probe"
            }
            """, stderr: "")
        try AgentDeckCLI.checkRestarted(result)
    }

    /// agent-deck exits 0 for a skipped restart; only `skipped` says nothing ran.
    @Test func skippedRestartFailsWithItsReason() {
        let reason = "session is starting and was started 1s ago (within 1m0s freshness window); use --force to restart anyway"
        let result = ProcessResult(command: "agent-deck session restart --json", status: 0, stdout: """
            {
              "id": "92d81845-1793166953",
              "reason": "\(reason)",
              "skipped": true,
              "success": true,
              "title": "bosun-lc-probe"
            }
            """, stderr: "")
        #expect(throws: AgentDeckCLIError.reported("Restart skipped: \(reason)")) {
            try AgentDeckCLI.checkRestarted(result)
        }
    }

    /// Refusals exit 1, unknown sessions exit 2; both carry the reason on stdout.
    @Test(arguments: [
        (Int32(1), "session 'bosun-lc-probe' is not running"),
        (Int32(2), "session 'no-such-session-xyz' not found"),
    ])
    func refusalShowsAgentDecksMessage(status: Int32, reason: String) {
        let result = ProcessResult(command: "agent-deck session stop --json", status: status, stdout: """
            {
              "code": "INVALID_OPERATION",
              "error": "\(reason)",
              "success": false
            }
            """, stderr: "")
        #expect(throws: AgentDeckCLIError.reported(reason)) {
            try AgentDeckCLI.checkReported(result)
        }
    }
}

@Suite struct SessionActionRuleTests {
    @Test(arguments: [SessionStatus.stopped, .error])
    func onlyStartsWithoutAProcess(status: SessionStatus) {
        #expect(!status.hasProcess)
    }

    @Test(arguments: [SessionStatus.running, .waiting, .idle, .starting, .queued, .unknown])
    func stopsAndRestartsWithAProcess(status: SessionStatus) {
        #expect(status.hasProcess)
    }

    static func session(_ id: String, _ path: String, archived: Bool = false) -> DeckSession {
        DeckSession(id: id, title: id, path: path, group: "", tool: "claude", status: .idle, substate: nil, tmuxSession: nil, archived: archived)
    }

    @Test func ownDirectoryIsPruned() {
        let target = Self.session("a", "/Users/me/dev/worktrees/app-a")
        #expect(target.mayPruneWorktree(among: [target, Self.session("b", "/Users/me/dev/worktrees/app-b")]))
    }

    /// A trailing slash and an archived sibling still count as sharing.
    @Test func sharedDirectoryIsKept() {
        let target = Self.session("a", "/Users/me/dev/pa/")
        #expect(!target.mayPruneWorktree(among: [target, Self.session("b", "/Users/me/dev/pa")]))
        #expect(!target.mayPruneWorktree(among: [target, Self.session("c", "/Users/me/dev/pa/", archived: true)]))
    }
}
