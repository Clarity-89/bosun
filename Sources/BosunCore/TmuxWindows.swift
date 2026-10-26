@preconcurrency import Foundation

/// One tmux window inside an agent-deck session. Window 0 runs the agent;
/// the rest are shells or programs the user opened "here".
public struct SessionWindow: Identifiable, Equatable, Sendable {
    public let index: Int
    public let windowID: String
    public let name: String
    public let command: String
    public let active: Bool

    public var id: String { windowID }
}

public enum SplitDirection: Sendable {
    /// Panes side by side (tmux `split-window -h`).
    case sideBySide
    /// Panes stacked (tmux `split-window -v`).
    case topAndBottom

    var tmuxFlag: String {
        switch self {
        case .sideBySide: "-h"
        case .topAndBottom: "-v"
        }
    }
}

extension AgentDeckCLI {
    /// tmux as the agent-deck binary's children see it: PATH lookup in the
    /// child environment, which already includes the package-manager
    /// prefixes a GUI launch would otherwise miss.
    public func tmuxPath() throws -> String {
        for directory in (Self.childEnvironment(binaryDirectory: nil)["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(directory)/tmux"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        throw SubprocessError.launchFailed(command: "tmux", reason: "not found on PATH")
    }

    /// Every window of every session on the server, keyed by tmux session
    /// name; one call per refresh instead of one per session.
    public func listAllWindows() async throws -> [String: [SessionWindow]] {
        let result = try await tmux([
            "list-windows", "-a",
            "-F", "#{session_name}\t#{window_index}\t#{window_id}\t#{window_name}\t#{pane_current_command}\t#{window_active}",
        ])
        guard result.succeeded else { return [:] }
        var bySession: [String: [SessionWindow]] = [:]
        for line in result.stdout.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 6, let index = Int(fields[1]) else { continue }
            bySession[fields[0], default: []].append(
                SessionWindow(index: index, windowID: fields[2], name: fields[3], command: fields[4], active: fields[5] == "1")
            )
        }
        return bySession
    }

    public func listWindows(tmuxSession: String) async throws -> [SessionWindow] {
        try await listAllWindows()[tmuxSession] ?? []
    }

    /// Mirrors the TUI's "open shell here" as a new window.
    public func newShellWindow(tmuxSession: String, workingDirectory: String?) async throws {
        var arguments = ["new-window", "-t", tmuxSession]
        if let workingDirectory { arguments += ["-c", workingDirectory] }
        arguments.append(userShell())
        try await tmux(arguments).checkSucceeded()
    }

    /// Mirrors the TUI's "open shell here" as a split of the active window.
    public func splitShellPane(tmuxSession: String, direction: SplitDirection, workingDirectory: String?) async throws {
        var arguments = ["split-window", direction.tmuxFlag, "-t", tmuxSession]
        if let workingDirectory { arguments += ["-c", workingDirectory] }
        arguments.append(userShell())
        try await tmux(arguments).checkSucceeded()
    }

    /// tmux's current window is per session; every client attached to the
    /// session follows this switch, as with the TUI's window rows.
    public func selectWindow(tmuxSession: String, index: Int) async throws {
        try await tmux(["select-window", "-t", "\(tmuxSession):\(index)"]).checkSucceeded()
    }

    /// agent-deck refuses to close a session's last window.
    public func closeWindow(sessionID: String, windowIndex: Int) async throws {
        _ = try await run(["session", "window", "close", sessionID, String(windowIndex), "--yes"])
    }

    private func tmux(_ arguments: [String]) async throws -> ProcessResult {
        try await Subprocess.run(
            executable: try tmuxPath(),
            arguments: arguments,
            environment: Self.childEnvironment(binaryDirectory: nil),
            timeout: .seconds(10)
        )
    }

    private func userShell() -> String {
        Self.childEnvironment(binaryDirectory: nil)["SHELL"] ?? "/bin/zsh"
    }
}
