@preconcurrency import Foundation

/// Bosun's own tmux session for one pane, grouped with an agent-deck session:
/// it shares the session's windows but has its own current window, so a
/// window Bosun selects moves no other client, the TUI's included. Like the
/// window operations, views live on tmux's default server.
public enum ViewSession {
    static let prefix = "bosun-view-"

    /// `bosun-view-<pid>-<n>`; the pid tells a dead Bosun's views from a
    /// running one's. Never `agentdeck_…`, which agent-deck's duplicate sweep
    /// kills, and never an extension of the agent-deck session's name, which
    /// tmux's prefix match would take for that session once it is gone.
    public static func name(sequence: Int, pid: Int32 = ProcessInfo.processInfo.processIdentifier) -> String {
        "\(prefix)\(pid)-\(sequence)"
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

extension AgentDeckCLI {
    /// A detached view grouped with agent-deck's `tmuxSession`. It fails for
    /// a session tmux's default server does not have, one on a configured
    /// `[tmux].socket_name`.
    public func createView(_ view: String, grouping tmuxSession: String) async throws {
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

    /// For quitting, which cannot wait: one tmux per view, left to finish
    /// after Bosun has exited.
    public nonisolated func killViewsWithoutWaiting(_ views: [String]) {
        guard let tmux = try? Self.tmuxPath() else { return }
        for view in views {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tmux)
            process.arguments = ["kill-session", "-t", "=\(view)"]
            process.environment = Self.childEnvironment(binaryDirectory: nil)
            try? process.run()
        }
    }

    /// Whether someone else is on the window the view shows, the TUI say:
    /// tmux gives a window one size, and agent-deck's `window-size latest`
    /// gives it to the client used last. Nobody, when tmux cannot say.
    public func someoneElseOnWindow(ofView view: String) async -> Bool {
        guard let window = try? await tmux(["display-message", "-p", "-t", "=\(view):", "#{window_id}"]), window.succeeded,
              let clients = try? await tmux(["list-clients", "-F", ViewSession.clientFormat]), clients.succeeded
        else { return false }
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
