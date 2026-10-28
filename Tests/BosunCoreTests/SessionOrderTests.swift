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

/// A drag in the sidebar's flat rows: group headers, their sessions, and
/// the window rows under a session.
@Suite struct SidebarMoveTests {
    let rows: [SidebarRowKind] = [
        .group(path: "g1"),
        .session(id: "s1", group: "g1"),
        .window,
        .session(id: "s2", group: "g1"),
        .group(path: "g2"),
        .session(id: "t1", group: "g2"),
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

/// `group reorder <path> --position <n>` leaves the group at index `n` among
/// its siblings (`handleGroupReorder`). `group list` order here; `empty` has
/// no sessions, so the sidebar never shows it.
@Suite struct GroupPositionTests {
    static let groups = ["my", "empty", "backend", "backend/api", "front"]

    static func topLevel(moving path: String, _ placement: RowPlacement) -> [String]? {
        guard let n = AgentDeckCLI.groupPosition(moving: path, placement, in: groups) else { return nil }
        var rest = ["my", "empty", "backend", "front"].filter { $0 != path }
        rest.insert(path, at: min(n, rest.count))
        return rest
    }

    @Test func hiddenGroupsDoNotShiftTheDrop() {
        #expect(Self.topLevel(moving: "front", .after("my")) == ["my", "front", "empty", "backend"])
        #expect(Self.topLevel(moving: "front", .before("backend")) == ["my", "empty", "front", "backend"])
    }

    /// The sidebar shows `backend/api` as its own section under `backend`.
    @Test func neighbourInASubgroupStandsForItsTopLevelGroup() {
        #expect(Self.topLevel(moving: "my", .after("backend/api")) == ["empty", "backend", "my", "front"])
    }

    @Test func besideItsOwnSubgroupAGroupStaysPut() {
        #expect(Self.topLevel(moving: "backend", .after("backend/api")) == ["my", "empty", "backend", "front"])
    }

    @Test func subgroupCannotMoveToAnotherLevel() {
        #expect(AgentDeckCLI.groupPosition(moving: "backend/api", .after("front"), in: Self.groups) == nil)
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

    static func place(_ id: String, _ placement: RowPlacement, in list: [String]) -> [String] {
        let (neighbour, after) = placement.neighbour
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
