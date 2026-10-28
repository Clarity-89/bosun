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
    private(set) var pane: SessionPane?
    /// Nil once libghostty is running; otherwise what the pane shows instead.
    private(set) var engineError: String?
    private(set) var windowsBySession: [String: [SessionWindow]] = [:]
    /// Sessions with a lifecycle action in flight; their actions wait for it.
    private(set) var busySessionIDs: Set<String> = []
    /// The New Session dialog while it is open.
    private(set) var newSessionPrompt: NewSessionPrompt?
    /// agent-deck's groups as `group list` last reported them, the empty
    /// ones the sidebar never shows included: the sidebar's order and the
    /// New Session dialog's choices.
    private(set) var deckGroups: [DeckGroup] = []
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
    @ObservationIgnored private var isReordering = false

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

    /// Nil unless a window row is selected.
    var selectedWindow: SessionWindow? {
        guard case .pane(let target)? = selection, let windowID = target.windowID else { return nil }
        return windowsBySession[target.sessionID]?.first { $0.windowID == windowID }
    }

    /// The session the pane shows; nil while it shows none or the list no
    /// longer has it.
    var paneSession: DeckSession? {
        guard let pane else { return nil }
        return sessions.first { $0.id == pane.sessionID }
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

    func toggleGroup(_ name: String) {
        collapsedGroups.formSymmetricDifference([name])
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
            // Without the group order (a failed `group list`) the last one
            // still keeps each group's rows together.
            async let listed = cli.list()
            async let groupOrder = cli.groups()
            let visible = try await listed.filter { !$0.archived }
            if let groups = try? await groupOrder {
                deckGroups = groups
            }
            sessions = DeckSession.inDeckOrder(visible, groupPaths: deckGroups.map(\.path))
            lastError = nil
            logger.info("list loaded \(self.sessions.count, privacy: .public) sessions")
            // A session deleted while not running has no tmux client whose
            // exit would close its pane.
            if case .notRunning(let sessionID)? = pane, !sessions.contains(where: { $0.id == sessionID }) {
                closePane()
            }
            await loadAllWindows()
        } catch is CancellationError {
        } catch {
            lastError = error.localizedDescription
            logger.error("list failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Shows the target in the pane. Attaching runs `agent-deck session
    /// attach`, a tmux client, so the agent keeps running when the pane goes
    /// away. A stopped session gets Restart instead, as its attach would exit
    /// at once. Every other status attaches: `error` can be an agent that is
    /// alive but blocked, and an attach that finds nothing falls back to
    /// Restart through `paneExited`. A window row first switches the
    /// session's current window, as the TUI's window rows do. A group row
    /// leaves the pane as it is.
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
        // Only a terminal is kept; a pane offering Restart tries again, as
        // the row may have caught up with the session.
        guard pane?.attached?.sessionID != target.sessionID else { return }
        if sessions.first(where: { $0.id == target.sessionID })?.status == .stopped {
            pane = .notRunning(sessionID: target.sessionID)
        } else {
            attach(target.sessionID)
        }
    }

    private func attach(_ sessionID: String) {
        guard let binary else {
            lastError = "agent-deck is still starting"
            return
        }
        pane = .attached(AttachedPane(sessionID: sessionID, launch: binary.attachLaunch(sessionID: sessionID)))
        logger.info("attached \(sessionID, privacy: .public) in window")
        Task { await loadAllWindows() }
    }

    /// Opens the New Session dialog on the group it creates in: `groupName`,
    /// else the selected row's. A list runs alongside, so a group made
    /// elsewhere since the last one reaches the dialog's picker.
    func promptNewSession(inGroup groupName: String? = nil) {
        newSessionPrompt = newSessionDefaults(inGroup: groupName)
        Task { await refresh() }
    }

    func dismissNewSession() {
        newSessionPrompt = nil
    }

    /// The dialog's defaults without the dialog, and a title agent-deck
    /// generates.
    func quickCreateSession(inGroup groupName: String? = nil) {
        let defaults = newSessionDefaults(inGroup: groupName)
        let request = NewSessionRequest(
            directory: defaults.directory, groupPath: defaults.groupPath, command: defaults.command, quick: true
        )
        run("quick session") { [weak self] in try await self?.createSession(request) }
    }

    /// Adds the session, starts it and attaches it in the pane. A refused add
    /// throws; after a refused start the pane offers Restart and the footer
    /// says why.
    func createSession(_ request: NewSessionRequest) async throws {
        let sessionID = try await cli.addSession(request)
        UserDefaults.standard.set(request.command.trimmingCharacters(in: .whitespaces), forKey: Self.lastCommandKey)
        logger.info("created \(sessionID, privacy: .public)")
        var startError: String?
        do {
            try await cli.startSession(id: sessionID)
        } catch {
            startError = error.localizedDescription
            logger.error("start \(sessionID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
        await refresh()
        if let group = sessions.first(where: { $0.id == sessionID })?.groupName {
            collapsedGroups.remove(group)
        }
        selection = .pane(PaneTarget(sessionID: sessionID))
        if let startError {
            pane = .notRunning(sessionID: sessionID)
            lastError = startError
        } else {
            attach(sessionID)
        }
    }

    /// The group is `groupName`, else the selected row's; one agent-deck no
    /// longer lists gives way to the first it does. The directory is the
    /// selected session's when it is in that group, else one of the group's
    /// sessions', else home. The command is the last one a session was
    /// created with, `omp` at first.
    private func newSessionDefaults(inGroup groupName: String?) -> NewSessionPrompt {
        let selected = selectedSession
        var groupName = groupName ?? selected?.groupName
        if groupName == nil, case .group(let name)? = selection {
            groupName = name
        }
        let member = selected.flatMap { $0.groupName == groupName ? $0 : nil }
            ?? sessions.first { $0.groupName == groupName }
        let directory = member?.path ?? FileManager.default.homeDirectoryForCurrentUser.path
        return NewSessionPrompt(
            groupPath: DeckGroup.listedPath(member?.group ?? "", in: deckGroups),
            directory: (directory as NSString).abbreviatingWithTildeInPath,
            command: UserDefaults.standard.string(forKey: Self.lastCommandKey) ?? "omp"
        )
    }

    private static let lastCommandKey = "newSessionCommand"

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

    func stopSession(_ session: DeckSession) {
        lifecycle("stop", session) { [cli] in try await cli.stopSession(id: session.id) }
    }

    /// Restart also starts a stopped session; a pane offering it attaches
    /// what it started.
    func restartSession(_ session: DeckSession) {
        lifecycle("restart", session, { [cli] in try await cli.restartSession(id: session.id) }) { [weak self] in
            if case .notRunning(session.id)? = self?.pane { self?.attach(session.id) }
        }
    }

    func renameSession(_ session: DeckSession, to title: String) {
        lifecycle("rename", session) { [cli] in try await cli.renameSession(id: session.id, to: title) }
    }

    func deleteSession(_ session: DeckSession) {
        lifecycle("delete", session) { [cli] in try await cli.deleteSession(id: session.id) }
    }

    /// Drag and drop within a group. The rows reorder at once; agent-deck
    /// then stores the order, and the list that follows confirms it or,
    /// after a refusal, puts it back.
    func moveSession(_ move: SessionMove) {
        reorder("move \(move.sessionID)", DeckSession.reordering(sessions, within: move.order)) { [cli] in
            try await cli.moveSession(id: move.sessionID, move.placement)
        }
    }

    /// Drag and drop of a group header: the group moves with its sessions,
    /// at once here and then in agent-deck, as for a session.
    func moveGroup(_ move: GroupMove) {
        reorder("move group \(move.path)", DeckSession.inDeckOrder(sessions, groupPaths: move.order)) { [cli] in
            try await cli.moveGroup(path: move.path, move.placement)
        }
    }

    /// One move at a time: each rewrites the positions around the moved
    /// row. The list after it, refused or not, settles the sidebar.
    private func reorder(_ label: String, _ ordered: [DeckSession], _ operation: @escaping @Sendable () async throws -> Void) {
        guard !isReordering else { return }
        isReordering = true
        sessions = ordered
        run(label, operation) {
            logger.info("\(label, privacy: .public) done")
        } finally: { [weak self] in
            await self?.refresh()
            self?.isReordering = false
        }
    }

    /// One action per session at a time; the list reloads after it, so the
    /// row changes even before the bus reports it. `done` runs once it
    /// succeeds, before the reload. A deleted session's pane goes with its
    /// tmux client, through `paneExited`, or with the list that no longer
    /// has it.
    private func lifecycle(
        _ label: String,
        _ session: DeckSession,
        _ operation: @escaping @Sendable () async throws -> Void,
        then done: (@MainActor () -> Void)? = nil
    ) {
        guard busySessionIDs.insert(session.id).inserted else { return }
        run(label, operation) { [weak self] in
            logger.info("\(label, privacy: .public) \(session.id, privacy: .public) done")
            done?()
            await self?.refresh()
        } finally: { [weak self] in
            self?.busySessionIDs.remove(session.id)
        }
    }

    func paneTitleChanged(sessionID: String, title: String) {
        guard case .attached(var attached)? = pane, attached.sessionID == sessionID else { return }
        attached.title = title
        pane = .attached(attached)
    }

    /// The tmux client ended. A Ctrl-Q detach or a stop closes the pane; the
    /// agent itself is untouched. An attach that ended at once found nothing
    /// to attach to, whatever the row said, so the pane offers to restart the
    /// session and the list catches up.
    func paneExited(sessionID: String, exit: ProcessExit) {
        guard pane?.attached?.sessionID == sessionID else { return }
        switch exit {
        case .normal:
            closePane()
            logger.info("pane for \(sessionID, privacy: .public) exited")
        case .abnormal:
            pane = .notRunning(sessionID: sessionID)
            logger.info("attach to \(sessionID, privacy: .public) ended at once")
            Task { await refresh() }
        }
    }

    private func closePane() {
        pane = nil
        if case .pane = selection { selection = nil }
    }

    private func run(
        _ label: String,
        _ operation: @escaping @Sendable () async throws -> Void,
        then follow: (@MainActor () async -> Void)? = nil,
        finally cleanup: (@MainActor () async -> Void)? = nil
    ) {
        lastError = nil
        Task {
            do {
                try await operation()
                await follow?()
            } catch {
                lastError = error.localizedDescription
                logger.error("\(label, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
            await cleanup?()
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
    /// The agent-deck path its sessions share; empty for "Ungrouped".
    var path: String { sessions.first?.group ?? "" }
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

/// The New Session dialog's starting values.
struct NewSessionPrompt: Identifiable {
    let id = UUID()
    /// A group's path; empty when nothing selected names a group.
    let groupPath: String
    let directory: String
    let command: String
}

/// What the pane shows for a session.
enum SessionPane {
    /// Its terminal.
    case attached(AttachedPane)
    /// Restart, while the session is not running.
    case notRunning(sessionID: String)

    var sessionID: String {
        switch self {
        case .attached(let attached): attached.sessionID
        case .notRunning(let sessionID): sessionID
        }
    }

    /// Nil while the session is not running.
    var attached: AttachedPane? {
        if case .attached(let attached) = self { attached } else { nil }
    }
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

extension SessionWindow {
    /// tmux names a window after its command, but a rename can clear it.
    var title: String {
        name.isEmpty ? "window \(index)" : name
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
