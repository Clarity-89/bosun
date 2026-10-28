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

/// A session moved within its group.
public struct SessionMove: Equatable, Sendable {
    public let sessionID: String
    public let placement: RowPlacement
    /// The group's visible sessions in their new order.
    public let order: [String]
}

/// A group moved, its sessions with it.
public struct GroupMove: Equatable, Sendable {
    public let path: String
    public let placement: RowPlacement
    /// The sidebar's groups in their new order.
    public let order: [String]
}

/// A sidebar row as a drag sees it.
public enum SidebarRowKind: Equatable, Sendable {
    case group(path: String)
    case session(id: String, group: String)
    /// Stays under its session.
    case window

    var groupPath: String? {
        if case .group(let path) = self { path } else { nil }
    }
}

/// A drag in the sidebar: a group header, which takes its sessions along,
/// or a session within its own group.
public enum SidebarMove: Equatable, Sendable {
    case group(GroupMove)
    case session(SessionMove)

    /// `source` and `destination` are a list move's offsets into `rows`.
    /// Nil when the order stays as it was, for a window row, and for a
    /// session dropped under another group's header: that would change its
    /// group, which a reorder does not.
    public init?(rows: [SidebarRowKind], from source: IndexSet, to destination: Int) {
        guard source.count == 1, let from = source.first else { return nil }
        var moved = rows
        let row = moved.remove(at: from)
        let to = destination > from ? destination - 1 : destination
        moved.insert(row, at: to)
        switch row {
        case .group(let path):
            let order = moved.compactMap(\.groupPath)
            guard !path.isEmpty, order != rows.compactMap(\.groupPath),
                  let placement = Self.placement(of: path, in: order) else { return nil }
            self = .group(GroupMove(path: path, placement: placement, order: order))
        case .session(let id, let group):
            func sessions(_ rows: [SidebarRowKind]) -> [String] {
                rows.compactMap { if case .session(let id, let owner) = $0, owner == group { id } else { nil } }
            }
            let order = sessions(moved)
            guard moved[..<to].last(where: { $0.groupPath != nil })?.groupPath == group,
                  order != sessions(rows),
                  let placement = Self.placement(of: id, in: order) else { return nil }
            self = .session(SessionMove(sessionID: id, placement: placement, order: order))
        case .window:
            return nil
        }
    }

    private static func placement(of id: String, in order: [String]) -> RowPlacement? {
        guard let index = order.firstIndex(of: id), order.count > 1 else { return nil }
        return index > 0 ? .after(order[index - 1]) : .before(order[index + 1])
    }
}

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
        try JSONDecoder().decode(Position.self, from: Data(try await run(["session", "show", id, "--json"]).stdout.utf8)).order
    }
}

private struct Position: Decodable {
    let order: Int
}
