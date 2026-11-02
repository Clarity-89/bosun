import Foundation
import os

private let logger = Logger(subsystem: "com.bosun.Bosun", category: "LaunchEnvironment")

/// What Bosun's process environment may hold. Every terminal Bosun opens
/// starts from it: libghostty copies the process environment and adds to it,
/// so a key here reaches each shell of the user's. `open` hands an app the
/// environment of the shell that ran it, and a Bosun started from tmux, or
/// from an agent's pane, would otherwise pass that shell's `TMUX`, `CI`,
/// `NO_COLOR` and `AGENTDECK_KILL_SCOPE` to those shells: nx stops
/// streaming under `CI`, and agent-deck's kill sweep takes every process
/// marked with its session's scope. The process keeps what Terminal.app
/// gives a new shell, and what Bosun's children are documented to read.
public enum LaunchEnvironment {
    /// A new shell's environment in Terminal.app, launchd's part included.
    static let terminal: Set<String> = [
        "HOME", "USER", "LOGNAME", "SHELL", "PATH", "TMPDIR", "LANG", "SSH_AUTH_SOCK",
        "XPC_FLAGS", "XPC_SERVICE_NAME", "__CF_USER_TEXT_ENCODING", "__CFBundleIdentifier",
    ]

    /// Where agent-deck, tmux and the agents keep their state when not in
    /// the default place. `TMUX_TMPDIR` names the tmux server: agent-deck's
    /// sessions and Bosun's own tmux calls have to land on the same one, a
    /// private one as much as the default.
    public static let stateLocations = [
        "AGENTDECK_PROFILE", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "CLAUDE_CONFIG_DIR", "CODEX_HOME", "TMUX_TMPDIR",
    ]

    static func keeps(_ key: String) -> Bool {
        terminal.contains(key) || stateLocations.contains(key) || key.hasPrefix("LC_")
    }

    /// `environment` without what the process must not pass on.
    static func kept(_ environment: [String: String]) -> [String: String] {
        environment.filter { keeps($0.key) }
    }

    /// Drops the rest from the process environment. Before anything reads
    /// `ProcessInfo.processInfo.environment`, which keeps its first reading.
    public static func sanitize() {
        var keys: [String] = []
        var entry = environ
        while let pointer = entry.pointee {
            let pair = String(cString: pointer)
            if let equals = pair.firstIndex(of: "=") {
                keys.append(String(pair[..<equals]))
            }
            entry += 1
        }
        let dropped = keys.filter { !keeps($0) }.sorted()
        for key in dropped {
            unsetenv(key)
        }
        logger.info("dropped from the launch environment: \(dropped.joined(separator: " "), privacy: .public)")
    }
}
