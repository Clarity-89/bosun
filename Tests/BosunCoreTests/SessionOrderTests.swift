import Foundation
import Testing
@testable import BosunCore

/// The sidebar in agent-deck's own order, as the TUI shows it.
@Suite struct SessionOrderTests {
    static func session(_ id: String, title: String, group: String) -> DeckSession {
        DeckSession(id: id, title: title, path: "/p", group: group, tool: "shell", status: .idle, substate: nil, tmuxSession: nil, archived: false)
    }

    /// `list` gives a group's sessions in creation or manual order; a title
    /// sort would undo a TUI reorder.
    @Test func sessionsKeepAgentDecksOrderWithinAGroup() {
        let listed = [
            Self.session("1", title: "zeta", group: "work"),
            Self.session("2", title: "alpha", group: "work"),
        ]
        let ordered = DeckSession.inDeckOrder(listed, groups: [DeckGroup(path: "work", label: "Work")])
        #expect(ordered.map(\.id) == ["1", "2"])
    }

    /// `list` interleaves groups; each group's rows must end up together, in
    /// `group list` order.
    @Test func groupsFollowGroupListOrder() {
        let listed = [
            Self.session("a1", title: "a1", group: "alpha"),
            Self.session("m1", title: "m1", group: "my-sessions"),
            Self.session("a2", title: "a2", group: "alpha"),
        ]
        let groups = [DeckGroup(path: "my-sessions", label: "My Sessions"), DeckGroup(path: "alpha", label: "alpha")]
        #expect(DeckSession.inDeckOrder(listed, groups: groups).map(\.id) == ["m1", "a1", "a2"])
    }

    /// A group `group list` did not report (or no list at all) still keeps
    /// its rows together, after the reported ones.
    @Test func unlistedGroupsStayTogetherAfterListedOnes() {
        let listed = [
            Self.session("x1", title: "x1", group: "x"),
            Self.session("w1", title: "w1", group: "w"),
            Self.session("x2", title: "x2", group: "x"),
            Self.session("k1", title: "k1", group: "known"),
        ]
        let ordered = DeckSession.inDeckOrder(listed, groups: [DeckGroup(path: "known", label: "Known")])
        #expect(ordered.map(\.id) == ["k1", "w1", "x1", "x2"])
    }
}

/// A drag in a group's sidebar rows: which session moved and the visible
/// neighbour it now sits by. nil rows are window rows, which stay under
/// their session.
@Suite struct SessionMoveTests {
    let rows: [String?] = ["s1", nil, "s2", "s3"]

    @Test func draggedToTheTopGoesBeforeTheFirst() throws {
        let move = try #require(SessionMove(rows: rows, from: [3], to: 0))
        #expect(move == SessionMove(sessionID: "s3", placement: .before("s1"), order: ["s3", "s1", "s2"]))
    }

    @Test func draggedToTheEndGoesAfterTheLast() throws {
        let move = try #require(SessionMove(rows: rows, from: [0], to: 4))
        #expect(move == SessionMove(sessionID: "s1", placement: .after("s3"), order: ["s2", "s3", "s1"]))
    }

    /// Dropping in place, or between a session and its own windows, leaves
    /// the sessions as they were: nothing to store.
    @Test(arguments: [(2, 2), (2, 3), (2, 1)])
    func dropThatKeepsTheOrderIsNoMove(source: Int, destination: Int) {
        #expect(SessionMove(rows: rows, from: [source], to: destination) == nil)
    }
}

/// `session set <id> order <n>`: agent-deck takes the session out of its
/// group's list, then inserts it at `n` (`GroupTree.SetSessionOrder`). The
/// list counts rows Bosun hides, such as `h` here.
@Suite struct OrderPositionTests {
    static func set(_ list: [String], moving id: String, to n: Int) -> [String] {
        var rest = list.filter { $0 != id }
        rest.insert(id, at: min(n, rest.count))
        return rest
    }

    static func place(_ id: String, _ placement: SessionPlacement, in list: [String]) -> [String] {
        let neighbour: String, after: Bool
        switch placement {
        case .after(let other): (neighbour, after) = (other, true)
        case .before(let other): (neighbour, after) = (other, false)
        }
        let n = AgentDeckCLI.orderPosition(
            moving: list.firstIndex(of: id)!, neighbour: list.firstIndex(of: neighbour)!, after: after
        )
        return set(list, moving: id, to: n)
    }

    @Test func movingDownLandsRightAfterTheNeighbour() {
        #expect(Self.place("a", .after("c"), in: ["a", "b", "c", "d"]) == ["b", "c", "a", "d"])
    }

    @Test func movingUpLandsRightAfterTheNeighbour() {
        #expect(Self.place("d", .after("a"), in: ["a", "b", "c", "d"]) == ["a", "d", "b", "c"])
    }

    @Test func movingToTheTopLandsBeforeTheFirst() {
        #expect(Self.place("c", .before("a"), in: ["a", "b", "c", "d"]) == ["c", "a", "b", "d"])
    }

    /// A visible index would put `c` after the hidden `h`, one row too far.
    @Test func hiddenRowsDoNotShiftTheDrop() {
        #expect(Self.place("c", .after("a"), in: ["a", "h", "b", "c"]) == ["a", "c", "h", "b"])
        #expect(Self.place("a", .after("b"), in: ["a", "h", "b", "c"]) == ["h", "b", "a", "c"])
    }
}
