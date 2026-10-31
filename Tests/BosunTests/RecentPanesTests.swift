import Foundation
import Testing
@testable import Bosun
@testable import BosunCore

private func pane(_ sessionID: String, view: String? = "view") -> AttachedPane {
    AttachedPane(id: UUID(), sessionID: sessionID, view: view, launch: AttachLaunch(command: "tmux", environment: [:]), yieldsSize: false)
}

private func session(_ id: String, status: SessionStatus = .idle) -> DeckSession {
    DeckSession(id: id, title: id, path: "/p", group: "g", tool: "shell", status: status, substate: nil, tmuxSession: "agentdeck_\(id)", worktreePath: nil, archived: false, lastActivityAt: nil)
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

    /// A view left alone in its tmux group shows a killed session's windows,
    /// whatever the session's name is now; a client through agent-deck ends
    /// by itself instead.
    @Test func stalePanesAreGoneStoppedOrLeftAlone() {
        var recent = RecentPanes(limit: 5)
        for added in [pane("gone"), pane("stopped"), pane("alone", view: "view-alone"), pane("noView", view: nil), pane("kept")] {
            _ = recent.add(added)
        }
        let sessions = [session("stopped", status: .stopped), session("alone"), session("noView"), session("kept")]
        let stale = recent.removeStale(given: sessions, loneViews: ["view-alone", "view-of-nobody"])
        #expect(stale.map(\.sessionID) == ["gone", "stopped", "alone"])
        #expect(recent.panes.map(\.sessionID) == ["noView", "kept"])
    }
}
