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
    /// What `list` reports and the sidebar hides; deleting a group takes
    /// them too.
    private var archivedSessions: [DeckSession] = []
    /// False until the first `list` answers, or startup fails before one:
    /// the session lists show placeholder rows until then, and an empty
    /// list after it means there are no sessions.
    private(set) var hasLoadedSessions = false
    private(set) var connection: ConnectionState = .starting
    private var statusEventsEnabled = false
    /// Who publishes status transitions; nil until known, with the bus off,
    /// or from an agent-deck too old to say.
    private var statusOwner: StatusOwner?
    private(set) var lastError: String?
    private(set) var selection: SidebarItem? {
        // A session selected while the search hides it, from a notification
        // or as a new session, ends the search, so its row shows.
        didSet {
            guard case .pane(let target)? = selection, sidebarFilter.hasQuery,
                  let session = sessions.first(where: { $0.id == target.sessionID }),
                  !session.matches(sidebarFilter.trimmedQuery) else { return }
            sidebarFilter.query = ""
        }
    }
    /// The sidebar's list. The Inbox covers the terminals: what they show
    /// is neither seen nor spared its notifications meanwhile.
    var tab = SidebarTab(rawValue: UserDefaults.standard.string(forKey: "sidebarTab") ?? "") ?? .sessions {
        didSet {
            guard tab != oldValue else { return }
            UserDefaults.standard.set(tab.rawValue, forKey: "sidebarTab")
            attention.paneCovered(tab == .inbox)
            if tab == .inbox { inbox.refreshIfStale() }
        }
    }
    /// The session the pane shows: its terminal while `recent` has one,
    /// nothing while `attachingSessionIDs` has it, else Restart.
    private(set) var shownSessionID: String?
    /// Five terminals stay attached, so switching back to a recent session
    /// shows it at once; each costs a tmux client and a hidden surface.
    private var recent = RecentPanes(limit: 5)
    /// What wants you, by Bosun's own count.
    let attention = AttentionCenter()
    /// GitHub: the Inbox tab, and each session's branch, pull request and issue.
    let inbox = InboxCenter()
    /// Two shells in each session's directory, beside its terminal.
    let sideTerminals = SideTerminals()
    /// Counts notification clicks, so the window puts the keyboard in the
    /// terminal of the session shown.
    private(set) var revealRequests = 0
    /// Sessions whose terminal is being opened.
    private(set) var attachingSessionIDs: Set<String> = []
    /// Nil once libghostty is running; otherwise what the pane shows instead.
    private(set) var engineError: String?
    private(set) var windowsBySession: [String: [SessionWindow]] = [:]
    /// Sessions with a lifecycle action in flight, and which; their actions
    /// wait for it, and their rows say what runs.
    private(set) var busySessions: [String: LifecycleAction] = [:]
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
    /// The session list's search, Open filter and sort. The search starts
    /// empty each launch, as the TUI's does; the other two are kept.
    var sidebarFilter = SidebarFilter(
        openOnly: UserDefaults.standard.bool(forKey: "sidebarOpenOnly"),
        byRecent: UserDefaults.standard.bool(forKey: "sidebarByRecent")
    ) {
        didSet {
            guard sidebarFilter.openOnly != oldValue.openOnly || sidebarFilter.byRecent != oldValue.byRecent else { return }
            UserDefaults.standard.set(sidebarFilter.openOnly, forKey: "sidebarOpenOnly")
            UserDefaults.standard.set(sidebarFilter.byRecent, forKey: "sidebarByRecent")
        }
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
    /// True once a `list` succeeded, so `sessions` is real; a failure leaves
    /// `hasLoadedSessions` true with nothing in it.
    @ObservationIgnored private var hasListed = false
    @ObservationIgnored private var agentPanePollTask: Task<Void, Never>?
    @ObservationIgnored private var pendingReveal: (sessionID: String, windowID: String?)?
    /// The session a reveal put in the pane before it had a terminal; the
    /// keyboard goes into the terminal once its attach lands.
    @ObservationIgnored private var focusOnAttach: String?

    private init() {
        // A turn is when an agent pushes, or opens or merges a pull request;
        // the 5 min round would show it late.
        attention.onTurnEnd = { [inbox] session in inbox.recheck(session) }
    }

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
        guard let shownSessionID else { return nil }
        return sessions.first { $0.id == shownSessionID }
    }

    /// Every attached terminal, shown or kept for a quick switch back.
    var livePanes: [AttachedPane] { recent.panes }

    /// The terminal the pane shows; nil while it shows Restart or nothing.
    var attachedPane: AttachedPane? {
        shownSessionID.flatMap(recent.pane(for:))
    }

    /// Whether the pane is opening the shown session's terminal.
    var isAttaching: Bool {
        shownSessionID.map(attachingSessionIDs.contains) ?? false
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

    func foldGroup(_ name: String) {
        collapsedGroups.insert(name)
    }

    func unfoldGroup(_ name: String) {
        collapsedGroups.remove(name)
    }

    func start() {
        guard !started else { return }
        started = true
        attention.paneCovered(tab == .inbox)
        do {
            try GhosttyAppController.shared.start()
        } catch {
            engineError = error.localizedDescription
            logger.error("libghostty failed to start: \(error.localizedDescription, privacy: .public)")
        }
        Task { await bootstrap() }
    }

    func stop() {
        for task in [followerTask, reconcileTask, delayedRefreshTask, refreshTask, installTask, agentPanePollTask] {
            task?.cancel()
        }
        attention.stop()
        inbox.stop()
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

    /// The session list and GitHub, together.
    func refreshAll() async {
        async let list: Void = refresh()
        await inbox.refresh()
        await list
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
            shownChanged()
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

    /// Opens the session's directory in the code editor. agent-deck lists
    /// every session with a path, so an empty one is agent-deck's own bug.
    func open(_ session: DeckSession, in editor: CodeEditor) {
        run("open in \(editor.name)") {
            guard !session.path.isEmpty else {
                throw AgentDeckCLIError.reported("“\(session.title)” has no directory")
            }
            try await editor.open(directory: session.path)
        }
    }

    private func loadSessions() async {
        do {
            // Without the group order (a failed `group list`) the last one
            // still keeps each group's rows together.
            async let listed = cli.list()
            async let groupOrder = cli.groups()
            let all = try await listed
            if let groups = try? await groupOrder {
                deckGroups = groups
            }
            let previous = hasListed ? sessions : nil
            archivedSessions = all.filter(\.archived)
            sessions = DeckSession.inDeckOrder(all.filter { !$0.archived }, groupPaths: deckGroups.map(\.path))
            hasLoadedSessions = true
            hasListed = true
            lastError = nil
            logger.info("list loaded \(self.sessions.count, privacy: .public) sessions")
            attention.listed(sessions, previous: previous)
            inbox.listed(sessions)
            sideTerminals.listed(sessions)
            inbox.start()
            dropStalePanes(loneViews: await cli.loneViews())
            await loadAllWindows()
            if let (sessionID, windowID) = pendingReveal {
                pendingReveal = nil
                reveal(sessionID: sessionID, windowID: windowID)
            }
        } catch is CancellationError {
        } catch {
            hasLoadedSessions = true
            lastError = error.localizedDescription
            logger.error("list failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Shows the target in the pane. A session shown lately is still
    /// attached and shows at once. Otherwise a new tmux client attaches, on
    /// Bosun's own view of the session, so the agent keeps running when the
    /// pane goes away. A stopped session gets Restart instead, as its attach
    /// would exit at once. Every other status attaches: `error` can be an
    /// agent that is alive but blocked, and an attach that finds nothing
    /// restarts the session through `paneExited`. A group row leaves the
    /// pane as it is.
    func select(_ item: SidebarItem?) {
        selection = item
        guard let item else {
            show(nil)
            return
        }
        guard case .pane(let target) = item else { return }
        show(target.sessionID)
        if let live = recent.touch(target.sessionID) {
            showWindow(target.windowID, in: live)
        } else if sessions.first(where: { $0.id == target.sessionID })?.status != .stopped {
            attach(target, restartsIfDead: true)
        }
        shownChanged()
    }

    /// Changes the session the pane shows. The terminal leaving yields its
    /// window's size while hidden.
    private func show(_ sessionID: String?) {
        guard sessionID != shownSessionID else { return }
        focusOnAttach = nil
        if let hidden = attachedPane { yieldSize(of: hidden) }
        shownSessionID = sessionID
        shownChanged()
    }

    /// Attention hears what the pane shows: after a selection, a shown
    /// session, or the window list changing.
    private func shownChanged() {
        attention.shown(sessionID: shownSessionID, windowID: shownWindowID)
    }

    /// The window the pane shows: the selected window row's, else the
    /// session's first, where its agent runs; nil until the windows are
    /// listed.
    private var shownWindowID: String? {
        guard let shownSessionID else { return nil }
        if case .pane(let target)? = selection, target.sessionID == shownSessionID, let windowID = target.windowID {
            return windowID
        }
        return windowsBySession[shownSessionID]?.first?.windowID
    }

    /// A window row's window, or the agent's for the session row, selected
    /// in the pane's view so no other client moves. Without a view a window
    /// row moves the session's current window for every client, as the
    /// TUI's window rows do.
    private func showWindow(_ windowID: String?, in live: AttachedPane) {
        if let view = live.view {
            run("select window") { [cli] in try await cli.selectWindow(windowID, inView: view) } then: { [weak self] in
                await self?.settleSize(of: live)
            }
        } else if let windowID {
            run("select window") { [cli] in try await cli.selectWindow(windowID: windowID) }
        }
    }

    /// The shown pane sizes its window unless someone else is on it; then
    /// it leaves the size alone until you type or click in it.
    private func settleSize(of live: AttachedPane) async {
        guard let view = live.view else { return }
        let yields = await cli.someoneElseOnWindow(ofView: view)
        guard attachedPane?.id == live.id else { return }
        recent.update(live.id) { $0.yieldsSize = yields }
        await cli.setSizesWindow(!yields, view: view)
    }

    private func yieldSize(of hidden: AttachedPane) {
        guard let view = hidden.view else { return }
        recent.update(hidden.id) { $0.yieldsSize = true }
        Task { [cli] in await cli.setSizesWindow(false, view: view) }
    }

    /// Typing or clicking in a pane makes it the client used last, so it
    /// takes its window's size, as agent-deck's `window-size latest` has it.
    func paneReceivedInput(paneID: UUID) {
        guard let pane = recent.pane(id: paneID), pane.yieldsSize, let view = pane.view else { return }
        recent.update(paneID) { $0.yieldsSize = false }
        Task { [cli] in await cli.setSizesWindow(true, view: view) }
    }

    /// Opens a terminal for the target's session, which the pane shows
    /// meanwhile, and keeps it with the recent ones, unless the pane moved
    /// on while tmux answered. `restartsIfDead` goes on the pane.
    private func attach(_ target: PaneTarget, restartsIfDead: Bool = false) {
        guard let binary else {
            lastError = "agent-deck is still starting"
            return
        }
        let sessionID = target.sessionID
        guard attachingSessionIDs.insert(sessionID).inserted else { return }
        let tmuxSession = sessions.first { $0.id == sessionID }?.tmuxSession
        Task {
            let live = await openPane(sessionID: sessionID, tmuxSession: tmuxSession, window: target.windowID, binary: binary, restartsIfDead: restartsIfDead)
            attachingSessionIDs.remove(sessionID)
            guard shownSessionID == sessionID else {
                end(live)
                return
            }
            for leaving in recent.add(live) {
                end(leaving)
            }
            if focusOnAttach == sessionID {
                focusOnAttach = nil
                revealRequests += 1
            }
            if case .pane(let now)? = selection, now.sessionID == sessionID, now.windowID != target.windowID {
                showWindow(now.windowID, in: live)
            }
            logger.info("attached \(sessionID, privacy: .public) in window, view \(live.view ?? "none", privacy: .public)")
            await loadAllWindows()
        }
    }

    /// A view grouped with the session, showing the target's window before
    /// the client attaches, and attaching with `ignore-size` when someone
    /// else is on that window. A session tmux's default server does not have
    /// attaches through agent-deck instead, which knows its socket; so does
    /// every session on a tmux older than 3.2.
    private func openPane(sessionID: String, tmuxSession: String?, window: String?, binary: AgentDeckBinary, restartsIfDead: Bool) async -> AttachedPane {
        let id = UUID()
        if let tmuxSession {
            let view = ViewSession.name(paneID: id)
            do {
                try await cli.createView(view, grouping: tmuxSession)
                try? await cli.selectWindow(window, inView: view)
                let yields = await cli.someoneElseOnWindow(ofView: view)
                let launch = try cli.viewAttachLaunch(view, yieldsSize: yields)
                return AttachedPane(id: id, sessionID: sessionID, view: view, launch: launch, yieldsSize: yields, restartsIfDead: restartsIfDead)
            } catch {
                await cli.killView(view)
                logger.info("no view of \(tmuxSession, privacy: .public), attaching through agent-deck: \(error.localizedDescription, privacy: .public)")
            }
        }
        if let window {
            try? await cli.selectWindow(windowID: window)
        }
        return AttachedPane(
            id: id, sessionID: sessionID, view: nil, launch: binary.attachLaunch(sessionID: sessionID), yieldsSize: false,
            restartsIfDead: restartsIfDead
        )
    }

    /// Its terminal goes with it once it leaves `recent`; the view would
    /// otherwise hold on to windows agent-deck has let go.
    private func end(_ pane: AttachedPane) {
        guard let view = pane.view else { return }
        Task { [cli] in await cli.killView(view) }
    }

    /// Ends the panes whose session went away or stopped, and the views tmux
    /// reports alone in their group. The pane closes with a session the
    /// list no longer has, offers Restart for a stopped one, and attaches
    /// one agent-deck recreated again.
    private func dropStalePanes(loneViews: Set<String> = []) {
        let stale = recent.removeStale(given: sessions, loneViews: loneViews)
        stale.forEach(end)
        guard let shownSessionID else { return }
        guard let session = sessions.first(where: { $0.id == shownSessionID }) else {
            closePane()
            return
        }
        if session.status != .stopped, stale.contains(where: { $0.sessionID == shownSessionID }) {
            attach(PaneTarget(sessionID: shownSessionID))
        }
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
    /// says why, as it does for a worktree setup hook that did not run.
    func createSession(_ request: NewSessionRequest) async throws {
        let added = try await cli.addSession(request)
        let sessionID = added.id
        UserDefaults.standard.set(request.command.trimmingCharacters(in: .whitespaces), forKey: Self.lastCommandKey)
        logger.info("created \(sessionID, privacy: .public)")
        if let notice = added.setupHookNotice {
            logger.notice("\(sessionID, privacy: .public): \(notice, privacy: .public)")
        }
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
        show(sessionID)
        if let startError {
            lastError = startError
        } else {
            attach(PaneTarget(sessionID: sessionID))
        }
        // After the reload, which clears the footer; a start that failed
        // is the bigger news, and a hook you asked to skip is none.
        if let notice = added.setupHookNotice, request.runsWorktreeSetup, lastError == nil {
            lastError = notice
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

    /// "Open shell here" as a new tmux window in the session's directory,
    /// shown in Bosun's view while other clients stay on their window.
    func newShellWindow(in session: DeckSession) {
        guard let target = shellTarget(session) else { return }
        run("new window") { [cli] in
            try await cli.newShellWindow(tmuxSession: target, workingDirectory: session.path)
        } then: { [weak self] in
            await self?.loadAllWindows()
        }
    }

    /// "Open shell here" as a split of the window Bosun shows.
    func split(_ session: DeckSession, _ direction: SplitDirection) {
        guard let target = shellTarget(session) else { return }
        run("split") { [cli] in
            try await cli.splitShellPane(tmuxSession: target, direction: direction, workingDirectory: session.path)
        }
    }

    /// Types the request into the session's agent, which carries it out as
    /// it would one you typed. A session that never had a tmux server has
    /// no agent to ask; one whose server is gone fails in tmux.
    func ask(_ request: AgentRequest, of session: DeckSession) {
        run(request.command) { [cli] in
            guard let tmuxSession = session.tmuxSession else {
                throw AgentDeckCLIError.reported("“\(session.title)” has no agent to ask")
            }
            try await cli.typeIntoAgent(request.command, tmuxSession: tmuxSession)
        }
    }

    /// The session's view when Bosun has one, whose current window is the
    /// one Bosun shows; else agent-deck's session.
    private func shellTarget(_ session: DeckSession) -> String? {
        recent.pane(for: session.id)?.view ?? session.tmuxSession
    }

    func closeWindow(_ window: SessionWindow, in session: DeckSession) {
        run("close window") { [cli] in
            try await cli.closeWindow(sessionID: session.id, windowID: window.windowID)
        } then: { [weak self] in
            await self?.loadAllWindows()
        }
    }

    func stopSession(_ session: DeckSession) {
        lifecycle(.stop, on: [session.id]) { [cli] in try await cli.stopSession(id: session.id) }
    }

    /// Restart also starts a stopped session; a pane offering it attaches
    /// what it started.
    func restartSession(_ session: DeckSession) {
        lifecycle(.restart, on: [session.id], { [cli] in try await cli.restartSession(id: session.id) }) { [weak self] in
            if let self, self.shownSessionID == session.id, self.attachedPane == nil { self.attach(PaneTarget(sessionID: session.id)) }
        }
    }

    /// Runs the repository's worktree setup script again in the session's
    /// worktree, as b does in the TUI; the row says so meanwhile.
    func runWorktreeSetup(_ session: DeckSession) {
        lifecycle(.setup, on: [session.id]) { [cli] in try await cli.runWorktreeSetup(sessionID: session.id) }
    }

    func renameSession(_ session: DeckSession, to title: String) {
        lifecycle(.rename, on: [session.id]) { [cli] in try await cli.renameSession(id: session.id, to: title) }
    }

    func deleteSession(_ session: DeckSession) {
        lifecycle(.delete, on: [session.id]) { [cli] in try await cli.deleteSession(id: session.id) }
    }

    /// Delete for every session in the group and its subgroups, archived
    /// ones included, one at a time, each a write to agent-deck's store;
    /// then the group. A failure stops it there, and the list that follows
    /// shows what is left, still in its group.
    func deleteGroup(_ group: SessionGroup) {
        guard group.isDeletable else { return }
        let doomed = sessions(inGroupTree: group.path)
        lifecycle(.delete, on: Set(doomed.map(\.id)), { [cli] in
            for session in doomed { try await cli.deleteSession(id: session.id) }
            try await cli.deleteGroup(path: group.path)
        }) { [weak self] in
            self?.collapsedGroups.remove(group.name)
        }
    }

    /// Whether Delete Group can run now: not on a group agent-deck will not
    /// delete, nor while an action runs on a session it would delete.
    func canDeleteGroup(_ group: SessionGroup) -> Bool {
        group.isDeletable && !sessions(inGroupTree: group.path).contains { busySessions[$0.id] != nil }
    }

    /// Every session agent-deck lists in the group at `path` or one of its
    /// subgroups, archived ones included: what deleting the group deletes.
    func sessions(inGroupTree path: String) -> [DeckSession] {
        (sessions + archivedSessions).filter { $0.isIn(groupTree: path) }
    }

    /// A row moved by drag or by key. The rows reorder at once; agent-deck
    /// then stores the order, and the list that follows confirms it or,
    /// after a refusal, puts it back. A group moves with its sessions.
    func move(_ move: SidebarMove) {
        switch move {
        case .session(let move):
            // Sorted by activity, a row's neighbours are not agent-deck's, so
            // a place beside them means nothing there.
            guard !sidebarFilter.byRecent else { return }
            reorder("move \(move.sessionID)", DeckSession.reordering(sessions, within: move.order)) { [cli] in
                try await cli.moveSession(id: move.sessionID, move.placement)
            }
        case .group(let move):
            reorder("move group \(move.path)", DeckSession.inDeckOrder(sessions, groupPaths: move.order)) { [cli] in
                try await cli.moveGroup(path: move.path, move.placement)
            }
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

    /// One action at a time on each of `ids`; they stay busy until the list
    /// after it, refused or failed part way alike, so their rows change
    /// before the bus reports it and never flip back before they go. `done`
    /// runs once it succeeds, after the reload, so it sees the session as
    /// agent-deck now lists it: a restart gives it a new tmux session. A
    /// deleted session's pane goes with its tmux client, through
    /// `paneExited`, or with the list that no longer has it.
    private func lifecycle(
        _ action: LifecycleAction,
        on ids: Set<String>,
        _ operation: @escaping @Sendable () async throws -> Void,
        then done: (@MainActor () -> Void)? = nil
    ) {
        guard ids.allSatisfy({ busySessions[$0] == nil }) else { return }
        for id in ids { busySessions[id] = action }
        let label = "\(action.rawValue) \(ids.sorted().joined(separator: " "))"
        var succeeded = false
        run(label, operation) {
            logger.info("\(label, privacy: .public) done")
            succeeded = true
        } finally: { [weak self] in
            await self?.refresh()
            for id in ids { self?.busySessions[id] = nil }
            if succeeded { done?() }
        }
    }

    func paneTitleChanged(paneID: UUID, title: String) {
        recent.update(paneID) { $0.title = title }
    }

    func paneFocusChanged(paneID: UUID, focused: Bool) {
        recent.update(paneID) { $0.hasKeyboard = focused }
    }

    /// The tmux client ended. A tmux detach or a stop closes the pane; the
    /// agent itself is untouched. An attach that ended at once found nothing
    /// to attach to, whatever the row said: a session you switched to
    /// restarts, one attached after a restart or a recreate offers Restart,
    /// and the list catches up. A hidden pane just goes.
    func paneExited(paneID: UUID, exit: ProcessExit) {
        guard let ended = recent.remove(paneID) else { return }
        end(ended)
        guard shownSessionID == ended.sessionID else { return }
        switch exit {
        case .normal:
            closePane()
            logger.info("pane for \(ended.sessionID, privacy: .public) exited")
        case .abnormal:
            logger.info("attach to \(ended.sessionID, privacy: .public) ended at once")
            if ended.restartsIfDead, let session = sessions.first(where: { $0.id == ended.sessionID }), session.status != .stopped {
                restartSession(session)
            }
            Task { await refresh() }
        }
    }

    private func closePane() {
        show(nil)
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
            await cli.killOrphanViews()
            statusEventsEnabled = try await cli.statusEventsEnabled()
            // Cursor before the list: anything published in between is
            // replayed onto the fresh list instead of being missed.
            let stats = try await cli.eventsStats()
            await refresh()
            startReconcileLoop()
            startAgentPanePoll()
            record(stats)
            if stats.enabled {
                startFollower(after: stats.cursor)
            } else {
                connection = .unavailable
                lastError = "The event bus is disabled; statuses refresh every 60 s"
            }
        } catch {
            hasLoadedSessions = true
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
        // Against the row, not the frame's `from`: a list can report a change
        // first. After a reboot the first list finds every session dead
        // before agent-deck's status pass publishes it.
        let from = sessions[index].status
        guard change.to != from else { return }
        sessions[index].status = change.to
        // The bus carries no substate, and the old one described the previous status.
        sessions[index].substate = nil
        logger.info("status \(frame.sessionID, privacy: .public) -> \(change.to.rawValue, privacy: .public)")
        attention.statusChanged(sessions[index], from: from, to: change.to)
        if change.to == .stopped { dropStalePanes() }
    }

    // MARK: Attention

    /// omp's pane titles every 2 s: when its turns end and when it asks.
    private func startAgentPanePoll() {
        agentPanePollTask?.cancel()
        agentPanePollTask = Task {
            while !Task.isCancelled {
                if let panes = await cli.listAgentPanes() {
                    attention.panesPolled(panes, sessions: sessions)
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// A notification's click, or Show Session: the session, in the window
    /// of the pane that wants you, with the keyboard in its terminal once
    /// there is one.
    func reveal(sessionID: String, windowID: String?) {
        // A click that launched Bosun arrives before the first list.
        guard hasListed else {
            pendingReveal = (sessionID, windowID)
            return
        }
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        tab = .sessions
        unfoldGroup(session.groupName)
        let first = windowsBySession[sessionID]?.first?.windowID
        select(.pane(PaneTarget(sessionID: sessionID, windowID: windowID == first ? nil : windowID)))
        if attachedPane != nil {
            revealRequests += 1
        } else {
            focusOnAttach = sessionID
        }
    }

    /// A menu bar row's click: the session, at the pane that wants you.
    func reveal(_ session: DeckSession) {
        reveal(sessionID: session.id, windowID: attention.window(for: session.id))
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
