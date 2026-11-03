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

    /// Stops the session's processes, removes it from agent-deck and
    /// deletes its git worktree, uncommitted changes included; the agent's
    /// own conversation files are kept. agent-deck's `--prune-worktree`
    /// goes first, and a directory it leaves behind goes here, unless
    /// another session still works in it: agent-deck's prune skips without
    /// a word a worktree whose recorded repository it cannot open, and
    /// only warns on stderr when `git worktree remove` fails. Both get the
    /// time a large tree takes to delete; a timeout would kill agent-deck,
    /// and the git it runs, between the session's end and its row's.
    public func deleteSession(id: String) async throws {
        // Asked first: the row that records the worktree goes with the session.
        let worktree: WorktreeInfo?
        do {
            worktree = try await worktreeInfo(sessionID: id)
        } catch AgentDeckCLIError.reported {
            worktree = nil
        }
        _ = try await run(["session", "remove", id, "--force", "--prune-worktree", "--json"], timeout: .seconds(300))
        guard let worktree, FileManager.default.fileExists(atPath: worktree.path),
              try await !list().contains(where: { $0.id != id && $0.worksIn(worktree.path) })
        else { return }
        try await removeWorktree(at: worktree.path)
    }

    /// Deletes a linked worktree's directory, uncommitted changes included,
    /// and its entry in the repository: `git worktree remove` from inside
    /// it, with the second `--force` a lock asks for, then the directory
    /// itself and `git worktree prune` when git refuses, as it refuses a
    /// worktree whose entry under `.git/worktrees` is already gone. A path
    /// whose `.git` is not a linked worktree's stays: a `.git` directory is
    /// a repository of its own, which agent-deck's worktree-reuse sessions
    /// record as their worktree.
    func removeWorktree(at path: String) async throws {
        guard let gitDir = Self.linkedWorktreeGitDir(at: path) else { return }
        let git = try Self.executablePath(named: "git")
        let environment = childEnvironment(binaryDirectory: nil)
        _ = try await Subprocess.run(
            executable: git, arguments: ["-C", path, "worktree", "remove", "--force", "--force", path],
            environment: environment, timeout: .seconds(300)
        )
        guard FileManager.default.fileExists(atPath: path) else { return }
        try FileManager.default.removeItem(atPath: path)
        let commonDir = ((gitDir as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        _ = try await Subprocess.run(
            executable: git, arguments: ["--git-dir", commonDir, "worktree", "prune"],
            environment: environment, timeout: .seconds(30)
        )
    }

    /// The git directory of the linked worktree at `path`, from the `.git`
    /// file `git worktree add` leaves there: `gitdir: <repo>/.git/worktrees/<id>`,
    /// resolved against `path` when relative. Nil for a repository of its
    /// own, whose `.git` is a directory, for a submodule, whose git directory
    /// is under `modules`, and for a directory with no `.git`.
    static func linkedWorktreeGitDir(at path: String) -> String? {
        let gitFile = (path as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitFile, isDirectory: &isDirectory), !isDirectory.boolValue,
              let contents = try? String(contentsOfFile: gitFile, encoding: .utf8),
              let line = contents.split(whereSeparator: \.isNewline).first, line.hasPrefix("gitdir:")
        else { return nil }
        let gitDir = URL(
            fileURLWithPath: line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces),
            relativeTo: URL(fileURLWithPath: path, isDirectory: true)
        ).standardizedFileURL.path
        guard ((gitDir as NSString).deletingLastPathComponent as NSString).lastPathComponent == "worktrees" else { return nil }
        return gitDir
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
