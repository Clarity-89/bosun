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

/// `list-windows -a` read back: every session's windows in tmux's order,
/// and the window each session is on, both keyed by tmux session name. A
/// view grouped with an agent-deck session lists the same windows under its
/// own name, with its own current one.
public struct WindowListing: Equatable, Sendable {
    public var windows: [String: [SessionWindow]] = [:]
    public var currentWindows: [String: String] = [:]

    /// `tmux list-windows -F` format that `init(listOutput:)` reads back.
    static let format = "#{session_name}\t#{window_index}\t#{window_id}\t#{window_name}\t#{pane_current_command}\t#{window_active}"
}

extension WindowListing {
    /// Lines with fewer than six fields or a non-numeric index are skipped.
    public init(listOutput: String) {
        for line in listOutput.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 6, let index = Int(fields[1]) else { continue }
            windows[fields[0], default: []].append(
                SessionWindow(index: index, windowID: fields[2], name: fields[3], command: fields[4])
            )
            if fields[5] == "1" { currentWindows[fields[0]] = fields[2] }
        }
    }
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

/// `MAJOR.MINOR` of the tmux on PATH; tmux's letter suffix (`3.7b`) does
/// not change what a version can do.
public struct TmuxVersion: Comparable, CustomStringConvertible, Sendable {
    public let major: Int
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    /// Parses the first `MAJOR.MINOR` in `tmux -V` output such as `tmux 3.7b`
    /// or `tmux next-3.5`.
    public init?(versionOutput: String) {
        guard let match = versionOutput.firstMatch(of: /(\d+)\.(\d+)/),
              let major = Int(match.1), let minor = Int(match.2)
        else { return nil }
        self.init(major: major, minor: minor)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }

    public var description: String { "\(major).\(minor)" }
}

/// Window operations. Closing goes through agent-deck; the rest talk to tmux
/// directly and so reach only the default server (`list --json` does not
/// expose a session's `[tmux].socket_name`) and skip the cwd assertion and
/// window options agent-deck's TUI applies. Both wait on agent-deck growing
/// `session window list|new|split`.
extension AgentDeckCLI {
    /// Every window of every session, agent-deck's and Bosun's views alike;
    /// one call per refresh instead of one per session.
    public func listAllWindows() async throws -> WindowListing {
        let result = try await tmux(["list-windows", "-a", "-F", WindowListing.format])
        guard result.succeeded else { return WindowListing() }
        return WindowListing(listOutput: result.stdout)
    }

    /// Mirrors the TUI's "open shell here" as a new window. `tmuxSession` is
    /// the agent-deck session or Bosun's view of it, which then shows the
    /// window while other clients stay where they are.
    public func newShellWindow(tmuxSession: String, workingDirectory: String?) async throws {
        try await openShell(["new-window", "-t", "=\(tmuxSession):"], workingDirectory: workingDirectory)
    }

    /// Mirrors the TUI's "open shell here" as a split of the active window
    /// of `tmuxSession`, the agent-deck session or Bosun's view of it.
    public func splitShellPane(tmuxSession: String, direction: SplitDirection, workingDirectory: String?) async throws {
        try await openShell(["split-window", direction.tmuxFlag, "-t", "=\(tmuxSession):"], workingDirectory: workingDirectory)
    }

    /// tmux's current window is per session; every client attached to the
    /// session follows this switch, as with the TUI's window rows. Bosun's
    /// own panes select in their view instead (`selectWindow(_:inView:)`).
    public func selectWindow(windowID: String) async throws {
        try await tmux(["select-window", "-t", windowID]).checkSucceeded()
    }

    /// agent-deck refuses to close a session's last window.
    public func closeWindow(sessionID: String, windowID: String) async throws {
        _ = try await run(["session", "window", "close", sessionID, windowID, "--yes"])
    }

    /// By window id, so the name lands whichever session the window is seen
    /// through. tmux keeps the name from then on: the window's
    /// `automatic-rename` goes off.
    public func renameWindow(windowID: String, to name: String) async throws {
        try await tmux(["rename-window", "-t", windowID, name]).checkSucceeded()
    }

    /// Types `line` into the agent and presses Return, as you would: the
    /// agent's own completion list takes the Return when it is open, as it
    /// does for you. The agent is in the first window's first pane, where
    /// agent-deck started it; a split opened beside it lands to its right or
    /// below, so it stays top left. Keys, not a paste, so the agent's input
    /// takes them as typing.
    public func typeIntoAgent(_ line: String, tmuxSession: String) async throws {
        let pane = "=\(tmuxSession):^.{top-left}"
        try await tmux(["send-keys", "-t", pane, "-l", line, ";", "send-keys", "-t", pane, "Enter"]).checkSucceeded()
    }

    /// The user's shell, which "open shell here" runs.
    public static var userShell: String {
        childEnvironment(binaryDirectory: nil)["SHELL"] ?? "/bin/sh"
    }

    /// Runs `$SHELL` in `workingDirectory` through the given tmux command.
    private func openShell(_ arguments: [String], workingDirectory: String?) async throws {
        var arguments = arguments
        if let workingDirectory { arguments += ["-c", workingDirectory] }
        arguments.append(Self.userShell)
        try await tmux(arguments).checkSucceeded()
    }

    /// tmux as the agent-deck binary's children see it: PATH lookup in the
    /// child environment, which includes the login shell's PATH.
    func tmux(_ arguments: [String]) async throws -> ProcessResult {
        try await Subprocess.run(
            executable: try Self.tmuxPath(), arguments: arguments,
            environment: Self.childEnvironment(binaryDirectory: nil), timeout: .seconds(10)
        )
    }

    /// `tmux -V`, probed once; the binary does not change while Bosun runs.
    func tmuxVersion() async throws -> TmuxVersion {
        if let probedTmuxVersion { return probedTmuxVersion }
        let result = try await tmux(["-V"])
        try result.checkSucceeded()
        guard let version = TmuxVersion(versionOutput: result.stdout) else {
            throw SubprocessError.launchFailed(command: "tmux -V", reason: "no version in \(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        probedTmuxVersion = version
        return version
    }

    static func tmuxPath() throws -> String {
        try executablePath(named: "tmux")
    }
}
