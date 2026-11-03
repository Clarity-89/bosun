import Foundation

/// agent-deck's `StatusString` values; anything newer decodes as `unknown`.
public enum SessionStatus: String, Decodable, Sendable {
    case running
    case waiting
    case idle
    case error
    case stopped
    case starting
    case queued
    case unknown

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value.lowercased()) ?? .unknown
    }

    public var label: String {
        switch self {
        case .running: "Running"
        // agent-deck's `waiting` is its prompt not yet acknowledged in the
        // TUI, which Bosun cannot do; Bosun keeps its own unread state.
        case .waiting: "At prompt"
        case .idle: "Idle"
        case .error: "Error"
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .queued: "Queued"
        case .unknown: "Unknown"
        }
    }
}

/// One row of `list --json`. Optionality follows the Go struct's `omitempty`:
/// `group`, `tool` and `path` are always present (possibly empty); `substate`,
/// `tmux_session`, `worktree_path` and `last_activity_at` are absent when
/// there is no refinement, no server, no worktree, or no activity yet.
public struct DeckSession: Decodable, Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let path: String
    public let group: String
    public let tool: String
    public var status: SessionStatus
    public var substate: String?
    public let tmuxSession: String?
    /// The git worktree agent-deck made for the session, whose repository
    /// may have a setup hook to run again. agent-deck 1.16.35 and later
    /// list it; nil before, and for a session in a plain directory.
    public let worktreePath: String?
    public let archived: Bool
    /// agent-deck's last confirmed activity or hook time; it moves while a
    /// session works, not only at a turn's end. `AgentDeckCLI.jsonDecoder()`
    /// reads Go's RFC3339Nano.
    public let lastActivityAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id, title, path, group, tool, status, substate, archived
        case tmuxSession = "tmux_session"
        case worktreePath = "worktree_path"
        case lastActivityAt = "last_activity_at"
    }
}

extension DeckSession {
    /// In the group at `path` or one of its subgroups; a group whose path
    /// only starts the same, `pa2` for `pa`, is another group.
    public func isIn(groupTree path: String) -> Bool {
        group == path || group.hasPrefix(path + "/")
    }

    /// Runs in `directory` or below it, by its own path or its worktree's,
    /// symlinks resolved as agent-deck stores some paths through them; a
    /// directory whose name only starts the same is another one.
    public func worksIn(_ directory: String) -> Bool {
        let root = Self.canonical(directory)
        return [path, worktreePath].compactMap { $0 }.map(Self.canonical).contains { $0 == root || $0.hasPrefix(root + "/") }
    }

    /// `path` without trailing slashes and with symlinks resolved, by
    /// `realpath`, which needs the path to exist: a missing last component
    /// is kept on its resolved parent.
    private static func canonical(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        func real(_ path: String) -> String? {
            guard let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        if let resolved = real(path) { return resolved }
        let parent = (path as NSString).deletingLastPathComponent
        guard parent != path, let resolvedParent = real(parent) else { return path }
        return (resolvedParent as NSString).appendingPathComponent((path as NSString).lastPathComponent)
    }
}

extension Date {
    /// Go's RFC3339Nano: up to nine fractional digits, where
    /// ISO8601DateFormatter reads exactly three. Nil for anything else.
    public init?(rfc3339 text: String) {
        var text = text
        if let dot = text.firstIndex(of: "."), let end = text[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let digits = text[text.index(after: dot)..<end]
            let kept = (digits + "000").prefix(3)
            text.replaceSubrange(dot..<end, with: "." + kept)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = text.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        guard let date = formatter.date(from: text) else { return nil }
        self = date
    }
}

/// `events stats --json`. `enabled` is the bus itself (`AGENTDECK_EVENTS_BUS`),
/// not the `macapp.status_events` gate.
public struct EventsStats: Decodable, Sendable {
    public let enabled: Bool
    public let cursor: UInt64
    /// Nil from agent-deck builds that predate `status_owner`, which also lack
    /// `notify-daemon install`.
    public let statusOwner: StatusOwner?

    private enum CodingKeys: String, CodingKey {
        case enabled, cursor
        case statusOwner = "status_owner"
    }
}

/// Who writes a profile's status transitions, and with them the
/// `session.status` frames Bosun follows; an owner newer than this build
/// decodes as `other`.
public enum StatusOwner: String, Decodable, Sendable {
    case tui
    case notifyDaemon = "notify-daemon"
    /// Nothing does, so rows change only when the list is reloaded.
    case nobody = "none"
    case other

    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
    }
}

/// `config get <key> --json`, for a boolean key.
public struct ConfigValue: Decodable, Sendable {
    public let value: Bool
}

/// `data` of a `session.status` frame. The wire also carries `from`, `tool`,
/// `tmux_session`, `changed_at` and an always-empty `substate`; the
/// session's row from the list is the source for all of those.
public struct StatusChange: Decodable, Sendable {
    public let to: SessionStatus
}

/// One line of `events follow --json`.
public struct BusFrame: Decodable, Sendable {
    public let cursor: UInt64
    public let kind: String
    public let sessionID: String
    public let data: StatusChange?

    private enum CodingKeys: String, CodingKey {
        case cursor, kind, data
        case sessionID = "session_id"
    }
}
