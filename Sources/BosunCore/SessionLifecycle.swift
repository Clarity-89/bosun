import Foundation

/// `session start|stop|restart|remove` and `rename`. A refusal arrives as
/// `AgentDeckCLIError.reported` with agent-deck's own message.
extension AgentDeckCLI {
    public func startSession(id: String) async throws {
        // No wait for the tool's own session id: Bosun never reads it, and
        // the hooks still record it.
        _ = try await run(["session", "start", id, "--no-wait", "--json"])
    }

    public func stopSession(id: String) async throws {
        _ = try await run(["session", "stop", id, "--json"])
    }

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

    /// Stops the session's processes and removes it from agent-deck; with
    /// `pruneWorktree`, also deletes its git worktree, uncommitted changes
    /// included. The agent's own conversation files are kept.
    public func deleteSession(id: String, pruneWorktree: Bool) async throws {
        _ = try await run(["session", "remove", id, "--force", "--json"] + (pruneWorktree ? ["--prune-worktree"] : []))
    }
}

private struct RestartReply: Decodable {
    let skipped: Bool?
    let reason: String?
}

extension SessionStatus {
    /// Whether the session has a process to stop or restart; a stopped or
    /// failed one can only be started.
    public var hasProcess: Bool {
        self != .stopped && self != .error
    }
}

extension DeckSession {
    /// Whether deleting this session may delete its git worktree too: not
    /// while another session, archived ones included, works in the same
    /// directory, since its uncommitted changes would go as well. The TUI's
    /// delete keeps a shared worktree the same way.
    public func mayPruneWorktree(among sessions: [DeckSession]) -> Bool {
        let path = (self.path as NSString).standardizingPath
        return !sessions.contains { $0.id != id && ($0.path as NSString).standardizingPath == path }
    }
}
