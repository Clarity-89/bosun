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
