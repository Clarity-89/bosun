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

/// `sessions` in agent-deck's groups, consecutive rows forming a group as
/// `DeckModel.groups` has them.
private func groups(_ sessions: [DeckSession]) -> [SessionGroup] {
    var groups: [SessionGroup] = []
    for session in sessions {
        if groups.last?.name == session.group {
            groups[groups.count - 1].sessions.append(session)
        } else {
            groups.append(SessionGroup(name: session.group, sessions: [session]))
        }
    }
    return groups
}

/// The row ids the filter lists: a group's as `group:name`, a session's as
/// its id, a window's as `session/window`.
private func ids(
    _ filter: SidebarFilter, _ sessions: [DeckSession], collapsed: Set<String> = [], selected: String? = nil,
    windows: [String: [SessionWindow]] = [:]
) -> [String] {
    filter.rows(groups: groups(sessions), collapsed: collapsed, selected: selected) { windows[$0, default: []].dropFirst() }
        .map(\.id)
}

/// The session list's search, Open filter and sort by last activity.
@Suite struct SidebarFilterTests {
    static let searched = [
        session("title", title: "Fix the Résumé parser"),
        session("path", path: "/Users/me/dev/agent-deck"),
        session("tool", tool: "claude"),
    ]

    /// The TUI's search fields, case and diacritics aside; a blank query
    /// searches for nothing, so it hides nothing. A group with no match
    /// left drops out, header and all.
    @Test(arguments: [
        ("resume", ["group:g", "title"]),
        ("AGENT-DECK", ["group:g", "path"]),
        ("Claude", ["group:g", "tool"]),
        ("  claude \n", ["group:g", "tool"]),
        ("   ", ["group:g", "title", "path", "tool"]),
        ("nowhere", []),
    ] as [(String, [String])])
    func searchMatchesTitlePathAndTool(query: String, rows: [String]) {
        #expect(ids(SidebarFilter(query: query), Self.searched) == rows)
    }

    /// A group with nothing left drops out; the rest keep agent-deck's order.
    @Test func groupsWithoutAMatchDropOut() {
        let sessions = [
            session("a1", group: "a", title: "api"),
            session("b1", group: "b", title: "web"),
            session("c1", group: "c", title: "api docs"), session("c2", group: "c", title: "ci"),
        ]
        #expect(ids(SidebarFilter(query: "api"), sessions) == ["group:a", "a1", "group:c", "c1"])
    }

    /// A search lists every match, so it holds a folded group open; the fold
    /// is back once the search ends.
    @Test func searchHoldsFoldedGroupsOpen() {
        let sessions = [session("a1", group: "a", title: "api"), session("b1", group: "b", title: "api")]
        #expect(ids(SidebarFilter(query: "api"), sessions, collapsed: ["a"]) == ["group:a", "a1", "group:b", "b1"])
        #expect(ids(SidebarFilter(), sessions, collapsed: ["a"]) == ["group:a", "group:b", "b1"])
    }

    /// The TUI's Open filter with its default excludes: error and stopped
    /// go, every other status stays.
    @Test func openFilterHidesErrorAndStopped() {
        let statuses: [SessionStatus] = [.running, .waiting, .idle, .error, .stopped, .starting, .queued, .unknown]
        let sessions = statuses.map { session($0.rawValue, status: $0) }
        #expect(ids(SidebarFilter(openOnly: true), sessions) == ["group:g", "running", "waiting", "idle", "starting", "queued", "unknown"])
    }

    /// Both filters hold at once: a match that has stopped stays hidden.
    @Test func searchAndOpenFilterCombine() {
        let sessions = [session("live", title: "api"), session("dead", title: "api v1", status: .stopped), session("web")]
        #expect(ids(SidebarFilter(query: "api", openOnly: true), sessions) == ["group:g", "live"])
    }

    /// What the pane shows keeps its row: the selected session stays, its
    /// group with it, where the Open filter would hide it. A search still
    /// hides it, as the search is what the list shows then.
    @Test func selectedSessionStaysUnderTheOpenFilter() {
        let sessions = [session("a1", group: "a", status: .stopped), session("b1", group: "b")]
        #expect(ids(SidebarFilter(openOnly: true), sessions, selected: "a1") == ["group:a", "a1", "group:b", "b1"])
        #expect(ids(SidebarFilter(openOnly: true), sessions, selected: "b1") == ["group:b", "b1"])
        #expect(ids(SidebarFilter(query: "b", openOnly: true), sessions, selected: "a1") == ["group:b", "b1"])
    }

    /// One list across the groups, no headers, latest activity first. Ties,
    /// and sessions with no activity yet, keep agent-deck's order; the
    /// filters still hold, and a session's extra windows follow it.
    @Test func activitySortListsEverySessionAcrossGroups() {
        let sessions = [
            session("a1", group: "a", activeAt: 5), session("a2", group: "a"),
            session("b1", group: "b", activeAt: 30), session("b2", group: "b", activeAt: 10),
            session("c1", group: "c", activeAt: 30), session("c2", group: "c", status: .stopped, activeAt: 20),
        ]
        let windows = ["b2": [SessionWindow(index: 0, windowID: "@1", name: "omp", command: "omp"), SessionWindow(index: 1, windowID: "@3", name: "zsh", command: "zsh")]]
        #expect(ids(SidebarFilter(sort: .activity), sessions, windows: windows) == ["b1", "c1", "c2", "b2", "b2/@3", "a1", "a2"])
        #expect(ids(SidebarFilter(openOnly: true, sort: .activity), sessions) == ["b1", "c1", "b2", "a1", "a2"])
    }
}
