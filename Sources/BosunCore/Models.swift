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
        case .waiting: "Waiting"
        case .idle: "Idle"
        case .error: "Error"
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .queued: "Queued"
        case .unknown: "Unknown"
        }
    }

    public var needsAttention: Bool {
        self == .waiting || self == .error
    }

    /// Whether the session has a process to stop or restart; a stopped or
    /// failed one can only be started.
    public var hasProcess: Bool {
        self != .stopped && self != .error
    }
}

/// One row of `list --json`. Optionality follows the Go struct's `omitempty`:
/// `group`, `tool` and `path` are always present (possibly empty); `substate`
/// and `tmux_session` are absent when there is no refinement or no server.
public struct DeckSession: Decodable, Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let path: String
    public let group: String
    public let tool: String
    public var status: SessionStatus
    public var substate: String?
    public let tmuxSession: String?
    public let archived: Bool

    private enum CodingKeys: String, CodingKey {
        case id, title, path, group, tool, status, substate, archived
        case tmuxSession = "tmux_session"
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
/// `tmux_session`, `changed_at` and an always-empty `substate`; the list is
/// the source for all of those.
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
