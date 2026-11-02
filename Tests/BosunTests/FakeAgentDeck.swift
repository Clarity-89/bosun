import Foundation
@testable import BosunCore

/// agent-deck in memory: the sessions and groups `list` answers with, a
/// tmux of windows and views, and a bus the test publishes frames on. Each
/// command is recorded as agent-deck's or tmux's own line, or one named
/// for what the CLI does where neither has one (`binary`,
/// `kill-orphan-views`), so a test can say what the model asked and in
/// what order. A command named in `failures` throws its error instead of
/// running; one that cannot fail, `killView` say, swallows it as the CLI
/// does.
@MainActor
final class FakeAgentDeck: AgentDeck {
    var binary = AgentDeckBinary(path: "/fake/bin/agent-deck", version: .minimumSupported)
    var sessions: [DeckSession] = []
    var groups: [DeckGroup] = []
    var statusEvents = true
    var stats = EventsStats(enabled: true, cursor: 0, statusOwner: .tui)
    var windows = WindowListing()
    var loneViews: Set<String> = []
    var panes: [AgentPane]? = []
    var someoneElse = false
    /// Errors by command name, the recorded line's first words: `"list"`,
    /// `"session stop"`, `"new-session"`.
    var failures: [String: any Error] = [:]
    /// What each `follow` ends with instead of frames, in order; the bus
    /// answers once these are spent.
    var followErrors: [any Error] = []
    /// Holds every `list` until `releaseList()`, to catch calls that
    /// arrive during one.
    var holdsList = false

    private(set) var commands: [String] = []
    /// The cursor each `follow` started after.
    private(set) var followedAfter: [UInt64] = []
    /// The views grouped with a session, by view name.
    private(set) var views: [String: String] = [:]
    /// Every frame published, which `follow` replays from its cursor, as
    /// agent-deck's retained log does, before streaming new ones.
    private var log: [BusFrame] = []
    private var following: AsyncThrowingStream<BusFrame, any Error>.Continuation?
    private var listWaiters: [CheckedContinuation<Void, Never>] = []
    private var added = 0

    /// The recorded lines that are `name` or start with it.
    func calls(_ name: String) -> [String] {
        commands.filter { $0 == name || $0.hasPrefix(name + " ") }
    }

    /// A `session.status` frame on the bus, as agent-deck's publisher would
    /// write it.
    func publish(_ status: SessionStatus, for sessionID: String, cursor: UInt64) {
        let frame = BusFrame(cursor: cursor, kind: "session.status", sessionID: sessionID, data: StatusChange(to: status))
        log.append(frame)
        following?.yield(frame)
    }

    func releaseList() {
        holdsList = false
        for waiter in listWaiters { waiter.resume() }
        listWaiters = []
    }

    /// Records the line and throws the failure set for its command.
    private func record(_ command: String, _ arguments: String...) throws {
        commands.append(([command] + arguments).joined(separator: " "))
        if let error = failures[command] { throw error }
    }

    private func row(of id: String) -> Int? {
        sessions.firstIndex { $0.id == id }
    }

    // MARK: agent-deck itself

    func binary() async throws -> AgentDeckBinary {
        try record("binary")
        return binary
    }

    func statusEventsEnabled() async throws -> Bool {
        try record("config get macapp.status_events")
        return statusEvents
    }

    func eventsStats() async throws -> EventsStats {
        try record("events stats")
        return stats
    }

    func follow(after cursor: UInt64) async throws -> any AsyncSequence<BusFrame, any Error> & Sendable {
        followedAfter.append(cursor)
        try record("events follow", String(cursor))
        if !followErrors.isEmpty {
            throw followErrors.removeFirst()
        }
        let (stream, continuation) = AsyncThrowingStream<BusFrame, any Error>.makeStream()
        for frame in log where frame.cursor > cursor {
            continuation.yield(frame)
        }
        following = continuation
        return stream
    }

    func installNotifyDaemon() async throws -> String {
        try record("notify-daemon install")
        return "/fake/LaunchAgents/com.agent-deck.notify.plist"
    }

    func openGhosttyAttach(sessionID: String) async throws {
        try record("session attach", sessionID)
    }

    // MARK: Sessions and groups

    func list() async throws -> [DeckSession] {
        try record("list")
        if holdsList {
            await withCheckedContinuation { listWaiters.append($0) }
        }
        return sessions
    }

    func groups() async throws -> [DeckGroup] {
        try record("group list")
        return groups
    }

    /// The session is listed idle with a tmux session, as agent-deck lists
    /// one it has not started.
    func addSession(_ request: NewSessionRequest) async throws -> AddedSession {
        try record("add", request.title, request.directory)
        added += 1
        let id = "new-\(added)"
        sessions.append(DeckSession(
            id: id, title: request.title.isEmpty ? id : request.title, path: request.directory, group: request.groupPath,
            tool: "shell", status: .idle, substate: nil, tmuxSession: "agentdeck_\(id)", worktreePath: nil, archived: false,
            lastActivityAt: nil
        ))
        return AddedSession(id: id, setupHookNotice: nil)
    }

    func startSession(id: String) async throws {
        try record("session start", id)
    }

    func stopSession(id: String) async throws {
        try record("session stop", id)
        if let row = self.row(of: id) { sessions[row].status = .stopped }
    }

    /// Restarted under a new tmux session, as agent-deck does.
    func restartSession(id: String) async throws {
        try record("session restart", id)
        if let row = self.row(of: id) {
            sessions[row] = sessions[row].with(status: .idle, tmuxSession: "agentdeck_\(id)_restarted")
        }
    }

    func runWorktreeSetup(sessionID: String) async throws {
        try record("worktree setup", sessionID)
    }

    func renameSession(id: String, to title: String) async throws {
        try record("rename", id, title)
        if let row = self.row(of: id) { sessions[row] = sessions[row].with(title: title) }
    }

    func deleteSession(id: String) async throws {
        try record("session remove", id)
        sessions.removeAll { $0.id == id }
    }

    func deleteGroup(path: String) async throws {
        try record("group delete", path)
        groups.removeAll { $0.path == path }
    }

    func moveSession(id: String, _ placement: RowPlacement) async throws {
        try record("session set", id, "order")
        guard let row = self.row(of: id) else { return }
        let moved = sessions.remove(at: row)
        switch placement {
        case .after(let neighbour):
            if let at = self.row(of: neighbour) { sessions.insert(moved, at: at + 1) }
        case .before(let neighbour):
            if let at = self.row(of: neighbour) { sessions.insert(moved, at: at) }
        }
    }

    func moveGroup(path: String, _ placement: RowPlacement) async throws {
        try record("group reorder", path)
        guard let index = groups.firstIndex(where: { $0.path == path }) else { return }
        let moved = groups.remove(at: index)
        switch placement {
        case .after(let neighbour):
            if let at = groups.firstIndex(where: { $0.path == neighbour }) { groups.insert(moved, at: at + 1) }
        case .before(let neighbour):
            if let at = groups.firstIndex(where: { $0.path == neighbour }) { groups.insert(moved, at: at) }
        }
    }

    // MARK: Windows and panes

    func listAllWindows() async throws -> WindowListing {
        try record("list-windows")
        return windows
    }

    func listAgentPanes() async -> [AgentPane]? {
        panes
    }

    func newShellWindow(tmuxSession: String, workingDirectory: String?) async throws {
        try record("new-window", tmuxSession, workingDirectory ?? "")
    }

    func splitShellPane(tmuxSession: String, direction: SplitDirection, workingDirectory: String?) async throws {
        try record("split-window", tmuxSession, workingDirectory ?? "")
    }

    func selectWindow(windowID: String) async throws {
        try record("select-window", windowID)
    }

    func closeWindow(sessionID: String, windowID: String) async throws {
        try record("session window close", sessionID, windowID)
        for name in windows.windows.keys {
            windows.windows[name]?.removeAll { $0.windowID == windowID }
        }
    }

    func renameWindow(windowID: String, to name: String) async throws {
        try record("rename-window", windowID, name)
    }

    func typeIntoAgent(_ line: String, tmuxSession: String) async throws {
        try record("send-keys", tmuxSession, line)
    }

    // MARK: Bosun's views

    /// The view lists the session's windows under its own name and starts
    /// on the first, as tmux's `new-session -t` has it.
    func createView(_ view: String, grouping tmuxSession: String, directory: String?) async throws {
        try record("new-session", tmuxSession, view)
        guard windows.windows[tmuxSession] != nil || sessions.contains(where: { $0.tmuxSession == tmuxSession }) else {
            throw SubprocessError.exited(command: "tmux has-session", status: 1, stderr: "can't find session: \(tmuxSession)")
        }
        views[view] = tmuxSession
        windows.windows[view] = windows.windows[tmuxSession]
        windows.currentWindows[view] = windows.windows[tmuxSession]?.first?.windowID
    }

    func selectWindow(_ windowID: String?, inView view: String) async throws {
        try record("select-window", "=\(view):\(windowID ?? "^")")
        windows.currentWindows[view] = windowID ?? windows.windows[view]?.first?.windowID
    }

    func killView(_ view: String) async {
        try? record("kill-session", view)
        views[view] = nil
        windows.windows[view] = nil
        windows.currentWindows[view] = nil
    }

    func killOrphanViews() async {
        try? record("kill-orphan-views")
    }

    func loneViews() async -> Set<String> {
        loneViews
    }

    func someoneElseOnWindow(ofView view: String) async -> Bool {
        someoneElse
    }

    func setSizesWindow(_ sizes: Bool, view: String) async {
        try? record("refresh-client", view, sizes ? "!ignore-size" : "ignore-size")
    }

    nonisolated func viewAttachLaunch(_ view: String, yieldsSize: Bool) throws -> AttachLaunch {
        AttachLaunch(command: "tmux attach-session -t =\(view)", environment: [:])
    }

    nonisolated func attachLaunch(_ binary: AgentDeckBinary, sessionID: String) -> AttachLaunch {
        AttachLaunch(command: "\(binary.path) session attach \(sessionID)", environment: [:])
    }
}

extension DeckSession {
    /// The row as agent-deck lists it after a rename or a restart; a new
    /// status comes without the substate that described the old one.
    func with(title: String? = nil, status: SessionStatus? = nil, tmuxSession: String? = nil) -> DeckSession {
        DeckSession(
            id: id, title: title ?? self.title, path: path, group: group, tool: tool, status: status ?? self.status,
            substate: status == nil ? substate : nil, tmuxSession: tmuxSession ?? self.tmuxSession, worktreePath: worktreePath,
            archived: archived, lastActivityAt: lastActivityAt
        )
    }
}
