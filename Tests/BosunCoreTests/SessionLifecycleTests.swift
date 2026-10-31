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
}

/// Which sessions a group's Delete takes with it: a session in a group whose
/// name only starts the same must survive.
@Suite struct GroupTreeTests {
    private func session(in group: String) -> DeckSession {
        DeckSession(id: group, title: group, path: "/p", group: group, tool: "shell", status: .idle, substate: nil, tmuxSession: nil, worktreePath: nil, archived: false, lastActivityAt: nil)
    }

    @Test func groupAndSubgroupsOnly() {
        #expect(session(in: "pa").isIn(groupTree: "pa"))
        #expect(session(in: "pa/work").isIn(groupTree: "pa"))
        #expect(!session(in: "pa2").isIn(groupTree: "pa"))
        #expect(!session(in: "pa-work/x").isIn(groupTree: "pa"))
        #expect(!session(in: "my/pa").isIn(groupTree: "pa"))
    }
}
