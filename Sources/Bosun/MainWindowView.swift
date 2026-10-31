import BosunCore
import SwiftUI

@MainActor
struct MainWindowView: View {
    static let windowID = "main"

    @Bindable var model: DeckModel
    @FocusState private var sidebarFocused: Bool
    /// Monotonic; TerminalHost moves first responder into the pane on each new value.
    @State private var terminalFocusRequest = 0
    /// The session list's toolbar button and ⌃Q both hide and show it.
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    /// The Inbox row whose detail covers the terminals.
    @State private var inboxSelection: String?
    /// Whether the side terminals show beside the pane, while it has a
    /// session.
    @State private var sideTerminalsShown = false
    /// Kept across hiding and showing them.
    @State private var sideTerminalsWidth: CGFloat = 480
    @Environment(\.openWindow) private var openWindow
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            VStack(spacing: 0) {
                tabPicker
                switch model.tab {
                case .sessions:
                    sessionList
                case .inbox:
                    InboxSidebar(inbox: model.inbox, selection: $inboxSelection)
                        .focused($sidebarFocused)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                footer
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
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
        // The keyboard follows the shells as it follows the list: into the
        // top one as they show, back into the session's terminal as they
        // hide. A switch to another session's shells leaves it be.
        .onChange(of: sideTerminalsDirectory) { previous, directory in
            guard let directory else {
                if model.attachedPane != nil { terminalFocusRequest += 1 }
                return
            }
            model.sideTerminals.start(in: directory)
            if previous == nil { model.sideTerminals.panes[directory]?[0]?.focusTerminal() }
        }
        // Into the Inbox list, never left in a terminal out of sight. Back
        // in Sessions, Show Session puts it in the terminal.
        .onChange(of: model.tab) {
            guard model.tab == .inbox else { return }
            Task { sidebarFocused = true }
        }
        // The keyboard follows the list, as ⌃Q in the TUI goes back to its
        // list: into it as it shows, into the terminal as it hides.
        .onChange(of: columnVisibility) { _, visibility in
            if visibility == .detailOnly {
                if model.attachedPane != nil { terminalFocusRequest += 1 }
            } else {
                // The list takes focus once it is back in the window.
                Task { sidebarFocused = true }
            }
        }
        .onChange(of: model.revealRequests) {
            terminalFocusRequest += 1
        }
        .focusedSceneValue(\.sidebarFocused, Binding(get: { sidebarFocused }, set: { sidebarFocused = $0 }))
        .focusedSceneValue(\.terminalFocusRequest, model.attachedPane == nil || model.tab == .inbox ? nil : $terminalFocusRequest)
        .focusedSceneValue(\.sessionListVisibility, $columnVisibility)
        .focusedSceneValue(\.sideTerminalsShown, model.paneSession == nil ? nil : $sideTerminalsShown)
        .navigationTitle(titleText)
        .toolbar {
            if model.tab == .sessions, let selected = model.selectedSession {
                let github = model.inbox[selected]
                // The editor, then what to ask the agent for, then what it
                // has made: the order the work goes in.
                if let editor = CodeEditor.installed {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            model.open(selected, in: editor)
                        } label: {
                            Label { Text("Open in \(editor.name)") } icon: { Image(nsImage: editor.icon) }
                        }
                        .help("Open the session's directory in \(editor.name)")
                    }
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
                    GitHubToolbarLinks(github: github)
                }
                // In a grouping of their own, apart from the actions beside
                // them: they say what the session works on, they do nothing to it.
                .sharedBackgroundVisibility(.hidden)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if model.paneSession != nil {
                    Button {
                        sideTerminalsShown.toggle()
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

    /// Names what the pane shows, which a selected group row leaves as it was.
    private var titleText: String {
        if model.tab == .inbox { return "Inbox" }
        guard let shown = model.paneSession else { return "Bosun" }
        guard let title = model.attachedPane?.title, !title.isEmpty else { return shown.title }
        return "\(shown.title) · \(title)"
    }

    /// The directory whose shells show beside the pane: its session's,
    /// while they are wanted.
    private var sideTerminalsDirectory: String? {
        sideTerminalsShown ? model.paneSession?.path : nil
    }

    /// The sidebar's two lists, and Refresh, which reloads both.
    private var tabPicker: some View {
        HStack(spacing: 6) {
            Picker("List", selection: $model.tab) {
                Text("Sessions").tag(SidebarTab.sessions)
                Text("Inbox").tag(SidebarTab.inbox)
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

    private var sessionList: some View {
        let rows = sidebarRows
        return ScrollViewReader { proxy in
            List(selection: Binding(
                get: { model.selection },
                set: { model.select($0) }
            )) {
                // One flat list with one row per element, so a drag moves the row
                // it picked up: a group header takes its sessions along, a session
                // stays in its group, a window stays under its session.
                ForEach(rows) { row in
                    switch row {
                    case .group(let group, let expanded):
                        // A row, not a Section header, so arrows and Tab reach it as
                        // they reach a group in the TUI.
                        let deleteGroup: (() -> Void)? = model.canDeleteGroup(group)
                            ? { SessionPrompts.confirmDeleteGroup(group, model: model) } : nil
                        GroupRow(name: group.name, isExpanded: expanded, onDelete: deleteGroup) { animated { model.toggleGroup(group.name) } }
                            .tag(row.item)
                            .contextMenu {
                                Button("New Session…") { model.promptNewSession(inGroup: group.name) }
                                Button("Quick Session") { model.quickCreateSession(inGroup: group.name) }
                                if let deleteGroup {
                                    Divider()
                                    Button("Delete Group…", role: .destructive, action: deleteGroup)
                                }
                            }
                    case .session(let session):
                        SidebarSessionRow(model: model, session: session)
                            .tag(row.item)
                            .contextMenu { SessionActionItems(model: model, session: session) }
                    case .window(let window, let session):
                        WindowRow(window: window)
                            .tag(row.item)
                            .contextMenu {
                                Button("Close Window…", role: .destructive) {
                                    SessionPrompts.confirmClose(window, in: session, model: model)
                                }
                                .shortcut(.delete)
                            }
                            .moveDisabled(true)
                    }
                }
                .onMove { source, destination in
                    if let move = SidebarMove(rows: rows, from: source, to: destination) { model.move(move) }
                }
                // None of the List's own leading inset: the rows' hover plate
                // and drag handle hold room there.
                .listRowInsets(.leading, 0)
            }
            .listStyle(.sidebar)
            // Less of the sidebar's own margin around the rows, whose hover
            // plate and drag handle hold room of their own.
            .contentMargins(.horizontal, 4, for: .scrollContent)
            // Over the list, which has no rows yet, so selection, keys and
            // drags never meet a placeholder.
            .overlay(alignment: .topLeading) {
                if !model.hasLoadedSessions {
                    SessionListPlaceholder()
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: model.hasLoadedSessions)
            .focused($sidebarFocused)
            // Only the focused list sees these keys, so every letter still
            // reaches the terminal.
            .onKeyPress(keys: Shortcut.listKeys, phases: [.down, .repeat]) { press in
                guard let action = Shortcut.listAction(key: press.key, modifiers: press.modifiers) else { return .ignored }
                guard press.phase == .down || action.repeats else { return .handled }
                return perform(action, rows: rows, scroll: proxy)
            }
        }
    }

    /// The TUI's keys, on the selected row as the TUI's act on the row under
    /// its cursor. Return folds a group, or hands the keyboard to the
    /// attached terminal. Tab folds the selected group; on a session it folds
    /// the session's group and moves the selection up to it, so a second Tab
    /// opens the group again. The session actions do what the Session menu's
    /// items do, on the selected row's session. A key with nothing to do on
    /// the row is still handled, so the list never type-selects by it.
    private func perform(_ action: Shortcut, rows: [SidebarRow], scroll proxy: ScrollViewProxy) -> KeyPress.Result {
        // The session actions wait out an action in flight, as the menu items do.
        let session = model.selectedSession.flatMap { model.busySessions[$0.id] != nil ? nil : $0 }
        switch (action, model.selection) {
        case (.moveDown, let selection), (.moveUp, let selection):
            guard let row = SidebarRow.step(by: action == .moveDown ? 1 : -1, from: selection, in: rows) else { break }
            model.select(row.item)
            proxy.scrollTo(row.id)
        case (.reorderUp, let selection), (.reorderDown, let selection):
            guard let index = rows.firstIndex(where: { $0.item == selection }),
                  let move = SidebarMove(rows: rows, moving: index, up: action == .reorderUp) else { break }
            model.move(move)
        case (.toggleGroup, .group(let name)?), (.activate, .group(let name)?):
            animated { model.toggleGroup(name) }
        case (.foldGroup, .group(let name)?):
            animated { model.foldGroup(name) }
        case (.unfoldGroup, .group(let name)?):
            animated { model.unfoldGroup(name) }
        case (.toggleGroup, .pane?), (.foldGroup, .pane?):
            guard let group = model.selectedSession?.groupName else { break }
            animated { if action == .toggleGroup { model.toggleGroup(group) } else { model.foldGroup(group) } }
            model.select(.group(group))
        case (.activate, _):
            guard model.attachedPane != nil else { return .ignored }
            terminalFocusRequest += 1
        case (.newSession, _):
            model.promptNewSession()
        case (.quickSession, _):
            model.quickCreateSession()
        case (.cheatSheet, _):
            openWindow(id: ShortcutsView.windowID)
        case (.rename, _):
            if let session { SessionPrompts.rename(session, model: model) }
        case (.restart, _):
            if let session { model.restartSession(session) }
        case (.stop, _):
            if let session, session.status != .stopped { SessionPrompts.confirmStop(session, model: model) }
        case (.delete, .group(let name)?):
            if let group = model.groups.first(where: { $0.name == name }), model.canDeleteGroup(group) {
                SessionPrompts.confirmDeleteGroup(group, model: model)
            }
        case (.delete, _):
            guard let session else { break }
            if let window = model.selectedWindow {
                SessionPrompts.confirmClose(window, in: session, model: model)
            } else {
                SessionPrompts.confirmDelete(session, model: model)
            }
        case (.splitSideBySide, _):
            if let session { model.split(session, .sideBySide) }
        case (.openInGhostty, _):
            if let session { model.openInGhostty(session) }
        case (.worktreeSetup, _):
            if let session, session.worktreePath != nil { model.runWorktreeSetup(session) }
        case (.toggleGroup, nil), (.foldGroup, nil), (.unfoldGroup, _), (.toggleSessionList, _), (.toggleSideTerminals, _), (.focusTerminal, _), (.focusSidebar, _), (.settings, _):
            // Nothing to do on this row; the last five have no list key.
            break
        }
        return .handled
    }

    /// A fold, from the chevron and the keys alike.
    private func animated(_ change: () -> Void) {
        withAnimation(.easeOut(duration: 0.15), change)
    }

    /// Each group header, then, while it is open, its sessions, each with its
    /// extra windows under it.
    private var sidebarRows: [SidebarRow] {
        model.groups.flatMap { group in
            let expanded = !model.collapsedGroups.contains(group.name)
            return [SidebarRow.group(group, expanded: expanded)] + (expanded ? group.sessions : []).flatMap { session in
                [SidebarRow.session(session)] + model.extraWindows(for: session.id).map { SidebarRow.window($0, of: session) }
            }
        }
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
            .accessibilityHidden(model.tab == .inbox)
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
        guard let shown = model.attachedPane, model.tab == .sessions else { return nil }
        guard controlActiveState == .key else { return "Click to type here" }
        guard !shown.hasKeyboard else { return nil }
        // Return hands the keyboard over from the list; elsewhere only the menu shortcut does.
        let key = sidebarFocused ? Shortcut.activate.listKeyLabel : Shortcut.focusTerminal.menuLabel
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

/// A sidebar row: highlighted on hover, with the drag handle fading in at
/// the leading edge and Rename and Delete in a plate over the end of the
/// text, so the common actions need no context menu and nothing moves
/// when they show. The shells mark and the chip come after the text, so
/// the plate never covers them.
@MainActor
private struct SidebarSessionRow: View {
    let model: DeckModel
    let session: DeckSession
    @State private var isHovered = false

    var body: some View {
        let github = model.inbox[session]
        return HStack(spacing: 6) {
            DragHandle(isVisible: isHovered)
            SessionRow(session: session, attention: model.attention[session], github: github, action: model.busySessions[session.id])
                .overlay(alignment: .trailing) {
                    if isHovered {
                        HStack(spacing: 4) {
                            RowActionButton(systemImage: "pencil", help: "Rename (\(Shortcut.rename.listKeyLabel))") {
                                SessionPrompts.rename(session, model: model)
                            }
                            RowActionButton(systemImage: "trash", help: "Delete (\(Shortcut.delete.listKeyLabel))", destructive: true) {
                                SessionPrompts.confirmDelete(session, model: model)
                            }
                        }
                        .padding(2)
                        // Material reads over the hover plate and the selection alike.
                        .background(.regularMaterial, in: .rect(cornerRadius: 7))
                        .disabled(model.busySessions[session.id] != nil)
                        .transition(.opacity)
                    }
                }
            if model.sideTerminals.isBusy(in: session.path) {
                Image(systemName: "terminal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("A command runs in this session's side shells (\(Shortcut.toggleSideTerminals.menuLabel))")
            }
            BranchChip(branch: github.branch)
        }
        .modifier(SidebarHover(isHovered: $isHovered))
    }
}

/// A group header the selection can land on, with the handle that drags it
/// with its sessions, a chevron that folds it and, on hover, Delete.
private struct GroupRow: View {
    let name: String
    let isExpanded: Bool
    /// Nil for a group agent-deck will not delete.
    let onDelete: (() -> Void)?
    let toggle: () -> Void
    @State private var isHovered = false

    var body: some View {
        // With the 14 pt chevron, its centre under the session rows' dots.
        HStack(spacing: 3) {
            DragHandle(isVisible: isHovered)
            Button(action: toggle) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 14, height: 16)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("\(isExpanded ? "Collapse" : "Expand") (\(Shortcut.toggleGroup.listKeyLabel))")
            Text(name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        // Over the row, as on a session's, so the header keeps its height.
        .overlay(alignment: .trailing) {
            if isHovered, let onDelete {
                RowActionButton(systemImage: "trash", help: "Delete Group (\(Shortcut.delete.listKeyLabel))", destructive: true, action: onDelete)
                    .transition(.opacity)
            }
        }
        .modifier(SidebarHover(isHovered: $isHovered))
        .padding(.top, 1)
    }
}

/// The hover plate and pointing hand every sidebar row shares.
private struct SidebarHover: ViewModifier {
    @Binding var isHovered: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(.primary.opacity(isHovered ? 0.16 : 0), in: .rect(cornerRadius: 6))
            .contentShape(.rect)
            .onHover { isHovered = $0 }
            .pointerStyle(.link)
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

/// A borderless icon button with its own hover plate and the pointing hand,
/// like a link; a destructive one turns red under the pointer.
private struct RowActionButton: View {
    let systemImage: String
    let help: String
    var destructive = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isHovered ? (destructive ? Color.red : .primary) : .secondary)
        .background(.primary.opacity(isHovered ? 0.22 : 0), in: .rect(cornerRadius: 5))
        .onHover { isHovered = $0 }
        .pointerStyle(.link)
        .help(help)
    }
}

/// Bold with a ring round its status dot while something in the session is
/// unread; an open question turns the dot orange. The issue it works on
/// follows its status. While `action` runs, the subtitle names it beside a
/// bar that only moves, as agent-deck reports no progress; a session being
/// deleted fades. The text takes the room left in its row, so what a row
/// puts after it stays put.
struct SessionRow: View {
    let session: DeckSession
    let attention: SessionAttention
    let github: SessionGitHub
    var action: LifecycleAction?

    var body: some View {
        HStack(spacing: 8) {
            StatusBadge(status: session.status, asks: attention.asks, unread: attention.unread)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .fontWeight(attention.unread ? .semibold : nil)
                    .lineLimit(1)
                HStack(spacing: 3) {
                    if let action {
                        Text(action.progressLabel)
                        ProgressView()
                            .progressViewStyle(.linear)
                            .controlSize(.mini)
                            .frame(maxWidth: 80)
                            .padding(.leading, 3)
                    } else {
                        Text(subtitle).layoutPriority(1)
                        if let issue = github.issue {
                            Text("·")
                            IssueMark(issue: issue)
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // With the row's spacing, the gap a spacer kept before the chip.
            .padding(.trailing, 12)
        }
        .opacity(action == .delete ? 0.55 : 1)
        // The full text when the row is too narrow for it.
        .help(help)
        // What GitHub says about the issue fades in over its placeholder.
        .animation(.easeOut(duration: 0.25), value: github)
    }

    /// The dot alone says Running and Idle, so the row leaves those words to
    /// its tooltip; At prompt shares Idle's dot, and the rest differ by colour only.
    private var subtitle: String {
        describe(withStatus: session.status != .running && session.status != .idle)
    }

    /// The tool, then what needs you, else the status and its substate.
    private func describe(withStatus: Bool) -> String {
        let tool = session.tool.isEmpty ? "agent" : session.tool
        if let summary = attention.summary {
            return "\(tool) · \(summary)"
        }
        return [tool, withStatus ? session.status.label : nil, session.substate].compactMap { $0 }.joined(separator: " · ")
    }

    private var help: String {
        var lines = [session.title, describe(withStatus: true)]
        if let issue = github.issue {
            lines.append(issue.summary)
        }
        return lines.joined(separator: "\n")
    }
}

/// The grip that says a row can be dragged, with the open hand and a
/// tooltip, shown on hover. It keeps its room while hidden, so the row never
/// shifts; the whole row drags, not only the grip.
private struct DragHandle: View {
    /// The grip's own width: two dots and the gap between them.
    static let width: CGFloat = 7
    let isVisible: Bool

    var body: some View {
        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            ForEach(0..<3, id: \.self) { _ in
                GridRow {
                    Circle().frame(width: 2.5, height: 2.5)
                    Circle().frame(width: 2.5, height: 2.5)
                }
            }
        }
        .foregroundStyle(.tertiary)
        .frame(width: Self.width, height: 16)
        .contentShape(.rect)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .pointerStyle(.grabIdle)
        .help("Drag to reorder")
    }
}

/// An extra tmux window of a session, indented under its session row.
struct WindowRow: View {
    let window: SessionWindow

    var body: some View {
        HStack(spacing: 8) {
            // The session row's drag handle column, so the window stays
            // indented under the session.
            Color.clear.frame(width: DragHandle.width, height: 0)
            Image(systemName: "terminal")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(window.title)
                .lineLimit(1)
            Spacer()
            Text(window.command)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.leading, 16)
        .padding(.vertical, 1)
    }
}
