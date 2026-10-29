@preconcurrency import Foundation

/// Bosun's own tmux session for one pane, grouped with an agent-deck session:
/// it shares the session's windows but has its own current window, so a
/// window Bosun selects moves no other client, the TUI's included. Like the
/// window operations, views live on tmux's default server.
public enum ViewSession {
    static let prefix = "bosun-view-"

    /// `ignore-size` on `attach-session` and `refresh-client`, and
    /// `session_group_size`, arrived in 3.2.
    static let minimumTmux = TmuxVersion(major: 3, minor: 2)

    /// `bosun-view-<pid>-<first 8 of the pane id>`; the pid tells a dead
    /// Bosun's views from a running one's. Never `agentdeck_…`, which
    /// agent-deck's duplicate sweep kills, and never an extension of the
    /// agent-deck session's name, which tmux's prefix match would take for
    /// that session once it is gone.
    public static func name(paneID: UUID, pid: Int32 = ProcessInfo.processInfo.processIdentifier) -> String {
        "\(prefix)\(pid)-\(paneID.uuidString.prefix(8).lowercased())"
    }

    /// The views among `sessionNames` whose Bosun no longer runs: tmux ends
    /// a view with its client, but a crash between creating a view and
    /// attaching it leaves the view behind.
    static func orphans(in sessionNames: [String], ownPID: Int32, isRunning: (Int32) -> Bool) -> [String] {
        sessionNames.filter { name in
            guard name.hasPrefix(prefix),
                  let pid = Int32(name.dropFirst(prefix.count).prefix { $0 != "-" }) else { return false }
            return pid != ownPID && !isRunning(pid)
        }
    }

    /// `list-sessions -F` format that `loneViews(in:)` reads.
    static let groupSizeFormat = "#{session_name}\t#{session_group_size}"

    /// The views alone in their group: agent-deck has killed the session each
    /// was grouped with, perhaps to recreate it under the same name, and the
    /// view alone keeps the dead session's windows alive.
    static func loneViews(in listOutput: String) -> Set<String> {
        var lone: Set<String> = []
        for line in listOutput.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 2, fields[0].hasPrefix(prefix), (Int(fields[1]) ?? 0) < 2 else { continue }
            lone.insert(String(fields[0]))
        }
        return lone
    }

    /// `list-clients -F` format that `someoneElse(on:besides:clients:)` reads.
    static let clientFormat = "#{client_session}\t#{window_id}\t#{client_flags}"

    /// Whether a person other than the view's client is on `windowID`.
    /// agent-deck's control-mode pipes are nobody, and an `ignore-size`
    /// client sizes nothing, as tmux itself has it.
    static func someoneElse(on windowID: String, besides view: String, clients: String) -> Bool {
        clients.split(whereSeparator: \.isNewline).contains { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3, fields[1] == windowID, fields[0] != view else { return false }
            let flags = Set(fields[2].split(separator: ",").map(String.init))
            return flags.isDisjoint(with: ["control-mode", "ignore-size", "suspended"])
        }
    }
}

/// Why a view could not be made.
public enum ViewSessionError: Error, LocalizedError, Equatable, Sendable {
    case tmuxTooOld(TmuxVersion)

    public var errorDescription: String? {
        switch self {
        case .tmuxTooOld(let version):
            "tmux \(version) is older than \(ViewSession.minimumTmux)"
        }
    }
}

extension AgentDeckCLI {
    /// A detached view grouped with agent-deck's `tmuxSession`. It fails on a
    /// tmux older than 3.2, and for a session tmux's default server does not
    /// have, one on a configured `[tmux].socket_name`.
    public func createView(_ view: String, grouping tmuxSession: String) async throws {
        let version = try await tmuxVersion()
        guard version >= ViewSession.minimumTmux else { throw ViewSessionError.tmuxTooOld(version) }
        try await tmux(["new-session", "-d", "-t", "=\(tmuxSession)", "-s", view]).checkSucceeded()
    }

    /// Shows `windowID` in the view, or the agent's window, tmux's first.
    public func selectWindow(_ windowID: String?, inView view: String) async throws {
        try await tmux(["select-window", "-t", "=\(view):\(windowID ?? "^")"]).checkSucceeded()
    }

    /// Ending a view ends the windows only it still holds: those of an
    /// agent-deck session that tmux no longer has.
    public func killView(_ view: String) async {
        _ = try? await tmux(["kill-session", "-t", "=\(view)"])
    }

    /// Kills the views a crashed Bosun left behind.
    public func killOrphanViews() async {
        guard let result = try? await tmux(["list-sessions", "-F", "#{session_name}"]), result.succeeded else { return }
        let names = result.stdout.split(whereSeparator: \.isNewline).map(String.init)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for view in ViewSession.orphans(in: names, ownPID: ownPID, isRunning: { kill($0, 0) == 0 || errno == EPERM }) {
            await killView(view)
        }
    }

    /// The views whose agent-deck session tmux no longer has, by name; see
    /// `ViewSession.loneViews(in:)`. Empty when tmux cannot say.
    public func loneViews() async -> Set<String> {
        guard let result = try? await tmux(["list-sessions", "-F", ViewSession.groupSizeFormat]), result.succeeded else { return [] }
        return ViewSession.loneViews(in: result.stdout)
    }

    /// Whether someone else is on the window the view shows, the TUI say:
    /// tmux gives a window one size, and agent-deck's `window-size latest`
    /// gives it to the client used last. Someone, when tmux cannot say: the
    /// pane then waits for input before it sizes a window whose clients it
    /// could not see.
    public func someoneElseOnWindow(ofView view: String) async -> Bool {
        guard let window = try? await tmux(["display-message", "-p", "-t", "=\(view):", "#{window_id}"]), window.succeeded,
              let clients = try? await tmux(["list-clients", "-F", ViewSession.clientFormat]), clients.succeeded
        else { return true }
        let windowID = window.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return ViewSession.someoneElse(on: windowID, besides: view, clients: clients.stdout)
    }

    /// Whether the view's client takes part in sizing its window; without,
    /// the window keeps the size the other clients give it.
    public func setSizesWindow(_ sizes: Bool, view: String) async {
        guard let clients = try? await tmux(["list-clients", "-t", "=\(view)", "-F", "#{client_name}"]), clients.succeeded else { return }
        for client in clients.stdout.split(whereSeparator: \.isNewline) {
            _ = try? await tmux(["refresh-client", "-t", String(client), "-f", sizes ? "!ignore-size" : "ignore-size"])
        }
    }

    /// The pane's command for `view`: tmux itself, as `session attach` only
    /// attaches agent-deck's own session. Ctrl-Q therefore no longer detaches;
    /// agent-deck's key binding swallows it outside its own sessions.
    public nonisolated func viewAttachLaunch(_ view: String, yieldsSize: Bool) throws -> AttachLaunch {
        AttachLaunch(
            command: Terminal.viewAttachCommand(tmuxPath: try Self.tmuxPath(), view: view, yieldsSize: yieldsSize),
            environment: Self.childEnvironment(binaryDirectory: nil)
        )
    }
}
