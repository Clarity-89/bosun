import Foundation

/// `session start|stop|restart|remove`, `rename`, `group delete` and
/// `worktree setup`. A refusal `AgentDeckCLIError.reported` with
/// agent-deck's own message.
extension AgentDeckCLI {
    /// For a session that has never run, which has no tmux session for
    /// `session start` to refuse. No wait for the tool's own session id:
    /// Bosun never reads it, and the hooks still record it.
    public func startSession(id: String) async throws {
        _ = try await run(["session", "start", id, "--no-wait", "--json"])
    }

    public func stopSession(id: String) async throws {
        _ = try await run(["session", "stop", id, "--json"])
    }

    /// Also how a stopped session is started: `session start` refuses one
    /// whose tmux session still exists, as it does with a kept dead pane.
    public func restartSession(id: String) async throws {
        try Self.checkRestarted(await run(["session", "restart", id, "--json"]))
    }

    /// agent-deck skips a restart of a session it started under a minute ago
    /// or whose agent failed to authenticate, and says why; nothing restarted,
    /// so that is a failure here.
    static func checkRestarted(_ result: ProcessResult) throws {
        let reply = try JSONDecoder().decode(RestartReply.self, from: Data(result.stdout.utf8))
        if reply.skipped == true {
            throw AgentDeckCLIError.reported("Restart skipped: \(reply.reason ?? "agent-deck gave no reason")")
        }
    }

    /// Runs the repository's worktree setup hook again in the session's
    /// worktree, through agent-deck's consent gate: an unapproved hook is
    /// refused with the command that approves it. agent-deck 1.16.35 and
    /// later; before, an unknown command. The hook keeps agent-deck's own
    /// timeout, a minute by default, so the wait here outlasts it. A
    /// failure goes on with the hook's last lines, which under `--json`
    /// all reach stderr.
    public func runWorktreeSetup(sessionID: String) async throws {
        let result = try await execute(["worktree", "setup", sessionID, "--json"], timeout: .seconds(300))
        do {
            try Self.checkReported(result)
        } catch AgentDeckCLIError.reported(let message) {
            throw AgentDeckCLIError.reported(Self.withHookOutput(message, stderr: result.stderr))
        }
    }

    public func renameSession(id: String, to title: String) async throws {
        _ = try await run(["rename", id, title, "--json"])
    }

    /// Stops the session's processes, deletes its git worktree, uncommitted
    /// changes included, and removes it from agent-deck. agent-deck keeps a
    /// worktree another session still works in; the agent's own conversation
    /// files are kept either way. The removal gets the minutes a large tree
    /// takes to delete: a timeout would kill agent-deck, and the git it
    /// runs, between the session's end and its row's. A worktree agent-deck
    /// could not remove fails the delete here, though the session is gone:
    /// agent-deck says so on stderr only, and exits 0.
    public func deleteSession(id: String) async throws {
        let result = try await execute(["session", "remove", id, "--force", "--prune-worktree", "--json"], timeout: .seconds(300))
        try Self.checkReported(result)
        try Self.checkWorktreeRemoved(result)
    }

    /// `session remove --prune-worktree` warns on stderr about a worktree it
    /// could not remove, `warn: worktree remove failed for <id>: <why>`, and
    /// says `note:` of one it kept for another session; only the first is a
    /// failure, with agent-deck's reason.
    static func checkWorktreeRemoved(_ result: ProcessResult) throws {
        let prefix = "warn: worktree remove failed for "
        if let warning = result.stderr.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix(prefix) }) {
            throw AgentDeckCLIError.reported("Worktree remove failed for \(warning.dropFirst(prefix.count))")
        }
    }

    /// Deletes the group and its subgroups. Sessions still in them move up
    /// a level rather than failing the delete, so delete them first with
    /// `deleteSession`. agent-deck refuses the default group.
    public func deleteGroup(path: String) async throws {
        _ = try await run(["group", "delete", path, "--force", "--json"])
    }
}

private struct RestartReply: Decodable {
    let skipped: Bool?
    let reason: String?
}
