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

    /// agent-deck exits 0 from `session remove --prune-worktree
    /// --delete-branch` whether the worktree and its branch went or stayed;
    /// only its stderr says. A `note:` is one kept on purpose, and no failure.
    @Test func aWorktreeOrBranchAgentDeckCouldNotRemoveFailsTheDelete() {
        let reply = """
            {
              "id": "c64f038c-1793696898",
              "success": true,
              "title": "owner"
            }
            """
        let kept = ProcessResult(command: "agent-deck session remove --json", status: 0, stdout: reply, stderr: """
            warn: inbox sweep for c64f038c-1793696898 failed: no such file
            warn: worktree remove failed for c64f038c-1793696898: not a git or jujutsu repository: /private/tmp/project/.worktrees/feature-probe

            """)
        #expect(throws: AgentDeckCLIError.reported("Worktree remove failed for c64f038c-1793696898: not a git or jujutsu repository: /private/tmp/project/.worktrees/feature-probe")) {
            try AgentDeckCLI.checkWorktreeRemoved(kept)
        }
        let checkedOut = ProcessResult(command: "agent-deck session remove --json", status: 0, stdout: reply, stderr: """
            warn: branch delete failed for c64f038c-1793696898: failed to delete branch: error: cannot delete branch 'feature/probe' used by worktree at '/private/tmp/project/.worktrees/other': exit status 1

            """)
        #expect(throws: AgentDeckCLIError.reported("Branch delete failed for c64f038c-1793696898: failed to delete branch: error: cannot delete branch 'feature/probe' used by worktree at '/private/tmp/project/.worktrees/other': exit status 1")) {
            try AgentDeckCLI.checkWorktreeRemoved(checkedOut)
        }
        let shared = ProcessResult(command: "agent-deck session remove --json", status: 0, stdout: reply, stderr: """
            note: worktree ~/project/.worktrees/feature-probe kept: another session still uses it
            note: branch main kept: the repository's default branch

            """)
        #expect(throws: Never.self) { try AgentDeckCLI.checkWorktreeRemoved(shared) }
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
