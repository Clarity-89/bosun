import BosunCore
import Foundation

extension DeckSession {
    /// agent-deck's order, as the TUI shows it with its default `group_sort`:
    /// groups as `group list` reports them, a group's sessions as `list`
    /// reports them (creation order, or the TUI's manual one). A group
    /// `groupPaths` lacks follows the reported ones, by path. Each group's
    /// sessions end up together. Pins are not applied: `list` does not
    /// report them.
    static func inDeckOrder(_ sessions: [DeckSession], groupPaths: [String]) -> [DeckSession] {
        let rank = Dictionary(groupPaths.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return sessions.enumerated()
            .sorted { a, b in
                let rankA = rank[a.element.group] ?? groupPaths.count
                let rankB = rank[b.element.group] ?? groupPaths.count
                if rankA != rankB { return rankA < rankB }
                if a.element.group != b.element.group { return a.element.group < b.element.group }
                return a.offset < b.offset
            }
            .map(\.element)
    }

    /// `sessions` with the rows `order` names, which share a group and so
    /// are consecutive, in that order and where they were.
    static func reordering(_ sessions: [DeckSession], within order: [String]) -> [DeckSession] {
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        let indices = sessions.indices.filter { rank[sessions[$0].id] != nil }
        let reordered = indices.map { sessions[$0] }.sorted { rank[$0.id, default: 0] < rank[$1.id, default: 0] }
        var result = sessions
        for (index, session) in zip(indices, reordered) {
            result[index] = session
        }
        return result
    }
}

/// A sidebar row: a group header, a session, or one of its extra windows.
enum SidebarRow: Identifiable {
    case group(SessionGroup, expanded: Bool)
    case session(DeckSession)
    case window(SessionWindow, of: DeckSession)

    var id: String {
        switch self {
        case .group(let group, _): "group:\(group.name)"
        case .session(let session): session.id
        case .window(let window, let session): "\(session.id)/\(window.windowID)"
        }
    }

    /// The group header's agent-deck path; nil for the other rows.
    var groupPath: String? {
        if case .group(let group, _) = self { group.path } else { nil }
    }

    /// What selecting the row selects.
    var item: SidebarItem {
        switch self {
        case .group(let group, _): .group(group.name)
        case .session(let session): .pane(PaneTarget(sessionID: session.id))
        case .window(let window, let session): .pane(PaneTarget(sessionID: session.id, windowID: window.windowID))
        }
    }

    /// The row `offset` rows from `selection`, held at either end, as the
    /// TUI's j and k move. A session or window a folded group hides counts
    /// as its group's header; with no selection, j starts at the top and k
    /// at the bottom.
    static func step(by offset: Int, from selection: SidebarItem?, in rows: [SidebarRow]) -> SidebarRow? {
        guard !rows.isEmpty else { return nil }
        let index = rows.firstIndex { $0.item == selection } ?? rows.firstIndex { row in
            guard case .group(let group, _) = row, case .pane(let target)? = selection else { return false }
            return group.sessions.contains { $0.id == target.sessionID }
        }
        guard let index else { return offset > 0 ? rows.first : rows.last }
        return rows[min(max(index + offset, 0), rows.count - 1)]
    }
}

/// A session moved within its group.
struct SessionMove: Equatable {
    let sessionID: String
    let placement: RowPlacement
    /// The group's visible sessions in their new order.
    let order: [String]
}

/// A group moved, its sessions with it.
struct GroupMove: Equatable {
    let path: String
    let placement: RowPlacement
    /// The sidebar's groups in their new order.
    let order: [String]
}

/// A drag in the sidebar: a group header, which takes its sessions along,
/// or a session within its own group.
enum SidebarMove: Equatable {
    case group(GroupMove)
    case session(SessionMove)

    /// `source` and `destination` are a list move's offsets into `rows`.
    /// Nil when the order stays as it was, for a window row, and for a
    /// session dropped under another group's header: that would change its
    /// group, which a reorder does not.
    init?(rows: [SidebarRow], from source: IndexSet, to destination: Int) {
        guard source.count == 1, let from = source.first else { return nil }
        var moved = rows
        let row = moved.remove(at: from)
        let to = destination > from ? destination - 1 : destination
        moved.insert(row, at: to)
        switch row {
        case .group(let group, _):
            let order = moved.compactMap(\.groupPath)
            guard !group.path.isEmpty, order != rows.compactMap(\.groupPath),
                  let placement = Self.placement(of: group.path, in: order) else { return nil }
            self = .group(GroupMove(path: group.path, placement: placement, order: order))
        case .session(let session):
            func sessions(_ rows: [SidebarRow]) -> [String] {
                rows.compactMap { if case .session(let row) = $0, row.group == session.group { row.id } else { nil } }
            }
            let order = sessions(moved)
            guard moved[..<to].last(where: { $0.groupPath != nil })?.groupPath == session.group,
                  order != sessions(rows),
                  let placement = Self.placement(of: session.id, in: order) else { return nil }
            self = .session(SessionMove(sessionID: session.id, placement: placement, order: order))
        case .window:
            return nil
        }
    }

    /// The TUI's K and J: the row at `index` one place up or down among its
    /// peers, a session within its group, a group among the groups. Nil at
    /// either end and for a window row.
    init?(rows: [SidebarRow], moving index: Int, up: Bool) {
        let isPeer: (SidebarRow) -> Bool
        switch rows[index] {
        case .group: isPeer = { $0.groupPath != nil }
        case .session(let session): isPeer = { if case .session(let other) = $0 { other.group == session.group } else { false } }
        case .window: return nil
        }
        let peers = rows.indices.filter { isPeer(rows[$0]) }
        // A list move inserts before `destination`: above the peer going up,
        // below it going down.
        if up, let peer = peers.last(where: { $0 < index }) {
            self.init(rows: rows, from: [index], to: peer)
        } else if !up, let peer = peers.first(where: { $0 > index }) {
            self.init(rows: rows, from: [index], to: peer + 1)
        } else {
            return nil
        }
    }

    private static func placement(of id: String, in order: [String]) -> RowPlacement? {
        guard let index = order.firstIndex(of: id), order.count > 1 else { return nil }
        return index > 0 ? .after(order[index - 1]) : .before(order[index + 1])
    }
}
