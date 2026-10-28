import BosunCore
import Foundation

/// A session's terminal: a tmux client on Bosun's view of the session, or,
/// for a session tmux's default server does not have, through `agent-deck
/// session attach`.
struct AttachedPane: Identifiable {
    let id = UUID()
    let sessionID: String
    /// agent-deck's tmux session at the attach. One under another name is a
    /// recreated session, whose windows the view does not share.
    let tmuxSession: String?
    /// Bosun's own session in the group; nil when attached through agent-deck.
    let view: String?
    let launch: AttachLaunch
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

    mutating func setTitle(_ title: String, of id: UUID) {
        guard let index = panes.firstIndex(where: { $0.id == id }) else { return }
        panes[index].title = title
    }

    /// Removes and returns the panes `sessions` no longer backs: a session
    /// gone or stopped, or a view whose agent-deck session tmux now has
    /// under another name.
    mutating func removeStale(given sessions: [DeckSession]) -> [AttachedPane] {
        let stale = panes.filter { pane in
            guard let session = sessions.first(where: { $0.id == pane.sessionID }) else { return true }
            return session.status == .stopped || (pane.view != nil && session.tmuxSession != pane.tmuxSession)
        }
        panes.removeAll { pane in stale.contains { $0.id == pane.id } }
        return stale
    }
}
