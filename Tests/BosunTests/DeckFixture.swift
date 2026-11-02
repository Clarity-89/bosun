import Foundation
import Testing
@testable import Bosun
@testable import BosunCore

/// GitHub with nothing in it, so the Inbox's rounds ask no `gh`.
struct FakeGitHub: GitHubClient {
    func inbox() async throws -> GitHubInbox {
        GitHubInbox(
            reviewRequests: .empty, teamReviewRequests: .empty, pullRequests: .empty,
            assignedIssues: .empty, openedIssues: .empty, mentions: .empty
        )
    }

    func pullRequests(forBranches branches: [BranchRef]) async throws -> [BranchRef: [GitHubPullRequest]] {
        [:]
    }

    func issues(_ refs: [IssueRef]) async throws -> [GitHubIssue?] {
        refs.map { _ in nil }
    }
}

/// A row as `list --json` gives it: `agentdeck_<id>` for its tmux session,
/// unless it never ran and so has none.
func deckSession(
    _ id: String, group: String = "g", status: SessionStatus = .running, substate: String? = nil,
    hasTmux: Bool = true, archived: Bool = false, inWorktree: Bool = false
) -> DeckSession {
    let path = inWorktree ? "/worktrees/\(id)" : "/p/\(id)"
    return DeckSession(
        id: id, title: id, path: path, group: group, tool: "codex", status: status, substate: substate,
        tmuxSession: hasTmux ? "agentdeck_\(id)" : nil, worktreePath: inWorktree ? path : nil, archived: archived,
        lastActivityAt: nil
    )
}

func window(_ id: String, index: Int, name: String = "zsh") -> SessionWindow {
    SessionWindow(index: index, windowID: id, name: name, command: name)
}

/// Defaults in a dictionary, so a test leaves no preferences file and
/// shares none with another.
@MainActor
final class MemoryDefaults: @MainActor Defaults {
    private(set) var values: [String: Any] = [:]

    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

/// A model on a fake agent-deck, an empty GitHub and defaults of its own.
/// Its loops stop when the test ends, or the model would poll the fake
/// for as long as the process runs.
@MainActor
final class DeckFixture {
    let deck = FakeAgentDeck()
    let defaults = MemoryDefaults()
    let model: DeckModel

    /// `groups` defaults to the sessions' groups in order of appearance.
    init(sessions: [DeckSession] = [], groups: [String]? = nil, windows: [String: [SessionWindow]] = [:]) {
        deck.sessions = sessions
        var seen = Set<String>()
        deck.groups = (groups ?? sessions.map(\.group).filter { seen.insert($0).inserted })
            .filter { !$0.isEmpty }
            .map { DeckGroup(path: $0, label: $0) }
        deck.windows = WindowListing(windows: windows, currentWindows: windows.compactMapValues { $0.first?.windowID })
        model = DeckModel(deck: deck, gitHub: FakeGitHub(), defaults: defaults)
    }

    isolated deinit {
        model.stop()
    }

    var sessions: [DeckSession] { model.sessions }

    func session(_ id: String) -> DeckSession {
        model.sessions.first { $0.id == id }!
    }

    func select(_ id: String, window: String? = nil) {
        model.select(.pane(PaneTarget(sessionID: id, windowID: window)))
    }

    /// Selects the session and waits for its terminal.
    func selectAndAttach(_ id: String) async throws -> AttachedPane {
        select(id)
        #expect(await eventually { self.model.attachedPane?.sessionID == id })
        return try #require(model.attachedPane)
    }
}

/// Polls `condition` for up to `timeout`: the fake answers in a few task
/// hops, the follower and the 2 s tmux poll in their own time.
@MainActor
func eventually(timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

/// Lets whatever the model has queued on the main actor run, for a check
/// that nothing more happens.
@MainActor
func settled() async {
    for _ in 0..<20 { await Task.yield() }
}
