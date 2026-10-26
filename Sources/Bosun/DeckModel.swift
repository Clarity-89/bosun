import BosunCore
import BosunTerminal
import Foundation
import Observation
import os

@MainActor
@Observable
final class DeckModel {
    static let shared = DeckModel()

    private(set) var sessions: [DeckSession] = []
    private(set) var connection: ConnectionState = .starting
    private(set) var statusEventsEnabled = false
    private(set) var lastError: String?
    private(set) var selection: PaneTarget?
    private(set) var terminalKey: TerminalHost.Key?
    private(set) var terminalTitles: [String: String] = [:]
    private(set) var windowsBySession: [String: [SessionWindow]] = [:]
    private var refreshTask: Task<Void, Never>?

    @ObservationIgnored private let cli = AgentDeckCLI(
        agentDeckPath: UserDefaults.standard.string(forKey: "agentDeckPath")
    )
    @ObservationIgnored private var started = false
    @ObservationIgnored private var followerTask: Task<Void, Never>?
    @ObservationIgnored private var reconcileTask: Task<Void, Never>?
    @ObservationIgnored private var delayedRefreshTask: Task<Void, Never>?

    private init() {}

    var isRefreshing: Bool { refreshTask != nil }

    var waitingCount: Int {
        sessions.count(where: { $0.status.needsAttention })
    }

    /// `sessions` is kept sorted by group, so consecutive rows form a group.
    var groups: [SessionGroup] {
        var groups: [SessionGroup] = []
        for session in sessions {
            if groups.last?.name == session.groupName {
                groups[groups.count - 1].sessions.append(session)
            } else {
                groups.append(SessionGroup(name: session.groupName, sessions: [session]))
            }
        }
        return groups
    }

    func start() {
        guard !started else { return }
        started = true
        Task { await bootstrap() }
    }

    func stop() {
        for task in [followerTask, reconcileTask, delayedRefreshTask, refreshTask] {
            task?.cancel()
        }
    }

    /// One `list --json` at a time: it runs a status pass, and a slower call
    /// finishing last must not overwrite a newer snapshot.
    func refresh() async {
        if let refreshTask {
            return await refreshTask.value
        }
        let task = Task { await loadSessions() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    /// Window rows for every session, keyed back from tmux session name
    /// to agent-deck id.
    private func loadAllWindows() async {
        guard let byTmuxName = try? await cli.listAllWindows() else { return }
        var result: [String: [SessionWindow]] = [:]
        for session in sessions {
            if let name = session.tmuxSession, let windows = byTmuxName[name] {
                result[session.id] = windows
            }
        }
        windowsBySession = result
    }

    /// Pops the session out into a separate Ghostty window.
    func openInGhostty(_ session: DeckSession) {
        lastError = nil
        Task {
            do {
                try await cli.openGhosttyAttach(sessionID: session.id)
                logger.info("opened Ghostty for \(session.id, privacy: .public)")
            } catch {
                lastError = error.localizedDescription
                logger.error("Ghostty attach failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func loadSessions() async {
        do {
            sessions = try await cli.list()
                .filter { !$0.archived }
                .sorted(using: [
                    KeyPathComparator(\.groupName, comparator: .localizedStandard),
                    KeyPathComparator(\.title, comparator: .localizedStandard),
                    KeyPathComparator(\.id),
                ])
            lastError = nil
            logger.info("list loaded \(self.sessions.count, privacy: .public) sessions")
            await loadAllWindows()
        } catch is CancellationError {
        } catch {
            lastError = error.localizedDescription
            logger.error("list failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Attaches the selected session inside the main window. The embedded
    /// pane runs `agent-deck session attach`, a tmux client, so the agent
    /// keeps running when the pane goes away. A window index selects that
    /// tmux window first, as the TUI's window rows do.
    func select(_ target: PaneTarget?) {
        selection = target
        guard let target else {
            terminalKey = nil
            return
        }
        let sessionID = target.sessionID
        Task {
            do {
                if let index = target.windowIndex, let tmuxSession = session(sessionID)?.tmuxSession {
                    try await cli.selectWindow(tmuxSession: tmuxSession, index: index)
                }
                guard selection?.sessionID == sessionID else { return }
                if terminalKey?.sessionID != sessionID {
                    var launch = try await cli.attachLaunch(sessionID: sessionID)
                    launch.environment["TERM_PROGRAM"] = "Bosun"
                    guard selection?.sessionID == sessionID else { return }
                    // libghostty runs this as `sh -c "exec <command>"`; no exec here.
                    terminalKey = TerminalHost.Key(
                        sessionID: sessionID,
                        launch: TerminalPane.Launch(command: launch.command, environment: launch.environment)
                    )
                    logger.info("attached \(sessionID, privacy: .public) in window")
                }
                await loadWindows(for: sessionID)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func windows(for sessionID: String) -> [SessionWindow] {
        windowsBySession[sessionID] ?? []
    }

    func loadWindows(for sessionID: String) async {
        guard let tmuxSession = session(sessionID)?.tmuxSession else { return }
        do {
            windowsBySession[sessionID] = try await cli.listWindows(tmuxSession: tmuxSession)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// "Open shell here" as a new tmux window in the session's directory.
    func newShellWindow(in session: DeckSession) {
        guard let tmuxSession = session.tmuxSession else { return }
        run("new window") { [cli] in
            try await cli.newShellWindow(tmuxSession: tmuxSession, workingDirectory: session.path)
        } then: { [weak self] in
            await self?.loadWindows(for: session.id)
        }
    }

    /// "Open shell here" as a split of the session's active window.
    func split(_ session: DeckSession, _ direction: SplitDirection) {
        guard let tmuxSession = session.tmuxSession else { return }
        run("split") { [cli] in
            try await cli.splitShellPane(tmuxSession: tmuxSession, direction: direction, workingDirectory: session.path)
        }
    }

    func closeWindow(_ window: SessionWindow, in session: DeckSession) {
        run("close window") { [cli] in
            try await cli.closeWindow(sessionID: session.id, windowIndex: window.index)
        } then: { [weak self] in
            await self?.loadWindows(for: session.id)
        }
    }

    func terminalTitleChanged(sessionID: String, title: String) {
        terminalTitles[sessionID] = title
    }

    /// The tmux client ended (Ctrl-Q detach or the session stopped); the
    /// agent itself is untouched, only the pane is gone.
    func terminalExited(sessionID: String) {
        guard terminalKey?.sessionID == sessionID else { return }
        terminalKey = nil
        selection = nil
        logger.info("pane for \(sessionID, privacy: .public) exited")
    }

    private func session(_ id: String) -> DeckSession? {
        sessions.first { $0.id == id }
    }

    private func run(_ label: String, _ operation: @escaping @Sendable () async throws -> Void, then follow: (@MainActor () async -> Void)? = nil) {
        lastError = nil
        Task {
            do {
                try await operation()
                await follow?()
            } catch {
                lastError = error.localizedDescription
                logger.error("\(label, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func bootstrap() async {
        do {
            let binary = try await cli.binary()
            logger.info("using \(binary.path, privacy: .public) v\(binary.version, privacy: .public)")
            statusEventsEnabled = try await cli.statusEventsEnabled()
            // Cursor before the list: anything published in between is
            // replayed onto the fresh list instead of being missed.
            let stats = try await cli.eventsStats()
            await refresh()
            startReconcileLoop()
            if stats.enabled {
                startFollower(after: stats.cursor)
            } else {
                connection = .unavailable
                lastError = "The event bus is disabled; statuses refresh every 60 s"
            }
        } catch {
            connection = .unavailable
            lastError = error.localizedDescription
            logger.error("startup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func startFollower(after initialCursor: UInt64) {
        followerTask?.cancel()
        followerTask = Task { await followLoop(after: initialCursor) }
    }

    private func followLoop(after initialCursor: UInt64) async {
        var cursor = initialCursor
        var retryDelay: Duration = .seconds(1)

        while true {
            do {
                connection = .reconnecting
                let frames = try await cli.follow(after: cursor)
                connection = .live
                retryDelay = .seconds(1)
                logger.info("follower live after \(cursor, privacy: .public)")
                for try await frame in frames {
                    cursor = max(cursor, frame.cursor)
                    apply(frame)
                }
                // The stream ends without an error only when this task is cancelled.
                return
            } catch {
                if Task.isCancelled { return }
                connection = .reconnecting
                if AgentDeckCLI.isCursorTooOld(error), let stats = try? await cli.eventsStats() {
                    cursor = stats.cursor
                    await refresh()
                    logger.info("follower resynced at \(cursor, privacy: .public)")
                } else {
                    lastError = error.localizedDescription
                    logger.error("follower failed: \(error.localizedDescription, privacy: .public)")
                }
                try? await Task.sleep(for: retryDelay)
                if Task.isCancelled { return }
                retryDelay = min(retryDelay * 2, .seconds(30))
            }
        }
    }

    private func startReconcileLoop() {
        reconcileTask?.cancel()
        reconcileTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if Task.isCancelled { return }
                await refresh()
            }
        }
    }

    private func apply(_ frame: BusFrame) {
        // `--kind session.status` also matches dot-prefixed sub-kinds agent-deck may add.
        guard frame.kind == "session.status", let change = frame.data else { return }
        guard let index = sessions.firstIndex(where: { $0.id == frame.sessionID }) else {
            scheduleRefresh()
            return
        }
        sessions[index].status = change.to
        // The bus carries no substate, and the old one described the previous status.
        sessions[index].substate = nil
        logger.info("status \(frame.sessionID, privacy: .public) -> \(change.to.rawValue, privacy: .public)")
    }

    /// A frame for a session the list does not know yet (created since the
    /// last list); one list after a short wait picks up the burst.
    private func scheduleRefresh() {
        guard delayedRefreshTask == nil else { return }
        delayedRefreshTask = Task {
            defer { delayedRefreshTask = nil }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }
}

struct SessionGroup: Identifiable {
    let name: String
    var sessions: [DeckSession]
    var id: String { name }
}

extension DeckSession {
    var groupName: String {
        let name = group.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Ungrouped" : name
    }
}

enum ConnectionState: Equatable, Sendable {
    case starting
    case live
    case reconnecting
    case unavailable

    var label: String {
        switch self {
        case .starting: "Starting"
        case .live: "Live"
        case .reconnecting: "Reconnecting"
        case .unavailable: "Unavailable"
        }
    }
}
