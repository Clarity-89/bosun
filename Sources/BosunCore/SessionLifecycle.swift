import Foundation

/// `session start|stop|restart|remove`, `rename` and `group delete`. A refusal
/// `AgentDeckCLIError.reported` with agent-deck's own message.
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

    public func renameSession(id: String, to title: String) async throws {
        _ = try await run(["rename", id, title, "--json"])
    }

    /// Stops the session's processes, deletes its git worktree, uncommitted
    /// changes included, and removes it from agent-deck. agent-deck keeps a
    /// worktree another session still works in; the agent's own conversation
    /// files are kept either way.
    public func deleteSession(id: String) async throws {
        _ = try await run(["session", "remove", id, "--force", "--prune-worktree", "--json"])
    }

    /// Deletes every session in the group and its subgroups, archived ones
    /// included, as `deleteSession` does one, then the group and its
    /// subgroups. A failure stops it there: what is left keeps its group.
    /// agent-deck refuses the default group.
    public func deleteGroup(path: String) async throws {
        for session in try await list() where session.isIn(groupTree: path) {
            try await deleteSession(id: session.id)
        }
        // Forced, so a session added meanwhile moves up a level rather than
        // failing the delete.
        _ = try await run(["group", "delete", path, "--force", "--json"])
    }
}

private struct RestartReply: Decodable {
    let skipped: Bool?
    let reason: String?
}
