import BosunCore
import Foundation

/// How the session list orders its rows.
enum SidebarSort: String {
    /// agent-deck's: its groups, each one's sessions as `list` reports them.
    case deck
    /// Every session in one list, latest activity first, out of its group.
    /// `list` has no time a session was last attached, so activity stands
    /// for recent use.
    case activity
}

/// What the session list leaves out of agent-deck's list and how it orders
/// the rest: the TUI's search, its Open filter, and every session by last
/// activity in place of agent-deck's groups. Bosun's own, as the folded
/// groups are: the TUI keeps its filters in agent-deck's database, with no
/// CLI to read them.
struct SidebarFilter: Equatable {
    /// Matched in a session's title, path and tool, the fields the TUI's
    /// search matches.
    var query = ""
    /// The TUI's Open filter, with its default `active_filter_excludes`:
    /// error and stopped sessions hidden.
    var openOnly = false
    var sort = SidebarSort.deck

    /// The query as it is matched; the TUI trims its own too.
    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var hasQuery: Bool { !trimmedQuery.isEmpty }

    /// Whether the groups fold. A search holds every group open, as the
    /// TUI's search lists every match, and the activity list has no groups,
    /// so a fold made meanwhile would show only once either ends.
    var allowsFolding: Bool { !hasQuery && sort == .deck }

    /// Whether the rows reorder. Sorted by activity, a row's neighbours are
    /// not agent-deck's, so a place beside them means nothing there.
    var allowsReordering: Bool { sort == .deck }

    /// The list's rows from agent-deck's `groups`: each group with a session
    /// left in it, then, unless `collapsed` has it, its sessions, each with
    /// its extra windows under it. A search holds every group open. Sorted
    /// by activity, the sessions leave their groups for one list, latest
    /// first; ties, and sessions without activity, keep agent-deck's order.
    /// The session at `selected` stays while the Open filter would hide it,
    /// so what the pane shows keeps its row.
    func rows(
        groups: [SessionGroup], collapsed: Set<String>, selected: String?,
        extraWindows: (String) -> ArraySlice<SessionWindow>
    ) -> [SidebarRow] {
        let query = trimmedQuery
        func keeps(_ session: DeckSession) -> Bool {
            (!openOnly || session.isOpen || session.id == selected) && (query.isEmpty || session.matches(query))
        }
        func withWindows(_ session: DeckSession) -> [SidebarRow] {
            [.session(session)] + extraWindows(session.id).map { .window($0, of: session) }
        }
        switch sort {
        case .activity:
            return groups.flatMap(\.sessions).filter(keeps)
                .sorted { ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast) }
                .flatMap(withWindows)
        case .deck:
            return groups.flatMap { group -> [SidebarRow] in
                let kept = group.sessions.filter(keeps)
                guard !kept.isEmpty else { return [] }
                let expanded = !query.isEmpty || !collapsed.contains(group.name)
                return [.group(SessionGroup(name: group.name, sessions: kept), expanded: expanded)] + (expanded ? kept.flatMap(withWindows) : [])
            }
        }
    }
}

extension DeckSession {
    /// Not hidden by the TUI's Open filter, whose default
    /// `active_filter_excludes` is error and stopped.
    var isOpen: Bool { status != .error && status != .stopped }

    /// The TUI's search fields, matched as Finder matches names: case and
    /// diacritics aside.
    func matches(_ query: String) -> Bool {
        title.localizedStandardContains(query) || path.localizedStandardContains(query) || tool.localizedStandardContains(query)
    }
}
