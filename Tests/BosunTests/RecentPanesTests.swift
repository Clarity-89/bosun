import Testing
@testable import Bosun
@testable import BosunCore

private func pane(_ sessionID: String, tmux: String? = nil, view: String? = "view") -> AttachedPane {
    AttachedPane(sessionID: sessionID, tmuxSession: tmux ?? "agentdeck_\(sessionID)", view: view, launch: AttachLaunch(command: "tmux", environment: [:]))
}

private func session(_ id: String, status: SessionStatus = .idle, tmux: String? = nil) -> DeckSession {
    DeckSession(id: id, title: id, path: "/p", group: "g", tool: "shell", status: status, substate: nil, tmuxSession: tmux ?? "agentdeck_\(id)", archived: false)
}

/// The terminals kept attached for a quick switch back.
@Suite struct RecentPanesTests {
    @Test func pastTheLimitTheLeastRecentlyShownGoes() {
        var recent = RecentPanes(limit: 2)
        _ = recent.add(pane("a"))
        _ = recent.add(pane("b"))
        _ = recent.touch("a")
        let leaving = recent.add(pane("c"))
        #expect(leaving.map(\.sessionID) == ["b"])
        #expect(recent.panes.map(\.sessionID) == ["a", "c"])
    }

    /// A session has one terminal; a new one replaces the old, which ends.
    @Test func newPaneReplacesTheSessionsOld() {
        var recent = RecentPanes(limit: 5)
        let old = pane("a")
        _ = recent.add(old)
        let leaving = recent.add(pane("a"))
        #expect(leaving.map(\.id) == [old.id])
        #expect(recent.panes.count == 1)
    }

    @Test func touchWithoutAPaneChangesNothing() {
        var recent = RecentPanes(limit: 5)
        _ = recent.add(pane("a"))
        #expect(recent.touch("b") == nil)
        #expect(recent.panes.map(\.sessionID) == ["a"])
    }

    /// A view of a session agent-deck recreated under another tmux name
    /// shows the dead one's windows; a client through agent-deck ends by
    /// itself instead.
    @Test func stalePanesAreGoneStoppedOrRegrouped() {
        var recent = RecentPanes(limit: 5)
        for added in [pane("gone"), pane("stopped"), pane("renamed"), pane("renamedNoView", view: nil), pane("kept")] {
            _ = recent.add(added)
        }
        let sessions = [
            session("stopped", status: .stopped),
            session("renamed", tmux: "agentdeck_renamed_2"),
            session("renamedNoView", tmux: "agentdeck_renamedNoView_2"),
            session("kept"),
        ]
        let stale = recent.removeStale(given: sessions)
        #expect(stale.map(\.sessionID) == ["gone", "stopped", "renamed"])
        #expect(recent.panes.map(\.sessionID) == ["renamedNoView", "kept"])
    }
}
