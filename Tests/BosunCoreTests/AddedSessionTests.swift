import Testing
@testable import BosunCore

/// `add --json` output as agent-deck 1.16.34 writes it when the repository
/// has a `.agent-deck/worktree-setup.sh`: the hook's stdout before the
/// reply, its outcome on stderr.
@Suite struct AddedSessionTests {
    static let reply = """
        {
          "command": "sh",
          "group": "hookrepo",
          "id": "5bc02ee2-1793432819",
          "path": "/Users/me/dev/worktrees/hookrepo/me-hooktest",
          "started": false,
          "success": true,
          "worktree_branch": "me/hooktest"
        }

        """

    @Test func theHooksOutputComesBeforeTheReply() throws {
        let stdout = "hook: copying env into /Users/me/dev/worktrees/hookrepo/me-hooktest\nhook: done\n" + Self.reply
        let stderr = "Running worktree setup script...\nWorktree setup script completed in 300ms\n"
        #expect(try AgentDeckCLI.addedSession(stdout: stdout, stderr: stderr) == AddedSession(id: "5bc02ee2-1793432819", setupHookNotice: nil))
    }

    @Test func aHookThatPrintsAnObjectDoesNotPassForTheReply() throws {
        let stdout = "{\"id\": \"not-the-session\"}\n{\n  \"step\": 1\n}\n" + Self.reply
        #expect(try AgentDeckCLI.addedSession(stdout: stdout, stderr: "").id == "5bc02ee2-1793432819")
    }

    @Test func anUnapprovedHookIsReportedFromStderr() throws {
        let notice = "worktree setup hook not run: /tmp/hookrepo/.agent-deck/worktree-setup.sh is not approved yet (sha256:55289a28eb17, exec); review and approve with `agent-deck worktree trust-hooks /tmp/hookrepo --hook setup`, or run it once with --run-hooks"
        let added = try AgentDeckCLI.addedSession(stdout: Self.reply, stderr: notice + "\n")
        #expect(added.setupHookNotice == notice)
    }

    @Test func aFailedHookIsReportedWithoutTheWarningPrefix() throws {
        let stderr = """
            Running worktree setup script...
            hook: oops
            Worktree setup script failed after 300ms: worktree setup script failed: exit status 3
            Warning: worktree setup script failed: worktree setup script failed: exit status 3

            """
        let added = try AgentDeckCLI.addedSession(stdout: "hook: starting\n" + Self.reply, stderr: stderr)
        #expect(added.setupHookNotice == "worktree setup script failed: worktree setup script failed: exit status 3")
    }

    @Test func noReplyIsAnError() {
        #expect(throws: (any Error).self) {
            try AgentDeckCLI.addedSession(stdout: "hook: done\n", stderr: "")
        }
    }
}
