import Foundation

extension DeckSession {
    /// agent-deck's order, as the TUI shows it with its default `group_sort`:
    /// groups as `group list` reports them, a group's sessions as `list`
    /// reports them (creation order, or the TUI's manual one). A group
    /// `groups` lacks follows the reported ones, by path. Each group's
    /// sessions end up together. Pins are not applied: `list` does not
    /// report them.
    public static func inDeckOrder(_ sessions: [DeckSession], groups: [DeckGroup]) -> [DeckSession] {
        let rank = Dictionary(groups.enumerated().map { ($1.path, $0) }, uniquingKeysWith: { first, _ in first })
        return sessions.enumerated()
            .sorted { a, b in
                let rankA = rank[a.element.group] ?? groups.count
                let rankB = rank[b.element.group] ?? groups.count
                if rankA != rankB { return rankA < rankB }
                if a.element.group != b.element.group { return a.element.group < b.element.group }
                return a.offset < b.offset
            }
            .map(\.element)
    }
}

/// Where a moved session goes in its group: right after a visible neighbour,
/// or right before one when it is now first.
public enum SessionPlacement: Equatable, Sendable {
    case after(String)
    case before(String)
}

/// A drag within a group's sidebar rows.
public struct SessionMove: Equatable, Sendable {
    public let sessionID: String
    public let placement: SessionPlacement
    /// The group's visible sessions in their new order.
    public let order: [String]
}

extension SessionMove {
    /// `rows` are a group's sidebar rows in order, nil for a window row,
    /// which stays under its session; `source` and `destination` are a list
    /// move's offsets into them. Nil when the sessions keep their order.
    public init?(rows: [String?], from source: IndexSet, to destination: Int) {
        let dragged = source.compactMap { rows[$0] }
        guard dragged.count == 1, let sessionID = dragged.first else { return nil }
        var moved = rows.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        moved.insert(contentsOf: source.map { rows[$0] }, at: destination - source.count(in: 0..<destination))
        let order = moved.compactMap { $0 }
        guard order != rows.compactMap({ $0 }), let index = order.firstIndex(of: sessionID) else { return nil }
        self.init(
            sessionID: sessionID,
            placement: index > 0 ? .after(order[index - 1]) : .before(order[index + 1]),
            order: order
        )
    }
}

extension AgentDeckCLI {
    /// Moves the session within its group next to a neighbour. agent-deck's
    /// positions count rows Bosun hides (archived sessions, sub-sessions),
    /// so both positions come from agent-deck rather than the sidebar.
    public func moveSession(id: String, _ placement: SessionPlacement) async throws {
        let neighbourID: String
        let after: Bool
        switch placement {
        case .after(let other): (neighbourID, after) = (other, true)
        case .before(let other): (neighbourID, after) = (other, false)
        }
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

    private func position(ofSession id: String) async throws -> Int {
        try JSONDecoder().decode(Position.self, from: Data(try await run(["session", "show", id, "--json"]).stdout.utf8)).order
    }
}

private struct Position: Decodable {
    let order: Int
}
