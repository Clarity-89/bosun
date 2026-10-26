@preconcurrency import Foundation

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
}

public actor AgentDeckCLI {
    private let configuredPath: String?
    private var resolved: AgentDeckBinary?

    public init(agentDeckPath: String? = nil) {
        self.configuredPath = agentDeckPath ?? UserDefaults.standard.string(forKey: "agentDeckPath")
    }

    public func executablePath() async throws -> String {
        try await binary().path
    }

    /// Picks the newest installed agent-deck. Several copies commonly coexist
    /// (a stale Homebrew install, a dev build, ~/.local/bin) and login-shell
    /// PATH order is not a safe tie-breaker: an old binary must never run
    /// against a newer state.db.
    public func binary() async throws -> AgentDeckBinary {
        if let resolved, FileManager.default.isExecutableFile(atPath: resolved.path) {
            return resolved
        }

        var candidates: [String] = []
        if let configuredPath { candidates.append(configuredPath) }
        let lookup = try? await ProcessRunner.run(
            executable: "/bin/zsh",
            arguments: ["-lc", "which -a agent-deck"],
            environment: executionEnvironment(),
            timeout: 10
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
        var found: [AgentDeckBinary] = []
        var rejected: [String] = []
        for path in candidates where seen.insert(path).inserted {
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            guard let output = try? await ProcessRunner.run(
                executable: path, arguments: ["--version"],
                environment: executionEnvironment(), timeout: 5
            ), output.succeeded, let version = AgentDeckVersion(versionOutput: output.stdout) else {
                rejected.append("\(path) (no version)")
                continue
            }
            if version < .minimumSupported {
                rejected.append("\(path) (v\(version))")
                continue
            }
            found.append(AgentDeckBinary(path: path, version: version))
        }

        // A configured path wins when it qualifies; otherwise the newest.
        let chosen = found.first(where: { $0.path == configuredPath })
            ?? found.max(by: { $0.version < $1.version })
        guard let chosen else {
            let detail = rejected.isEmpty
                ? "agent-deck was not found"
                : "no agent-deck ≥ v\(AgentDeckVersion.minimumSupported); found: \(rejected.joined(separator: ", "))"
            throw ProcessRunnerError.launchFailed(detail)
        }
        resolved = chosen
        return chosen
    }

    /// A minimal environment for agent-deck children: never the launching
    /// shell's `TMUX`/`AGENTDECK_*`, which would make `session attach` nest or
    /// misattribute the caller. The chosen binary's directory leads PATH so a
    /// re-exec by name (hooks, tmux-side helpers) lands on the same build.
    public func executionEnvironment() -> [String: String] {
        var environment: [String: String] = [:]
        let inherited = ProcessInfo.processInfo.environment
        let home = inherited["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        let inheritedPath = inherited["PATH"] ?? ""
        let standardPath = [
            resolved.map { ($0.path as NSString).deletingLastPathComponent } ?? "",
            inheritedPath,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        environment["PATH"] = standardPath
            .joined(separator: ":")
            .split(separator: ":")
            .map(String.init)
            .reduce(into: [String]()) { paths, path in
                if !paths.contains(path) { paths.append(path) }
            }
            .joined(separator: ":")
        environment["HOME"] = home
        environment["USER"] = inherited["USER"] ?? NSUserName()
        environment["LOGNAME"] = inherited["LOGNAME"] ?? environment["USER"]
        environment["SHELL"] = inherited["SHELL"] ?? "/bin/zsh"
        environment["LANG"] = inherited["LANG"] ?? "en_US.UTF-8"

        for key in [
            "AGENTDECK_PROFILE",
            "XDG_CONFIG_HOME",
            "XDG_DATA_HOME",
            "XDG_CACHE_HOME",
            "CLAUDE_CONFIG_DIR",
            "CODEX_HOME",
        ] {
            if let value = inherited[key], !value.isEmpty {
                environment[key] = value
            }
        }
        return environment
    }

    public func list() async throws -> [DeckSession] {
        let result = try await run(["list", "--json"])
        try check(result)
        return try JSONDecoder().decode([DeckSession].self, from: Data(result.stdout.utf8))
    }

    public func eventsStats() async throws -> EventsStats {
        let result = try await run(["events", "stats", "--json"])
        try check(result)
        return try JSONDecoder().decode(EventsStats.self, from: Data(result.stdout.utf8))
    }

    public func statusEventsEnabled() async throws -> Bool {
        let result = try await run(["config", "get", "macapp.status_events", "--json"])
        try check(result)
        return try JSONDecoder().decode(ConfigValue.self, from: Data(result.stdout.utf8)).value
    }

    public func follow(
        after cursor: UInt64,
        onStart: (@Sendable (pid_t) -> Void)? = nil
    ) async throws -> AsyncThrowingStream<BusFrame, Error> {
        let path = try await executablePath()
        return BusFollower.stream(
            executable: path,
            environment: executionEnvironment(),
            after: cursor,
            onStart: onStart
        )
    }

    public func openGhosttyAttach(sessionID: String) async throws {
        let path = try await executablePath()
        let result = try await Terminal.openAttach(
            executablePath: path,
            sessionID: sessionID,
            environment: executionEnvironment()
        )
        try check(result)
    }

    public func attachArguments(sessionID: String) async throws -> [String] {
        let path = try await executablePath()
        return Terminal.attachArguments(executablePath: path, sessionID: sessionID)
    }

    private func run(_ arguments: [String]) async throws -> ProcessResult {
        let path = try await executablePath()
        return try await ProcessRunner.run(
            executable: path,
            arguments: arguments,
            environment: executionEnvironment()
        )
    }

    private func check(_ result: ProcessResult) throws {
        guard result.succeeded else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProcessRunnerError.launchFailed(
                detail.isEmpty ? "agent-deck exited with status \(result.status)" : detail
            )
        }
    }
}
