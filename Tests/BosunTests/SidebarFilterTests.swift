import Foundation
import Testing
@testable import Bosun
@testable import BosunCore

private func session(
    _ id: String, group: String = "g", title: String = "", path: String = "/p", tool: String = "shell",
    status: SessionStatus = .idle, activeAt seconds: TimeInterval? = nil
) -> DeckSession {
    DeckSession(
        id: id, title: title.isEmpty ? id : title, path: path, group: group, tool: tool, status: status,
        substate: nil, tmuxSession: nil, worktreePath: nil, archived: false, lastActivityAt: seconds.map(Date.init(timeIntervalSince1970:))
    )
}

private func kept(_ filter: SidebarFilter, _ sessions: [DeckSession]) -> [String] {
    filter.apply(to: [SessionGroup(name: "g", sessions: sessions)]).flatMap { $0.sessions.map(\.id) }
}

/// The session list's search, Open filter and sort by last activity.
@Suite struct SidebarFilterTests {
    static let searched = [
        session("title", title: "Fix the Résumé parser"),
        session("path", path: "/Users/me/dev/agent-deck"),
        session("tool", tool: "claude"),
    ]

    /// The TUI's search fields, case and diacritics aside; a blank query
    /// searches for nothing, so it hides nothing.
    @Test(arguments: [
        ("resume", ["title"]),
        ("AGENT-DECK", ["path"]),
        ("Claude", ["tool"]),
        ("  claude \n", ["tool"]),
        ("   ", ["title", "path", "tool"]),
        ("nowhere", []),
    ] as [(String, [String])])
    func searchMatchesTitlePathAndTool(query: String, matches: [String]) {
        #expect(kept(SidebarFilter(query: query), Self.searched) == matches)
    }

    /// A group with nothing left drops out; the rest keep agent-deck's order.
    @Test func groupsWithoutAMatchDropOut() {
        let groups = [
            SessionGroup(name: "a", sessions: [session("a1", title: "api")]),
            SessionGroup(name: "b", sessions: [session("b1", title: "web")]),
            SessionGroup(name: "c", sessions: [session("c1", title: "api docs"), session("c2", title: "ci")]),
        ]
        let filtered = SidebarFilter(query: "api").apply(to: groups)
        #expect(filtered.map(\.name) == ["a", "c"])
        #expect(filtered.map { $0.sessions.map(\.id) } == [["a1"], ["c1"]])
    }

    /// The TUI's Open filter with its default excludes: error and stopped
    /// go, every other status stays.
    @Test func openFilterHidesErrorAndStopped() {
        let statuses: [SessionStatus] = [.running, .waiting, .idle, .error, .stopped, .starting, .queued, .unknown]
        let sessions = statuses.map { session($0.rawValue, status: $0) }
        #expect(kept(SidebarFilter(openOnly: true), sessions) == ["running", "waiting", "idle", "starting", "queued", "unknown"])
    }

    /// Both filters hold at once: a match that has stopped stays hidden.
    @Test func searchAndOpenFilterCombine() {
        let sessions = [session("live", title: "api"), session("dead", title: "api v1", status: .stopped), session("web")]
        #expect(kept(SidebarFilter(query: "api", openOnly: true), sessions) == ["live"])
    }

    /// One list across the groups, latest activity first. Ties, and sessions
    /// with no activity yet, keep agent-deck's order; the filters still hold.
    @Test func recentListsEverySessionAcrossGroups() {
        let sessions = [
            session("a1", group: "a", activeAt: 5), session("a2", group: "a"),
            session("b1", group: "b", activeAt: 30), session("b2", group: "b", activeAt: 10),
            session("c1", group: "c", activeAt: 30), session("c2", group: "c", status: .stopped, activeAt: 20),
        ]
        #expect(SidebarFilter(byRecent: true).recent(sessions).map(\.id) == ["b1", "c1", "c2", "b2", "a1", "a2"])
        #expect(SidebarFilter(openOnly: true, byRecent: true).recent(sessions).map(\.id) == ["b1", "c1", "b2", "a1", "a2"])
    }
}
