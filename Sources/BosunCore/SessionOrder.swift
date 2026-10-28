import Foundation

/// Where a moved row goes: right after a visible neighbour, or right before
/// one when it is now first.
public enum RowPlacement: Equatable, Sendable {
    case after(String)
    case before(String)

    var neighbour: (id: String, after: Bool) {
        switch self {
        case .after(let id): (id, true)
        case .before(let id): (id, false)
        }
    }
}

/// `session set <id> order <n>` and `group reorder`. A refusal arrives as
/// `AgentDeckCLIError.reported` with agent-deck's own message.
extension AgentDeckCLI {
    /// Moves the session within its group next to a neighbour. agent-deck's
    /// positions count rows Bosun hides (archived sessions, sub-sessions),
    /// so both positions come from agent-deck rather than the sidebar.
    public func moveSession(id: String, _ placement: RowPlacement) async throws {
        let (neighbourID, after) = placement.neighbour
        async let moving = position(ofSession: id)
        async let neighbour = position(ofSession: neighbourID)
        let order = Self.orderPosition(moving: try await moving, neighbour: try await neighbour, after: after)
        _ = try await run(["session", "set", id, "order", String(order), "--json"])
    }

    /// `session set <id> order <n>` takes the session out of its group's
    /// list, then inserts it at `n`; past the neighbour, that list is one
    /// shorter.
    static func orderPosition(moving: Int, neighbour: Int, after: Bool) -> Int {
        let shifted = moving < neighbour ? neighbour - 1 : neighbour
        return after ? shifted + 1 : shifted
    }

    /// Moves the group, with its sessions and subgroups, next to a neighbour
    /// among its siblings. Positions come from `group list`, which also has
    /// the empty groups the sidebar leaves out.
    public func moveGroup(path: String, _ placement: RowPlacement) async throws {
        guard let position = Self.groupPosition(moving: path, placement, in: try await groups().map(\.path)) else {
            throw AgentDeckCLIError.reported("“\(path)” can only move among the groups at its own level")
        }
        _ = try await run(["group", "reorder", path, "--position", String(position), "--json"])
    }

    /// The position `group reorder --position` takes: the group's index
    /// among its siblings once moved. A neighbour inside a sibling's
    /// subgroups stands for that sibling; one at another level gives nil.
    static func groupPosition(moving path: String, _ placement: RowPlacement, in groups: [String]) -> Int? {
        func parent(_ path: String) -> String {
            path.lastIndex(of: "/").map { String(path[..<$0]) } ?? ""
        }
        let level = parent(path)
        var neighbour = placement.neighbour.id
        while parent(neighbour) != level {
            guard neighbour.contains("/") else { return nil }
            neighbour = parent(neighbour)
        }
        let siblings = groups.filter { parent($0) == level }
        // Dropped beside its own subgroups: it stays where it is.
        if neighbour == path {
            return siblings.firstIndex(of: path)
        }
        guard let index = siblings.filter({ $0 != path }).firstIndex(of: neighbour) else { return nil }
        return placement.neighbour.after ? index + 1 : index
    }

    private func position(ofSession id: String) async throws -> Int {
        try await decode(Position.self, ["session", "show", id, "--json"]).order
    }
}

private struct Position: Decodable {
    let order: Int
}
