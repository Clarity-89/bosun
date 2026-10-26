import Foundation

public enum SessionStatus: String, Codable, CaseIterable, Sendable {
    case running
    case waiting
    case idle
    case error
    case stopped
    case starting
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = (try? container.decode(String.self))?.lowercased() ?? ""
        self = Self(rawValue: value) ?? .unknown
    }

    public var label: String {
        switch self {
        case .running: "Running"
        case .waiting: "Waiting"
        case .idle: "Idle"
        case .error: "Error"
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .unknown: "Unknown"
        }
    }

    public var needsAttention: Bool {
        self == .waiting || self == .error
    }
}

public struct DeckSession: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public var title: String
    public var path: String?
    public var group: String?
    public var tool: String?
    public var account: String?
    public var command: String?
    public var status: SessionStatus
    public var statusSource: String?
    public var substate: String?
    public var tmuxSession: String?
    public var profile: String?
    public var createdAt: String?
    public var lastActivityAt: String?
    public var archived: Bool

    public init(
        id: String,
        title: String,
        path: String? = nil,
        group: String? = nil,
        tool: String? = nil,
        account: String? = nil,
        command: String? = nil,
        status: SessionStatus = .unknown,
        statusSource: String? = nil,
        substate: String? = nil,
        tmuxSession: String? = nil,
        profile: String? = nil,
        createdAt: String? = nil,
        lastActivityAt: String? = nil,
        archived: Bool = false
    ) {
        self.id = id
        self.title = title
        self.path = path
        self.group = group
        self.tool = tool
        self.account = account
        self.command = command
        self.status = status
        self.statusSource = statusSource
        self.substate = substate
        self.tmuxSession = tmuxSession
        self.profile = profile
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
        self.archived = archived
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, path, group, tool, account, command, status
        case statusSource = "status_source"
        case substate
        case tmuxSession = "tmux_session"
        case profile
        case createdAt = "created_at"
        case lastActivityAt = "last_activity_at"
        case archived
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? id
        path = try container.decodeIfPresent(String.self, forKey: .path)
        group = try container.decodeIfPresent(String.self, forKey: .group)
        tool = try container.decodeIfPresent(String.self, forKey: .tool)
        account = try container.decodeIfPresent(String.self, forKey: .account)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        status = try container.decodeIfPresent(SessionStatus.self, forKey: .status) ?? .unknown
        statusSource = try container.decodeIfPresent(String.self, forKey: .statusSource)
        substate = try container.decodeIfPresent(String.self, forKey: .substate)
        tmuxSession = try container.decodeIfPresent(String.self, forKey: .tmuxSession)
        profile = try container.decodeIfPresent(String.self, forKey: .profile)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        lastActivityAt = try container.decodeIfPresent(String.self, forKey: .lastActivityAt)
        archived = try container.decodeIfPresent(Bool.self, forKey: .archived) ?? false
    }
}

public struct EventsStats: Decodable, Sendable {
    public let enabled: Bool
    public let cursor: UInt64
    public let dropped: UInt64?

    public init(enabled: Bool = false, cursor: UInt64 = 0, dropped: UInt64? = nil) {
        self.enabled = enabled
        self.cursor = cursor
        self.dropped = dropped
    }
}

public struct ConfigValue: Decodable, Sendable {
    public let key: String
    public let value: Bool
    public let type: String?

    public init(key: String, value: Bool, type: String? = nil) {
        self.key = key
        self.value = value
        self.type = type
    }
}

public struct BusData: Decodable, Sendable {
    public let from: String?
    public let to: String?
    public let tool: String?
    public let tmuxSession: String?
    public let substate: String?
    public let changedAt: String?
    public let phase: String?
    public let durationMs: Int64?

    private enum CodingKeys: String, CodingKey {
        case from, to, tool
        case tmuxSession = "tmux_session"
        case substate
        case changedAt = "changed_at"
        case phase
        case durationMs = "duration_ms"
    }
}

public struct BusFrame: Decodable, Sendable {
    public let cursor: UInt64
    public let eventID: String?
    public let timestamp: Int64?
    public let kind: String
    public let sessionID: String?
    public let data: BusData?

    private enum CodingKeys: String, CodingKey {
        case cursor
        case eventID = "event_id"
        case timestamp = "ts"
        case kind
        case sessionID = "session_id"
        case data
    }
}

public enum ProcessRunnerError: Error, LocalizedError, Sendable {
    case launchFailed(String)
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let message): "Could not launch process: \(message)"
        case .timedOut(let command): "Process timed out: \(command)"
        }
    }
}

public enum BusFollowerError: Error, LocalizedError, Sendable {
    case exited(Int32, String)
    case cursorTooOld
    case invalidFrame(String)

    public var errorDescription: String? {
        switch self {
        case .exited(let code, let stderr):
            stderr.isEmpty ? "Event follower exited with status \(code)" : stderr
        case .cursorTooOld:
            "The event cursor is older than the retained log"
        case .invalidFrame(let line):
            "Invalid event frame: \(line)"
        }
    }
}
