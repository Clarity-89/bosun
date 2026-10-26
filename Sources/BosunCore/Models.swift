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
}

/// One row of `list --json`. Optionality follows the Go struct's `omitempty`:
/// `group` and `tool` are always present (possibly empty), `substate` is
/// absent when there is no refinement.
public struct DeckSession: Decodable, Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let group: String
    public let tool: String
    public var status: SessionStatus
    public var substate: String?
    public let archived: Bool
}

/// `events stats --json`. `enabled` is the bus itself (`AGENTDECK_EVENTS_BUS`),
/// not the `macapp.status_events` gate.
public struct EventsStats: Decodable, Sendable {
    public let enabled: Bool
    public let cursor: UInt64
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
