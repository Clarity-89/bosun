import Foundation
import Testing
@testable import BosunCore

/// `add` as the New Session dialog and Quick Session build it.
@Suite struct AddArgumentsTests {
    @Test func commandWithArgumentsStaysOneArgument() {
        let arguments = AgentDeckCLI.addArguments(NewSessionRequest(
            directory: "/tmp/p", command: "codex --dangerously-bypass-approvals-and-sandbox"
        ))
        #expect(arguments.contains(["-c", "codex --dangerously-bypass-approvals-and-sandbox"]))
    }

    /// `-b` alone would create a branch with no worktree to put it in.
    @Test func noWorktreeMeansNoBranchFlags() {
        let arguments = AgentDeckCLI.addArguments(NewSessionRequest(
            directory: "/tmp/p", command: "omp", worktreeBranch: nil, createBranch: true
        ))
        #expect(!arguments.contains("-w"))
        #expect(!arguments.contains("-b"))
    }

    @Test(arguments: [true, false])
    func worktreeBranchIsNewOnlyWhenAsked(createBranch: Bool) {
        let arguments = AgentDeckCLI.addArguments(NewSessionRequest(
            directory: "/tmp/p", command: "omp", worktreeBranch: "feature/x", createBranch: createBranch
        ))
        #expect(arguments.contains(["-w", "feature/x"]))
        #expect(arguments.contains("-b") == createBranch)
    }

    /// The hook only exists for a worktree, so the flag only goes with one.
    @Test(arguments: [(true, false), (false, true)])
    func theSetupHookIsSkippedOnlyWhenAsked(runsSetup: Bool, skips: Bool) {
        let arguments = AgentDeckCLI.addArguments(NewSessionRequest(
            directory: "/tmp/p", command: "omp", worktreeBranch: "feature/x", runsWorktreeSetup: runsSetup
        ))
        #expect(arguments.contains("--skip-hooks") == skips)
        let plain = AgentDeckCLI.addArguments(NewSessionRequest(directory: "/tmp/p", command: "omp", runsWorktreeSetup: false))
        #expect(!plain.contains("--skip-hooks"))
    }

    @Test func quickSessionLeavesTheTitleToAgentDeck() {
        let arguments = AgentDeckCLI.addArguments(NewSessionRequest(
            title: "ignored", directory: "/tmp/p", command: "omp", quick: true
        ))
        #expect(arguments.contains("--quick"))
        #expect(!arguments.contains("-t"))
    }

    @Test func directoryComesLastWithHomeExpanded() {
        let arguments = AgentDeckCLI.addArguments(NewSessionRequest(
            title: "t", directory: "~/dev/bosun", groupPath: "omp", command: "omp"
        ))
        #expect(arguments.last == FileManager.default.homeDirectoryForCurrentUser.path + "/dev/bosun")
    }
}

/// `group list --json` from agent-deck's own golden file
/// (`cmd/agent-deck/testdata/goldens/group_list_json.golden`).
@Suite struct GroupListDecodingTests {
    static let golden = """
        {
          "groups": [
            {"name": "My Sessions", "path": "my-sessions", "session_count": 2,
             "status": {"running": 0, "waiting": 0, "idle": 0, "error": 2, "stopped": 0}},
            {"name": "Backend", "path": "backend", "session_count": 4,
             "status": {"running": 0, "waiting": 0, "idle": 0, "error": 2, "stopped": 1},
             "children": [
               {"name": "API", "path": "backend/api", "session_count": 2,
                "status": {"running": 0, "waiting": 0, "idle": 0, "error": 0, "stopped": 1}}
             ]}
          ],
          "total_groups": 3,
          "total_sessions": 6
        }
        """

    /// A subgroup follows its parent and is named after it, so two subgroups
    /// of the same name stay apart.
    @Test func subgroupsFollowTheirParentNamedAfterIt() throws {
        let groups = try AgentDeckCLI.decodeGroups(Data(Self.golden.utf8))
        #expect(groups.map(\.path) == ["my-sessions", "backend", "backend/api"])
        #expect(groups.map(\.label) == ["My Sessions", "Backend", "Backend › API"])
    }
}

/// Which group the New Session dialog and Quick Session start on.
@Suite struct ListedPathTests {
    static let groups = [DeckGroup(path: "my", label: "My"), DeckGroup(path: "work", label: "Work")]

    @Test func aListedGroupStays() {
        #expect(DeckGroup.listedPath("work", in: Self.groups) == "work")
    }

    /// "Ungrouped" has no path, and a group can be gone since the last list.
    @Test(arguments: ["", "old"])
    func anUnlistedGroupGivesWayToTheFirst(path: String) {
        #expect(DeckGroup.listedPath(path, in: Self.groups) == "my")
    }

    /// With no list to go by (a failed `group list`), the row's own group
    /// is still the best guess.
    @Test func noListKeepsThePath() {
        #expect(DeckGroup.listedPath("work", in: []) == "work")
    }
}
