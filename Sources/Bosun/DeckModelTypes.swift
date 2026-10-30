import BosunCore
import Foundation

/// The values DeckModel publishes: what the sidebar selects and shows, what
/// runs on a session, how agent-deck is connected, and where the New Session
/// dialog starts.

/// A lifecycle action in flight on a session.
enum LifecycleAction: String {
    case stop, restart, rename, delete

    /// What the session's row says meanwhile. agent-deck reports no progress,
    /// only the end.
    var progressLabel: String {
        switch self {
        case .stop: "Stopping…"
        case .restart: "Restarting…"
        case .rename: "Renaming…"
        case .delete: "Deleting…"
        }
    }
}

/// A request typed into a session's agent as a skill's slash command, for
/// the work a session ends with: the branch caught up with main, and the
/// pull request. In the order the toolbar shows them.
enum AgentRequest: CaseIterable {
    case mergeMain, submitPullRequest

    var command: String {
        switch self {
        case .mergeMain: "/merge-main"
        case .submitPullRequest: "/submit-pr"
        }
    }

    /// The toolbar's word for it.
    var title: String {
        switch self {
        case .mergeMain: "Update Branch"
        case .submitPullRequest: "Open PR"
        }
    }

    /// The Session menu's, with room to say what is merged.
    var menuTitle: String {
        switch self {
        case .mergeMain: "Update Branch from Main"
        case .submitPullRequest: "Open Pull Request"
        }
    }

    /// What the agent is asked to do, for a tooltip, with the command typed.
    var help: String {
        switch self {
        case .mergeMain: "Ask the agent to merge the latest main into this branch and push (\(command))"
        case .submitPullRequest: "Ask the agent to open a pull request for this session (\(command))"
        }
    }
}

struct SessionGroup: Identifiable {
    let name: String
    var sessions: [DeckSession]
    var id: String { name }
    /// The agent-deck path its sessions share; empty for "Ungrouped".
    var path: String { sessions.first?.group ?? "" }
    /// Not agent-deck's default group, which it refuses to delete, nor the
    /// row of sessions without a group.
    var isDeletable: Bool { !path.isEmpty && path != DeckGroup.defaultPath }
}

/// What the pane shows: a session, optionally one of its extra tmux windows.
struct PaneTarget: Hashable {
    let sessionID: String
    let windowID: String?

    init(sessionID: String, windowID: String? = nil) {
        self.sessionID = sessionID
        self.windowID = windowID
    }
}

/// A sidebar row: a group header or a pane target.
enum SidebarItem: Hashable {
    case group(String)
    case pane(PaneTarget)
}

/// The sidebar's two lists.
enum SidebarTab: String {
    case sessions, inbox
}

/// The New Session dialog's starting values.
struct NewSessionPrompt: Identifiable {
    let id = UUID()
    /// A group's path; empty when nothing selected names a group.
    let groupPath: String
    let directory: String
    let command: String
}

extension DeckSession {
    var groupName: String {
        let name = group.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Ungrouped" : name
    }
}

extension SessionWindow {
    /// tmux names a window after its command, but a rename can clear it.
    var title: String {
        name.isEmpty ? "window \(index)" : name
    }
}

enum ConnectionState: Equatable, Sendable {
    case starting
    case live
    case reconnecting
    case unavailable

    var label: String {
        switch self {
        case .starting: "Starting"
        case .live: "Live"
        case .reconnecting: "Reconnecting"
        case .unavailable: "Unavailable"
        }
    }
}

/// Why no `session.status` frame can arrive.
enum StatusFeedGap {
    /// The `macapp.status_events` gate is off.
    case eventsOff
    /// No TUI and no notify daemon writes transitions.
    case noPublisher
}
