import Foundation
import Testing
@testable import Bosun
@testable import BosunCore

private func session(_ id: String, title: String = "", group: String) -> DeckSession {
    DeckSession(id: id, title: title.isEmpty ? id : title, path: "/p", group: group, tool: "shell", status: .idle, substate: nil, tmuxSession: nil, archived: false)
}

/// The sidebar in agent-deck's own order, as the TUI shows it.
@Suite struct SessionOrderTests {
    /// `list` gives a group's sessions in creation or manual order; a title
    /// sort would undo a TUI reorder.
    @Test func sessionsKeepAgentDecksOrderWithinAGroup() {
        let listed = [
            session("1", title: "zeta", group: "work"),
            session("2", title: "alpha", group: "work"),
        ]
        #expect(DeckSession.inDeckOrder(listed, groupPaths: ["work"]).map(\.id) == ["1", "2"])
    }

    /// `list` interleaves groups; each group's rows must end up together, in
    /// `group list` order.
    @Test func groupsFollowGroupListOrder() {
        let listed = [
            session("a1", group: "alpha"),
            session("m1", group: "my-sessions"),
            session("a2", group: "alpha"),
        ]
        #expect(DeckSession.inDeckOrder(listed, groupPaths: ["my-sessions", "alpha"]).map(\.id) == ["m1", "a1", "a2"])
    }

    /// A group `group list` did not report (or no list at all) still keeps
    /// its rows together, after the reported ones.
    @Test func unlistedGroupsStayTogetherAfterListedOnes() {
        let listed = [
            session("x1", group: "x"),
            session("w1", group: "w"),
            session("x2", group: "x"),
            session("k1", group: "known"),
        ]
        #expect(DeckSession.inDeckOrder(listed, groupPaths: ["known"]).map(\.id) == ["k1", "w1", "x1", "x2"])
    }

    /// A drag's new order lands in the group's own rows; the groups around
    /// it stay put.
    @Test func reorderingTouchesOnlyTheGroupsRows() {
        let sessions = [
            session("x", group: "before"),
            session("a1", group: "g"),
            session("a2", group: "g"),
            session("y", group: "after"),
        ]
        #expect(DeckSession.reordering(sessions, within: ["a2", "a1"]).map(\.id) == ["x", "a2", "a1", "y"])
    }
}

/// A drag in the sidebar's flat rows: group headers, their sessions, and
/// the window rows under a session.
@Suite struct SidebarMoveTests {
    static let s1 = session("s1", group: "g1")
    static let s2 = session("s2", group: "g1")
    static let t1 = session("t1", group: "g2")

    let rows: [SidebarRow] = [
        .group(SessionGroup(name: "g1", sessions: [s1, s2]), expanded: true),
        .session(s1),
        .window(SessionWindow(index: 1, windowID: "@3", name: "zsh", command: "zsh"), of: s1),
        .session(s2),
        .group(SessionGroup(name: "g2", sessions: [t1]), expanded: true),
        .session(t1),
    ]

    @Test func sessionDraggedToTheTopOfItsGroupGoesBeforeTheFirst() {
        #expect(SidebarMove(rows: rows, from: [3], to: 1)
            == .session(SessionMove(sessionID: "s2", placement: .before("s1"), order: ["s2", "s1"])))
    }

    @Test func sessionDraggedPastItsNeighbourGoesAfterIt() {
        #expect(SidebarMove(rows: rows, from: [1], to: 4)
            == .session(SessionMove(sessionID: "s1", placement: .after("s2"), order: ["s2", "s1"])))
    }

    /// Under another group's header, or above every header, a session would
    /// change group; a reorder cannot do that.
    @Test(arguments: [6, 0])
    func sessionDroppedOutsideItsGroupIsNoMove(destination: Int) {
        #expect(SidebarMove(rows: rows, from: [1], to: destination) == nil)
    }

    @Test func headerDraggedToTheTopGoesBeforeTheFirstGroup() {
        #expect(SidebarMove(rows: rows, from: [4], to: 0)
            == .group(GroupMove(path: "g2", placement: .before("g1"), order: ["g2", "g1"])))
    }

    @Test func headerDraggedToTheEndGoesAfterTheLastGroup() {
        #expect(SidebarMove(rows: rows, from: [0], to: 6)
            == .group(GroupMove(path: "g1", placement: .after("g2"), order: ["g2", "g1"])))
    }

    /// A header dropped among its own sessions, or a window row, changes no
    /// order.
    @Test(arguments: [(0, 2), (2, 0)])
    func dropThatKeepsTheOrderIsNoMove(source: Int, destination: Int) {
        #expect(SidebarMove(rows: rows, from: [source], to: destination) == nil)
    }
}
