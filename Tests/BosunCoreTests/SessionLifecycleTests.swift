import Foundation
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

/// Which directory a delete may remove: only one whose `.git` is the file
/// `git worktree add` writes. A `.git` directory is a repository of its
/// own, a `modules` git directory a submodule's.
@Suite struct LinkedWorktreeTests {
    private func directory(withGitFile contents: String?) throws -> String {
        let path = NSTemporaryDirectory() + "bosun-wt-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        if let contents {
            try contents.write(toFile: path + "/.git", atomically: true, encoding: .utf8)
        }
        return path
    }

    @Test func aLinkedWorktreeNamesItsGitDirectory() throws {
        let path = try directory(withGitFile: "gitdir: /repo/.git/worktrees/feature\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(AgentDeckCLI.linkedWorktreeGitDir(at: path) == "/repo/.git/worktrees/feature")
    }

    @Test func aRelativeGitDirResolvesAgainstTheWorktree() throws {
        let path = try directory(withGitFile: "gitdir: ../../repo/.git/worktrees/feature")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let parent = ((path as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        #expect(AgentDeckCLI.linkedWorktreeGitDir(at: path) == parent + "/repo/.git/worktrees/feature")
    }

    @Test func aRepositorySubmoduleOrPlainDirectoryIsNot() throws {
        let repository = try directory(withGitFile: nil)
        try FileManager.default.createDirectory(atPath: repository + "/.git", withIntermediateDirectories: true)
        let submodule = try directory(withGitFile: "gitdir: ../.git/modules/sub\n")
        let plain = try directory(withGitFile: nil)
        defer { for path in [repository, submodule, plain] { try? FileManager.default.removeItem(atPath: path) } }
        #expect(AgentDeckCLI.linkedWorktreeGitDir(at: repository) == nil)
        #expect(AgentDeckCLI.linkedWorktreeGitDir(at: submodule) == nil)
        #expect(AgentDeckCLI.linkedWorktreeGitDir(at: plain) == nil)
        #expect(AgentDeckCLI.linkedWorktreeGitDir(at: plain + "/missing") == nil)
    }
}

/// Which sessions keep a worktree a delete would remove: one in it or
/// below it, by path or by worktree, through a symlink too; a sibling
/// whose name only starts the same does not.
@Suite struct WorksInTests {
    private func session(path: String, worktree: String? = nil) -> DeckSession {
        DeckSession(id: path, title: "s", path: path, group: "", tool: "shell", status: .idle, substate: nil, tmuxSession: nil, worktreePath: worktree, archived: false, lastActivityAt: nil)
    }

    @Test func inOrBelowTheDirectory() {
        #expect(session(path: "/wt/x").worksIn("/wt/x"))
        #expect(session(path: "/wt/x/pkg").worksIn("/wt/x"))
        #expect(session(path: "/wt/x/").worksIn("/wt/x"))
        #expect(session(path: "/wt/x").worksIn("/wt/x/"))
        #expect(session(path: "/elsewhere", worktree: "/wt/x").worksIn("/wt/x"))
        #expect(session(path: "/private/tmp/x").worksIn("/tmp/x"), "macOS's /tmp is a symlink")
        #expect(!session(path: "/wt/x2").worksIn("/wt/x"))
        #expect(!session(path: "/wt").worksIn("/wt/x"))
    }
}
