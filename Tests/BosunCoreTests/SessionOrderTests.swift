import Foundation
import Testing
@testable import BosunCore

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
