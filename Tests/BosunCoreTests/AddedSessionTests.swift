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
        let added = try AgentDeckCLI.addedSession(stdout: Self.reply, stderr: "Reusing existing worktree at /tmp/wt for branch me/hooktest\n" + notice + "\n")
        #expect(added.setupHookNotice == notice)
    }

    @Test func aFailedHookIsReportedWithItsLastLines() throws {
        let stderr = """
            Running worktree setup script...
            Syncing data/ ...
            This project is configured to use pnpm because /tmp/wt/package.json has a "packageManager" field
            Worktree setup script failed after 300ms: worktree setup script failed: exit status 1
            Warning: worktree setup script failed: worktree setup script failed: exit status 1

            """
        let added = try AgentDeckCLI.addedSession(stdout: "hook: starting\n" + Self.reply, stderr: stderr)
        #expect(added.setupHookNotice == "worktree setup script failed: worktree setup script failed: exit status 1 — Syncing data/ ... | This project is configured to use pnpm because /tmp/wt/package.json has a \"packageManager\" field")
    }

    /// agent-deck through 1.16.34 kept the hook's stdout on `add`'s own.
    @Test func theHooksStdoutServesWhenStderrHasOnlyAgentDecksLines() throws {
        let stderr = """
            Running worktree setup script...
            Worktree setup script failed after 300ms: worktree setup script failed: exit status 3
            Warning: worktree setup script failed: worktree setup script failed: exit status 3

            """
        let added = try AgentDeckCLI.addedSession(stdout: "{\"step\": 1}\nhook: oops\n" + Self.reply, stderr: stderr)
        #expect(added.setupHookNotice == "worktree setup script failed: worktree setup script failed: exit status 3 — {\"step\": 1} | hook: oops")
    }

    @Test func theTailIsTheLastFiveLinesCarriageReturnsIncluded() {
        #expect(AgentDeckCLI.hookOutputTail("one\ntwo\rthree   3\n\n  four\rfive\nsix\nseven\n") == "three 3 | four | five | six | seven")
        #expect(AgentDeckCLI.hookOutputTail("abcdefghij", maxLength: 6) == "…fghij")
        #expect(AgentDeckCLI.hookOutputTail("Running worktree setup script...\n\n") == nil)
    }

    /// `worktree setup --json` reports its error on stdout and leaves the
    /// hook's lines on stderr; an unapproved hook prints nothing there.
    @Test func aRerunFailureGoesOnWithTheHooksLines() {
        let message = "worktree setup script failed: exit status 1"
        #expect(AgentDeckCLI.withHookOutput(message, stderr: "Running worktree setup script...\nSetting up Grafana Enterprise ...\nUsage Error: pnpm not found\n") == "worktree setup script failed: exit status 1 — Setting up Grafana Enterprise ... | Usage Error: pnpm not found")
        #expect(AgentDeckCLI.withHookOutput(message, stderr: "") == message)
    }

    @Test func noReplyIsAnError() {
        #expect(throws: (any Error).self) {
            try AgentDeckCLI.addedSession(stdout: "hook: done\n", stderr: "")
        }
    }
}
