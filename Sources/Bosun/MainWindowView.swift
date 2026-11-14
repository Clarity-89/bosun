import BosunCore
import SwiftUI

/// Where the sidebar holds the keyboard: its list, or the session search.
enum SidebarFocus {
    case list, search
}

@MainActor
struct MainWindowView: View {
    static let windowID = "main"

    @Bindable var model: DeckModel
    /// Nil while the keyboard is in a terminal, or out of the window.
    @FocusState private var sidebarFocus: SidebarFocus?
    /// Monotonic; TerminalHost moves first responder into the pane on each new value.
    @State private var terminalFocusRequest = 0
    /// What takes the keyboard once the hidden session list is back in the
    /// window; neither the list nor its search is in it until then.
    @State private var focusOnShow = SidebarFocus.list
    /// The session list's toolbar button and ⌃Q both hide and show it.
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    /// The Inbox row whose detail covers the terminals.
    @State private var inboxSelection: String?
    /// The sessions, by id, whose side terminals show beside the pane when
    /// it shows them. Each shows or hides its own, though sessions in one
    /// directory share the shells.
    @State private var sideTerminalSessions: Set<String> = []
    /// Kept across hiding and showing them.
    @State private var sideTerminalsWidth: CGFloat = 480
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            VStack(spacing: 0) {
                tabPicker
                switch model.tab {
                case .sessions:
                    SessionListView(model: model, list: model.sessionList, focus: $sidebarFocus, terminalFocusRequest: $terminalFocusRequest)
                case .inbox:
                    InboxSidebar(inbox: model.inbox, selection: $inboxSelection)
                        .focused($sidebarFocus, equals: .list)
                case .todos:
                    TodoPanel(todos: model.todos, agent: model.todoAgent)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                footer
            }
            // Wider on the To-dos, whose agent is a terminal.
            .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: model.tab == .todos ? 560 : 420)
        } detail: {
            HStack(spacing: 0) {
                detail
                    // The terminal's own floor. A floor on the window's root
                    // becomes the detail column's, and showing the list then
                    // widens the window by a list, off the screen if need be,
                    // instead of narrowing the terminal.
                    .frame(minWidth: 400)
                // Once the pair runs, so the shells' split view starts with
                // both and halves the height; a child added later keeps the
                // first one's size.
                if let directory = sideTerminalsDirectory, let panes = model.sideTerminals.panes[directory] {
                    SideTerminalsView(panes: panes, respawn: { model.sideTerminals.respawn($0, in: directory) }, width: $sideTerminalsWidth)
                }
            }
        }
        // The keyboard follows the list, as ⌃Q in the TUI goes back to its
        // list: into it as it shows, into the terminal as it hides.
        .onChange(of: columnVisibility) { _, visibility in
            if visibility == .detailOnly {
                if model.attachedPane != nil { terminalFocusRequest += 1 }
            } else {
                // Once the list is back in the window.
                Task {
                    sidebarFocus = focusOnShow
                    focusOnShow = .list
                }
            }
        }
        .onChange(of: model.revealRequests) {
            terminalFocusRequest += 1
        }
        // A closure, not `focusSidebar` itself: Swift 6.3's IRGen aborts on
        // the thunk for a main-actor method passed as a binding's setter.
        .focusedSceneValue(\.sidebarFocus, Binding(get: { sidebarFocus }, set: { focusSidebar($0) }))
        // The menu's Go to Sessions, Inbox and To-dos.
        .focusedSceneValue(\.sidebarTab, Binding(get: { model.tab }, set: { show($0) }))
        .focusedSceneValue(\.terminalFocusRequest, model.attachedPane == nil || model.tab.coversPane ? nil : $terminalFocusRequest)
        .focusedSceneValue(\.sessionListVisibility, $columnVisibility)
        .focusedSceneValue(\.sideTerminalsShown, model.paneSession == nil ? nil : Binding(get: { sideTerminalsShown }, set: { shown in
            if shown != sideTerminalsShown { toggleSideTerminals() }
        }))
        .navigationTitle(titleText)
        .toolbar {
            if !model.tab.coversPane, let selected = model.selectedSession {
                let github = model.inbox[selected]
                // The editor, then what to ask the agent for, then what it
                // has made: the order the work goes in.
                ToolbarItem(placement: .primaryAction) {
                    CodeEditorButton(
                        help: { "Open the session's directory in \($0.name)" },
                        open: { model.open(selected, in: $0) }
                    )
                }
                // A stopped session has no agent to ask.
                if selected.status != .stopped {
                    ToolbarItemGroup(placement: .primaryAction) {
                        ForEach(AgentRequest.requests(for: github.branch.pullRequest), id: \.self) { request in
                            Button(request.title) { model.ask(request, of: selected) }
                                .help(request.help)
                        }
                        .disabled(model.busySessions[selected.id] != nil)
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if let changes = model.workTree[selected.path], !changes.isEmpty {
                        WorkTreeMark(changes: changes)
                    }
                    GitHubToolbarLinks(github: github)
                }
                // In a grouping of their own, apart from the actions beside
                // them: they say what the session works on, they do nothing to it.
                .sharedBackgroundVisibility(.hidden)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if model.paneSession != nil {
                    Button {
                        toggleSideTerminals()
                    } label: {
                        Label("Shells", systemImage: "terminal")
                    }
                    .help((sideTerminalsShown ? "Hide the session's two shells" : "Show two shells in the session's directory") + " (\(Shortcut.toggleSideTerminals.menuLabel))")
                }
                Button {
                    model.promptNewSession()
                } label: {
                    Label("New Session", systemImage: "plus")
                }
                .help("New session in the selected group (\(Shortcut.newSession.menuLabel))")
                if let selected = model.selectedSession {
                    Menu {
                        ShellActionItems(model: model, session: selected)
                    } label: {
                        Label("Open Shell Here", systemImage: "plus.rectangle.on.rectangle")
                    }
                    .help("New shell window or split in this session")
                }
            }
        }
        .sheet(item: Binding(get: { model.newSessionPrompt }, set: { if $0 == nil { model.dismissNewSession() } })) { prompt in
            NewSessionSheet(model: model, prompt: prompt)
        }
    }

    /// Shows or hides the shown session's shells. The keyboard follows them
    /// as it follows the list: into the top one as they show, back into the
    /// session's terminal as they hide.
    private func toggleSideTerminals() {
        guard let session = model.paneSession else { return }
        if sideTerminalSessions.remove(session.id) != nil {
            if model.attachedPane != nil { terminalFocusRequest += 1 }
            return
        }
        sideTerminalSessions.insert(session.id)
        model.sideTerminals.start(in: session.path)
        model.sideTerminals.panes[session.path]?[0]?.focusTerminal()
    }

    /// A tab chosen, in the picker or by its shortcut, which brings a hidden
    /// sidebar back. The keyboard goes into the list shown, never left in a
    /// terminal out of sight under the Inbox, or into the to-do agent, there
    /// to be asked; Show Session puts it back in the terminal.
    private func show(_ tab: SidebarTab) {
        model.tab = tab
        if columnVisibility == .detailOnly { columnVisibility = .all }
        switch tab {
        case .sessions, .inbox: Task { sidebarFocus = .list }
        case .todos: model.todoAgent.focus()
        }
    }

    /// The menu bar's side of `sidebarFocus`, for Focus Sidebar and Filter
    /// Sessions: a hidden list comes back first, and the search lies under
    /// the Sessions tab.
    private func focusSidebar(_ target: SidebarFocus?) {
        if target == .search { model.tab = .sessions }
        if let target, columnVisibility == .detailOnly {
            focusOnShow = target
            columnVisibility = .all
        } else {
            // Once the Sessions tab, and with it the search, is in the window.
            Task { sidebarFocus = target }
        }
    }

    /// Names what the pane shows, which a selected group row leaves as it was.
    private var titleText: String {
        if model.tab == .inbox { return "Inbox" }
        guard let shown = model.paneSession else { return "Bosun" }
        guard let title = model.attachedPane?.title, !title.isEmpty else { return shown.title }
        return "\(shown.title) · \(title)"
    }

    /// Whether the session the pane shows has its shells shown.
    private var sideTerminalsShown: Bool {
        model.paneSession.map { sideTerminalSessions.contains($0.id) } ?? false
    }

    /// The directory whose shells show beside the pane: its session's,
    /// while that session has them shown.
    private var sideTerminalsDirectory: String? {
        sideTerminalsShown ? model.paneSession?.path : nil
    }

    /// The sidebar's three lists, and Refresh, which reloads the sessions and GitHub.
    private var tabPicker: some View {
        HStack(spacing: 6) {
            Picker("List", selection: Binding(get: { model.tab }, set: { show($0) })) {
                Text("Sessions").tag(SidebarTab.sessions)
                Text("Inbox").tag(SidebarTab.inbox)
                Text("To-dos").tag(SidebarTab.todos)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Button {
                Task { await model.refreshAll() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Refresh sessions and GitHub")
            .disabled(model.isRefreshing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// Every live pane stays in the view tree, hidden unless shown, so its
    /// tmux client outlives a switch and showing it again is instant. The
    /// terminal being opened shows a spinner; a session without one, Restart.
    /// Over a shown terminal, `keyboardHint` says when typing would miss it.
    private var detail: some View {
        let shown = model.attachedPane?.id
        return ZStack {
            Group {
                ForEach(model.livePanes) { live in
                    TerminalHost(launch: live.launch, isShown: live.id == shown, focusRequest: terminalFocusRequest) { title in
                        model.paneTitleChanged(paneID: live.id, title: title)
                    } onInput: {
                        model.paneReceivedInput(paneID: live.id)
                    } onExit: { exit in
                        model.paneExited(paneID: live.id, exit: exit)
                    } onFocusChange: { focused in
                        model.paneFocusChanged(paneID: live.id, focused: focused)
                    }
                }
                KeyboardElsewhereHint(message: keyboardHint)
                if shown == nil {
                    if model.isAttaching {
                        ProgressView()
                    } else if let session = model.paneSession {
                        NotRunningPane(model: model, session: session)
                    } else {
                        ContentUnavailableView(
                            "Select a session",
                            systemImage: "rectangle.stack",
                            description: Text(model.engineError ?? "The session attaches here, inside Bosun.")
                        )
                    }
                }
            }
            // Out of sight under the Inbox, so out of VoiceOver's reach too.
            .accessibilityHidden(model.tab.coversPane)
            // Over the terminals, which stay in the tree, so their tmux
            // clients live on while the Inbox shows.
            if model.tab == .inbox {
                InboxDetail(inbox: model.inbox, entryID: inboxSelection) { model.reveal($0) }
            }
        }
    }

    /// Why typing would not reach the shown terminal, and how to type in it;
    /// nil while it would. The first click on a window in the background only
    /// brings it forward, so the keyboard then stays where it was.
    private var keyboardHint: String? {
        guard let shown = model.attachedPane, !model.tab.coversPane else { return nil }
        guard controlActiveState == .key else { return "Click to type here" }
        guard !shown.hasKeyboard else { return nil }
        // Return hands the keyboard over from the list; elsewhere only the menu shortcut does.
        let key = sidebarFocus == .list ? Shortcut.activate.listKeyLabel : Shortcut.focusTerminal.menuLabel
        return "Press \(key) or click to type here"
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            StatusNotices(model: model)
            Text(model.connectionLabel).foregroundStyle(.secondary)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.bar)
    }
}

/// Over a shown terminal that typing would miss: a dimmed pane and how to
/// type in it. Clicks pass through, so a click lands in the terminal and
/// gives it the keyboard, as it always has.
private struct KeyboardElsewhereHint: View {
    let message: String?

    var body: some View {
        ZStack {
            if let message {
                Color.black.opacity(0.35)
                Label(message, systemImage: "keyboard")
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: .capsule)
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.15), value: message)
    }
}

/// The pane of a session that is not running: Restart, which also starts a
/// stopped session.
@MainActor
private struct NotRunningPane: View {
    let model: DeckModel
    let session: DeckSession

    var body: some View {
        let busy = model.busySessions[session.id] != nil
        ContentUnavailableView {
            Label(session.title, systemImage: "stop.circle")
        } description: {
            Text("The session is not running.")
        } actions: {
            HStack {
                Button("Restart") { model.restartSession(session) }
                if busy { ProgressView().controlSize(.small) }
            }
            .disabled(busy)
        }
    }
}
