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
    private var statusEventsEnabled = false
    /// Who publishes status transitions; nil until known, with the bus off,
    /// or from an agent-deck too old to say.
    private var statusOwner: StatusOwner?
    private(set) var lastError: String?
    private(set) var selection: SidebarItem?
    private(set) var pane: AttachedPane?
    /// Nil once libghostty is running; otherwise what the pane shows instead.
    private(set) var engineError: String?
    private(set) var windowsBySession: [String: [SessionWindow]] = [:]
    /// Sessions with a lifecycle action in flight; their actions wait for it.
    private(set) var busySessionIDs: Set<String> = []
    /// Bosun's own: agent-deck keeps the TUI's expanded groups in its
    /// database, with no CLI to read or set them.
    private(set) var collapsedGroups = Set(UserDefaults.standard.stringArray(forKey: "collapsedGroups") ?? []) {
        didSet { UserDefaults.standard.set(collapsedGroups.sorted(), forKey: "collapsedGroups") }
    }
    private var refreshTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?

    @ObservationIgnored private let cli = AgentDeckCLI(
        agentDeckPath: UserDefaults.standard.string(forKey: "agentDeckPath")
    )
    @ObservationIgnored private var started = false
    @ObservationIgnored private var binary: AgentDeckBinary?
    @ObservationIgnored private var followerTask: Task<Void, Never>?
    @ObservationIgnored private var reconcileTask: Task<Void, Never>?
    @ObservationIgnored private var delayedRefreshTask: Task<Void, Never>?
    /// The last list with archived rows: a delete must not take a worktree
    /// that an archived session still works in.
    @ObservationIgnored private var everySession: [DeckSession] = []

    private init() {}

    var isRefreshing: Bool { refreshTask != nil }

    var isInstallingNotifyDaemon: Bool { installTask != nil }

    /// Why `session.status` frames cannot arrive, while they cannot; rows
    /// then change only on the 60 s list.
    var statusFeedGap: StatusFeedGap? {
        if !statusEventsEnabled {
            .eventsOff
        } else if statusOwner == .nobody {
            .noPublisher
        } else {
            nil
        }
    }

    /// "Live" only while frames can arrive; a connected follower alone
    /// proves nothing.
    var connectionLabel: String {
        connection == .live && statusFeedGap != nil ? "Updates every 60 s" : connection.label
    }

    var waitingCount: Int {
        sessions.count(where: { $0.status.needsAttention })
    }

    /// Nil while a group row is selected.
    var selectedSession: DeckSession? {
        guard case .pane(let target)? = selection else { return nil }
        return sessions.first { $0.id == target.sessionID }
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

    func setGroup(_ name: String, expanded: Bool) {
        if expanded {
            collapsedGroups.remove(name)
        } else {
            collapsedGroups.insert(name)
        }
    }

    func start() {
        guard !started else { return }
        started = true
        do {
            try GhosttyAppController.shared.start()
        } catch {
            engineError = error.localizedDescription
            logger.error("libghostty failed to start: \(error.localizedDescription, privacy: .public)")
        }
        Task { await bootstrap() }
    }

    func stop() {
        for task in [followerTask, reconcileTask, delayedRefreshTask, refreshTask, installTask] {
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
        do {
            let byTmuxName = try await cli.listAllWindows()
            windowsBySession = sessions.reduce(into: [:]) { result, session in
                if let name = session.tmuxSession, let windows = byTmuxName[name] {
                    result[session.id] = windows
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Pops the session out into a separate Ghostty window.
    func openInGhostty(_ session: DeckSession) {
        run("Ghostty attach") { [cli] in
            try await cli.openGhosttyAttach(sessionID: session.id)
        }
    }

    private func loadSessions() async {
        do {
            everySession = try await cli.list()
            sessions = everySession
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

    /// Shows the target in the pane. Attaching runs `agent-deck session
    /// attach`, a tmux client, so the agent keeps running when the pane goes
    /// away; a window row first switches the session's current window, as
    /// the TUI's window rows do. A group row leaves the pane as it is.
    func select(_ item: SidebarItem?) {
        selection = item
        guard let item else {
            pane = nil
            return
        }
        guard case .pane(let target) = item else { return }
        if let windowID = target.windowID {
            run("select window") { [cli] in try await cli.selectWindow(windowID: windowID) }
        }
        guard pane?.sessionID != target.sessionID else { return }
        guard let binary else {
            lastError = "agent-deck is still starting"
            return
        }
        pane = AttachedPane(sessionID: target.sessionID, launch: binary.attachLaunch(sessionID: target.sessionID))
        logger.info("attached \(target.sessionID, privacy: .public) in window")
        Task { await loadAllWindows() }
    }

    /// A session's windows after the first, which runs the agent.
    func extraWindows(for sessionID: String) -> ArraySlice<SessionWindow> {
        (windowsBySession[sessionID] ?? []).dropFirst()
    }

    /// "Open shell here" as a new tmux window in the session's directory.
    func newShellWindow(in session: DeckSession) {
        guard let tmuxSession = session.tmuxSession else { return }
        run("new window") { [cli] in
            try await cli.newShellWindow(tmuxSession: tmuxSession, workingDirectory: session.path)
        } then: { [weak self] in
            await self?.loadAllWindows()
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
            try await cli.closeWindow(sessionID: session.id, windowID: window.windowID)
        } then: { [weak self] in
            await self?.loadAllWindows()
        }
    }

    func startSession(_ session: DeckSession) {
        lifecycle("start", session) { [cli] in try await cli.startSession(id: session.id) }
    }

    func stopSession(_ session: DeckSession) {
        lifecycle("stop", session) { [cli] in try await cli.stopSession(id: session.id) }
    }

    func restartSession(_ session: DeckSession) {
        lifecycle("restart", session) { [cli] in try await cli.restartSession(id: session.id) }
    }

    func renameSession(_ session: DeckSession, to title: String) {
        lifecycle("rename", session) { [cli] in try await cli.renameSession(id: session.id, to: title) }
    }

    /// `pruneWorktree` is the answer the confirmation showed, so the delete
    /// does what the user agreed to.
    func deleteSession(_ session: DeckSession, pruneWorktree: Bool) {
        lifecycle("delete", session) { [cli] in
            try await cli.deleteSession(id: session.id, pruneWorktree: pruneWorktree)
        }
    }

    func mayPruneWorktree(_ session: DeckSession) -> Bool {
        session.mayPruneWorktree(among: everySession)
    }

    /// One action per session at a time; the list reloads after it, so the
    /// row changes even before the bus reports it. A deleted session's pane
    /// goes with its tmux client, through `paneExited`.
    private func lifecycle(_ label: String, _ session: DeckSession, _ operation: @escaping @Sendable () async throws -> Void) {
        guard busySessionIDs.insert(session.id).inserted else { return }
        run(label, operation) { [weak self] in
            logger.info("\(label, privacy: .public) \(session.id, privacy: .public) done")
            await self?.refresh()
        } finally: { [weak self] in
            self?.busySessionIDs.remove(session.id)
        }
    }

    func paneTitleChanged(sessionID: String, title: String) {
        guard pane?.sessionID == sessionID else { return }
        pane?.title = title
    }

    /// The tmux client ended (Ctrl-Q detach or the session stopped); the
    /// agent itself is untouched, only the pane is gone.
    func paneExited(sessionID: String) {
        guard pane?.sessionID == sessionID else { return }
        pane = nil
        if case .pane = selection { selection = nil }
        logger.info("pane for \(sessionID, privacy: .public) exited")
    }

    private func run(
        _ label: String,
        _ operation: @escaping @Sendable () async throws -> Void,
        then follow: (@MainActor () async -> Void)? = nil,
        finally cleanup: (@MainActor () -> Void)? = nil
    ) {
        lastError = nil
        Task {
            defer { cleanup?() }
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
            self.binary = binary
            logger.info("using \(binary.path, privacy: .public) v\(binary.version, privacy: .public)")
            statusEventsEnabled = try await cli.statusEventsEnabled()
            // Cursor before the list: anything published in between is
            // replayed onto the fresh list instead of being missed.
            let stats = try await cli.eventsStats()
            await refresh()
            startReconcileLoop()
            record(stats)
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
                    record(stats)
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
                async let list: Void = refresh()
                await refreshStatusOwner()
                await list
            }
        }
    }

    /// The owner changes as the TUI starts and quits and as the daemon comes
    /// and goes. A failed check keeps the last answer rather than flashing a
    /// warning.
    private func refreshStatusOwner() async {
        if let stats = try? await cli.eventsStats() {
            record(stats)
        }
    }

    /// With the bus off there is no owner to report: nothing it publishes
    /// could arrive.
    private func record(_ stats: EventsStats) {
        statusOwner = stats.enabled ? stats.statusOwner : nil
    }

    /// Installs agent-deck's notify daemon, which publishes statuses while no
    /// TUI runs, then waits for its first pass to take them over. Offered only
    /// at `.nobody`: an agent-deck without `status_owner` cannot install it.
    func installNotifyDaemon() {
        guard statusOwner == .nobody, installTask == nil else { return }
        lastError = nil
        installTask = Task {
            defer { installTask = nil }
            do {
                let plist = try await cli.installNotifyDaemon()
                logger.info("notify daemon installed: \(plist, privacy: .public)")
                try await awaitNotifyDaemonOwnership()
            } catch is CancellationError {
            } catch {
                lastError = error.localizedDescription
                logger.error("notify daemon install failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// launchd starts the daemon at once; its first pass, a second or two
    /// later, is what makes it the owner.
    private func awaitNotifyDaemonOwnership() async throws {
        for _ in 0..<10 {
            try await Task.sleep(for: .seconds(1))
            await refreshStatusOwner()
            if statusOwner != .nobody { return }
        }
        lastError = "The notify daemon is installed but has not started publishing statuses"
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

/// What the pane shows: a session, optionally one of its extra tmux windows.
struct PaneTarget: Hashable {
    let sessionID: String
    let windowID: String?

    init(sessionID: String, windowID: String? = nil) {
        self.sessionID = sessionID
        self.windowID = windowID
    }
}

/// A sidebar row: a group header or a pane target.
enum SidebarItem: Hashable {
    case group(String)
    case pane(PaneTarget)
}

/// The session attached in the pane and the title its terminal reports.
struct AttachedPane {
    let sessionID: String
    let launch: AttachLaunch
    var title = ""
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

/// Why no `session.status` frame can arrive.
enum StatusFeedGap {
    /// The `macapp.status_events` gate is off.
    case eventsOff
    /// No TUI and no notify daemon writes transitions.
    case noPublisher
}
