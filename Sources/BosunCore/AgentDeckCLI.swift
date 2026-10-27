@preconcurrency import Foundation
import os

private let log = Logger(subsystem: "com.bosun.Bosun", category: "agent-deck")

public struct AgentDeckVersion: Comparable, CustomStringConvertible, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    /// The release `docs/macapp-core.md` was probed against; older binaries
    /// lack `events follow` or refuse the current state.db schema.
    public static let minimumSupported = AgentDeckVersion(major: 1, minor: 16, patch: 26)

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses the first `vMAJOR.MINOR.PATCH` in `--version` output such as
    /// `Agent Deck v1.16.34-14-gb3612c5ed31-dirty (update available: v1.16.34)`.
    public init?(versionOutput: String) {
        guard let match = versionOutput.firstMatch(of: /v?(\d+)\.(\d+)\.(\d+)/),
              let major = Int(match.1), let minor = Int(match.2), let patch = Int(match.3)
        else { return nil }
        self.init(major: major, minor: minor, patch: patch)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}

public struct AgentDeckBinary: Sendable {
    public let path: String
    public let version: AgentDeckVersion

    var directory: String { URL(fileURLWithPath: path).deletingLastPathComponent().path }
}

/// Command line and environment for an embedded `session attach`: a tmux
/// client, so the agent keeps running when the pane goes away.
public struct AttachLaunch: Sendable {
    public let command: String
    public let environment: [String: String]
}

extension AgentDeckBinary {
    public func attachLaunch(sessionID: String) -> AttachLaunch {
        AttachLaunch(
            command: Terminal.attachCommand(executablePath: path, sessionID: sessionID),
            environment: AgentDeckCLI.childEnvironment(binaryDirectory: directory)
        )
    }
}

public enum AgentDeckCLIError: Error, LocalizedError, Sendable {
    case notFound(rejected: [String])

    public var errorDescription: String? {
        switch self {
        case .notFound(let rejected):
            rejected.isEmpty
                ? "agent-deck was not found"
                : "no agent-deck ≥ v\(AgentDeckVersion.minimumSupported); found: \(rejected.joined(separator: ", "))"
        }
    }
}

public actor AgentDeckCLI {
    private let configuredPath: String?
    private var resolved: AgentDeckBinary?

    public init(agentDeckPath: String? = nil) {
        configuredPath = agentDeckPath
    }

    /// Picks the newest installed agent-deck. Several copies commonly coexist
    /// (a stale Homebrew install, a dev build, ~/.local/bin) and login-shell
    /// PATH order is not a safe tie-breaker: an old binary must never run
    /// against a newer state.db.
    public func binary() async throws -> AgentDeckBinary {
        if let resolved, FileManager.default.isExecutableFile(atPath: resolved.path) {
            return resolved
        }

        let environment = Self.childEnvironment(binaryDirectory: nil)
        var candidates: [String] = []
        if let configuredPath { candidates.append(configuredPath) }
        // The login shell knows the user's PATH; a LaunchServices-launched app does not.
        let lookup = try? await Subprocess.run(
            executable: "/bin/zsh",
            arguments: ["-lc", "which -a agent-deck"],
            environment: environment,
            timeout: .seconds(10)
        )
        candidates += (lookup?.stdout ?? "")
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("/") }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        candidates += [
            "\(home)/.local/bin/agent-deck",
            "\(home)/go/bin/agent-deck",
            "/opt/homebrew/bin/agent-deck",
            "/usr/local/bin/agent-deck",
        ]
        var seen = Set<String>()
        candidates = candidates.filter { seen.insert($0).inserted && FileManager.default.isExecutableFile(atPath: $0) }

        var versions: [String: AgentDeckVersion] = [:]
        await withTaskGroup(of: (String, AgentDeckVersion?).self) { group in
            for path in candidates {
                group.addTask { (path, await Self.probeVersion(at: path, environment: environment)) }
            }
            for await (path, version) in group {
                versions[path] = version
            }
        }

        let selection = Self.select(candidates: candidates, versions: versions, configuredPath: configuredPath)
        guard let chosen = selection.chosen else {
            throw AgentDeckCLIError.notFound(rejected: selection.rejected)
        }
        resolved = chosen
        return chosen
    }

    /// Picks the binary to use: a configured path when it qualifies,
    /// otherwise the newest version at or above `minimumSupported`.
    /// Candidate order decides ties, so PATH order still wins among equal
    /// versions. `rejected` names every candidate that did not qualify.
    static func select(
        candidates: [String],
        versions: [String: AgentDeckVersion],
        configuredPath: String?
    ) -> (chosen: AgentDeckBinary?, rejected: [String]) {
        var found: [AgentDeckBinary] = []
        var rejected: [String] = []
        for path in candidates {
            switch versions[path] {
            case let version? where version >= .minimumSupported:
                found.append(AgentDeckBinary(path: path, version: version))
            case let version?:
                rejected.append("\(path) (v\(version))")
            case nil:
                rejected.append("\(path) (no version)")
            }
        }
        let chosen = found.first(where: { $0.path == configuredPath })
            ?? found.max(by: { $0.version < $1.version })
        return (chosen, rejected)
    }

    private static func probeVersion(at path: String, environment: [String: String]) async -> AgentDeckVersion? {
        guard let result = try? await Subprocess.run(
            executable: path, arguments: ["--version"], environment: environment, timeout: .seconds(5)
        ), result.succeeded else { return nil }
        return AgentDeckVersion(versionOutput: result.stdout)
    }

    /// A minimal environment for agent-deck children: never the launching
    /// shell's `TMUX`/`AGENTDECK_*`, which would make `session attach` nest or
    /// misattribute the caller. The chosen binary's directory leads PATH so a
    /// re-exec by name (hooks, tmux-side helpers) lands on the same build.
    static func childEnvironment(binaryDirectory: String?) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        let directories = [binaryDirectory].compactMap { $0 }
            + (inherited["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()

        var environment: [String: String] = [
            "PATH": directories.filter { seen.insert($0).inserted }.joined(separator: ":"),
            "HOME": inherited["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path,
            "USER": inherited["USER"] ?? NSUserName(),
            "SHELL": inherited["SHELL"] ?? "/bin/zsh",
            "LANG": inherited["LANG"] ?? "en_US.UTF-8",
        ]
        environment["LOGNAME"] = inherited["LOGNAME"] ?? environment["USER"]
        for key in ["AGENTDECK_PROFILE", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "CLAUDE_CONFIG_DIR", "CODEX_HOME"] {
            if let value = inherited[key], !value.isEmpty {
                environment[key] = value
            }
        }
        return environment
    }

    public func list() async throws -> [DeckSession] {
        try await decode([DeckSession].self, ["list", "--json"])
    }

    public func eventsStats() async throws -> EventsStats {
        try await decode(EventsStats.self, ["events", "stats", "--json"])
    }

    public func statusEventsEnabled() async throws -> Bool {
        try await decode(ConfigValue.self, ["config", "get", "macapp.status_events", "--json"]).value
    }

    /// Status frames after `cursor`. Ends only by cancellation or with an
    /// error; see `isCursorTooOld` for the one the caller resyncs from.
    public func follow(after cursor: UInt64) async throws -> some AsyncSequence<BusFrame, any Error> & Sendable {
        let binary = try await binary()
        return try Subprocess.lines(
            executable: binary.path,
            arguments: ["events", "follow", "--json", "--after", String(cursor), "--kind", "session.status"],
            environment: Self.childEnvironment(binaryDirectory: binary.directory)
        ).compactMap { line in
            guard let frame = try? JSONDecoder().decode(BusFrame.self, from: Data(line.utf8)) else {
                log.warning("skipping undecodable frame: \(line, privacy: .public)")
                return nil
            }
            return frame
        }
    }

    /// `events follow` exits 1 with this on stderr when `--after` predates the
    /// retained log; the caller resyncs from `eventsStats().cursor`.
    public static func isCursorTooOld(_ error: any Error) -> Bool {
        guard case SubprocessError.exited(_, _, let stderr) = error else { return false }
        return stderr.contains("cursor older than the retained log")
    }

    public func openGhosttyAttach(sessionID: String) async throws {
        let binary = try await binary()
        try await Terminal.openAttach(executablePath: binary.path, sessionID: sessionID)
    }

    /// Runs the resolved agent-deck in its child environment; a non-zero exit
    /// is `SubprocessError.exited`.
    func run(_ arguments: [String]) async throws -> ProcessResult {
        let binary = try await binary()
        let result = try await Subprocess.run(
            executable: binary.path,
            arguments: arguments,
            environment: Self.childEnvironment(binaryDirectory: binary.directory)
        )
        try result.checkSucceeded()
        return result
    }

    private func decode<T: Decodable>(_ type: T.Type, _ arguments: [String]) async throws -> T {
        try JSONDecoder().decode(type, from: Data(try await run(arguments).stdout.utf8))
    }
}
