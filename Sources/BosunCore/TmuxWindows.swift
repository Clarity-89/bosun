@preconcurrency import Foundation

/// One tmux window inside an agent-deck session. tmux's first window (`^`)
/// runs the agent; the rest are shells or programs the user opened "here".
public struct SessionWindow: Identifiable, Equatable, Sendable {
    public let index: Int
    /// tmux's `@N` id: stable, unlike `index`, which tmux renumbers and reuses.
    public let windowID: String
    public let name: String
    public let command: String

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

/// Window operations. Closing goes through agent-deck; the rest talk to tmux
/// directly and so reach only the default server (`list --json` does not
/// expose a session's `[tmux].socket_name`) and skip the cwd assertion and
/// window options agent-deck's TUI applies. Both wait on agent-deck growing
/// `session window list|new|split`.
extension AgentDeckCLI {
    /// Every window of every session, in tmux's index order and keyed by
    /// tmux session name; one call per refresh instead of one per session.
    public func listAllWindows() async throws -> [String: [SessionWindow]] {
        let result = try await tmux([
            "list-windows", "-a",
            "-F", "#{session_name}\t#{window_index}\t#{window_id}\t#{window_name}\t#{pane_current_command}",
        ])
        guard result.succeeded else { return [:] }
        return SessionWindow.parse(listOutput: result.stdout)
    }
}

extension SessionWindow {
    /// Parses `list-windows -a` output in the tab-separated format above.
    /// Lines that do not have five fields or a numeric index are skipped.
    public static func parse(listOutput: String) -> [String: [SessionWindow]] {
        var bySession: [String: [SessionWindow]] = [:]
        for line in listOutput.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 5, let index = Int(fields[1]) else { continue }
            bySession[fields[0], default: []].append(
                SessionWindow(index: index, windowID: fields[2], name: fields[3], command: fields[4])
            )
        }
        return bySession
    }
}

extension AgentDeckCLI {

    /// Mirrors the TUI's "open shell here" as a new window.
    public func newShellWindow(tmuxSession: String, workingDirectory: String?) async throws {
        try await openShell(["new-window", "-t", tmuxSession], workingDirectory: workingDirectory)
    }

    /// Mirrors the TUI's "open shell here" as a split of the active window.
    public func splitShellPane(tmuxSession: String, direction: SplitDirection, workingDirectory: String?) async throws {
        try await openShell(["split-window", direction.tmuxFlag, "-t", tmuxSession], workingDirectory: workingDirectory)
    }

    /// tmux's current window is per session; every client attached to the
    /// session follows this switch, as with the TUI's window rows.
    public func selectWindow(windowID: String) async throws {
        try await tmux(["select-window", "-t", windowID]).checkSucceeded()
    }

    /// agent-deck refuses to close a session's last window.
    public func closeWindow(sessionID: String, windowID: String) async throws {
        _ = try await run(["session", "window", "close", sessionID, windowID, "--yes"])
    }

    /// Runs `$SHELL` in `workingDirectory` through the given tmux command.
    private func openShell(_ arguments: [String], workingDirectory: String?) async throws {
        var arguments = arguments
        if let workingDirectory { arguments += ["-c", workingDirectory] }
        arguments.append(Self.childEnvironment(binaryDirectory: nil)["SHELL"] ?? "/bin/sh")
        try await tmux(arguments).checkSucceeded()
    }

    /// tmux as the agent-deck binary's children see it: PATH lookup in the
    /// child environment, which already includes the package-manager
    /// prefixes a GUI launch would otherwise miss.
    private func tmux(_ arguments: [String]) async throws -> ProcessResult {
        let environment = Self.childEnvironment(binaryDirectory: nil)
        let tmux = (environment["PATH"] ?? "").split(separator: ":").lazy
            .map { "\($0)/tmux" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let tmux else { throw SubprocessError.launchFailed(command: "tmux", reason: "not found on PATH") }
        return try await Subprocess.run(executable: tmux, arguments: arguments, environment: environment, timeout: .seconds(10))
    }
}
