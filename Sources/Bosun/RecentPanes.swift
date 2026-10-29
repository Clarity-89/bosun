import BosunCore
import Foundation

/// A session's terminal: a tmux client on Bosun's view of the session, or,
/// for a session tmux's default server does not have, through `agent-deck
/// session attach`.
struct AttachedPane: Identifiable {
    let id: UUID
    let sessionID: String
    /// Bosun's own session in the group; nil when attached through agent-deck.
    let view: String?
    let launch: AttachLaunch
    /// Whether the tmux client leaves its window's size to the other clients:
    /// hidden, or shown while someone else is on the window, until you type
    /// or click in it. tmux gives a window one size, and agent-deck's
    /// `window-size latest` gives it to the client used last, so a pane that
    /// sized its window would shrink the TUI's.
    var yieldsSize: Bool
    /// What the terminal reports as its title.
    var title = ""
}

/// The panes kept attached, the most recently shown last. A hidden one
/// keeps its tmux client, so showing it again starts nothing; past `limit`
/// the least recent goes.
struct RecentPanes {
    let limit: Int
    private(set) var panes: [AttachedPane] = []

    init(limit: Int) {
        self.limit = limit
    }

    func pane(for sessionID: String) -> AttachedPane? {
        panes.first { $0.sessionID == sessionID }
    }

    func pane(id: UUID) -> AttachedPane? {
        panes.first { $0.id == id }
    }

    /// The session's pane, made the most recent; nil without one.
    mutating func touch(_ sessionID: String) -> AttachedPane? {
        guard let index = panes.firstIndex(where: { $0.sessionID == sessionID }) else { return nil }
        let pane = panes.remove(at: index)
        panes.append(pane)
        return pane
    }

    /// Adds `pane` as the most recent, in place of any its session had, and
    /// returns the panes that leave, which the caller ends.
    mutating func add(_ pane: AttachedPane) -> [AttachedPane] {
        var leaving = panes.filter { $0.sessionID == pane.sessionID }
        panes.removeAll { $0.sessionID == pane.sessionID }
        panes.append(pane)
        let overflow = max(0, panes.count - limit)
        leaving += panes.prefix(overflow)
        panes.removeFirst(overflow)
        return leaving
    }

    mutating func remove(_ id: UUID) -> AttachedPane? {
        guard let index = panes.firstIndex(where: { $0.id == id }) else { return nil }
        return panes.remove(at: index)
    }

    mutating func update(_ id: UUID, _ change: (inout AttachedPane) -> Void) {
        guard let index = panes.firstIndex(where: { $0.id == id }) else { return }
        change(&panes[index])
    }

    /// Removes and returns the panes `sessions` no longer backs: a session
    /// gone or stopped, or a view in `loneViews`, left alone in its tmux
    /// group when agent-deck killed the session, perhaps to recreate it
    /// under the same name; the view alone keeps the dead windows alive.
    mutating func removeStale(given sessions: [DeckSession], loneViews: Set<String>) -> [AttachedPane] {
        let stale = panes.filter { pane in
            guard let session = sessions.first(where: { $0.id == pane.sessionID }) else { return true }
            return session.status == .stopped || pane.view.map(loneViews.contains) ?? false
        }
        panes.removeAll { pane in stale.contains { $0.id == pane.id } }
        return stale
    }
}
