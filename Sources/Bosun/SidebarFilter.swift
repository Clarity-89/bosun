import BosunCore
import Foundation

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
    /// Every session in one list, latest activity first, out of its group.
    /// `list` has no time a session was last attached, so activity stands
    /// for recent use.
    var byRecent = false

    /// The query as it is matched; the TUI trims its own too.
    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var hasQuery: Bool { !trimmedQuery.isEmpty }

    func keeps(_ session: DeckSession) -> Bool {
        (!openOnly || session.isOpen) && (!hasQuery || session.matches(trimmedQuery))
    }

    /// `groups` with the sessions the filters keep; a group left with none
    /// drops out, as the TUI's Open filter drops it.
    func apply(to groups: [SessionGroup]) -> [SessionGroup] {
        guard hasQuery || openOnly else { return groups }
        return groups.compactMap { group in
            let kept = group.sessions.filter(keeps)
            return kept.isEmpty ? nil : SessionGroup(name: group.name, sessions: kept)
        }
    }

    /// The sessions the filters keep, latest activity first, whatever their
    /// group. Stable, so sessions without activity, and ties, keep
    /// agent-deck's order.
    func recent(_ sessions: [DeckSession]) -> [DeckSession] {
        sessions.filter(keeps).sorted { ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast) }
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
