import BosunCore
import SwiftUI

/// The sidebar's session list: the TUI's search, Open filter and the sort
/// over the rows, the rows themselves, and the TUI's keys on the selected
/// row.
@MainActor
struct SessionListView: View {
    let model: DeckModel
    /// The list's folds and filter, bound to from the filter bar.
    @Bindable var list: SessionList
    /// The sidebar's keyboard, which the window hands out from the menu bar
    /// as well.
    var focus: FocusState<SidebarFocus?>.Binding
    @Binding var terminalFocusRequest: Int
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let rows = model.sidebarRows
        filterBar(rows: rows)
        list(rows: rows)
    }

    private func filterBar(rows: [SidebarRow]) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter Sessions", text: $list.filter.query, prompt: Text("Title, path or tool"))
                    .textFieldStyle(.plain)
                    .focused(focus, equals: .search)
                    // The first match, as Return in the TUI's search opens it,
                    // with the keyboard left in the list for j, k and Return.
                    .onSubmit {
                        if let first = rows.first(where: { if case .session = $0 { true } else { false } }) {
                            model.select(first.item)
                        }
                        focus.wrappedValue = .list
                    }
                    .onExitCommand {
                        list.filter.query = ""
                        focus.wrappedValue = .list
                    }
                if !list.filter.query.isEmpty {
                    Button {
                        list.filter.query = ""
                    } label: {
                        Label("Clear", systemImage: "xmark.circle.fill")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Clear the search (esc)")
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(.quaternary, in: .rect(cornerRadius: 6))
            Menu {
                Toggle("Hide Error and Stopped Sessions", isOn: $list.filter.openOnly)
                Picker("Sort By", selection: $list.filter.sort) {
                    Text("Default Order").tag(SidebarSort.deck)
                    Text("Last Activity").tag(SidebarSort.activity)
                }
                .pickerStyle(.inline)
            } label: {
                // Filled while the list leaves sessions out or reorders them.
                let changed = list.filter.openOnly || list.filter.sort != .deck
                Label("Filter and Sort", systemImage: changed ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .labelStyle(.iconOnly)
            .fixedSize()
            .help("Hide error and stopped sessions, or list every session by last activity")
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private func list(rows: [SidebarRow]) -> some View {
        ScrollViewReader { proxy in
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
                        GroupRow(name: group.name, isExpanded: expanded, foldable: list.filter.allowsFolding, onDelete: deleteGroup) {
                            animated { list.toggleGroup(group.name) }
                        }
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
                        SidebarSessionRow(model: model, session: session, draggable: list.filter.allowsReordering)
                            .tag(row.item)
                            .contextMenu { SessionActionItems(model: model, session: session) }
                            .moveDisabled(!list.filter.allowsReordering)
                    case .window(let window, let session):
                        WindowRow(window: window)
                            .tag(row.item)
                            .contextMenu { WindowActionItems(model: model, session: session, window: window) }
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
            // Only a filter can empty a list that has sessions.
            .overlay {
                if model.hasLoadedSessions, rows.isEmpty, !model.sessions.isEmpty {
                    Group {
                        if list.filter.hasQuery {
                            ContentUnavailableView.search(text: list.filter.trimmedQuery)
                        } else {
                            ContentUnavailableView("No Open Sessions", systemImage: "line.3.horizontal.decrease.circle", description: Text("Every session is stopped or reports an error."))
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
            .focused(focus, equals: .list)
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
            animated { list.toggleGroup(name) }
        case (.foldGroup, .group(let name)?):
            animated { list.foldGroup(name) }
        case (.unfoldGroup, .group(let name)?):
            animated { list.unfoldGroup(name) }
        case (.toggleGroup, .pane?), (.foldGroup, .pane?):
            // The selection only moves up to a header the fold leaves in the list.
            guard list.filter.allowsFolding, let group = model.selectedSession?.groupName else { break }
            animated { if action == .toggleGroup { list.toggleGroup(group) } else { list.foldGroup(group) } }
            model.select(.group(group))
        case (.activate, _):
            guard model.attachedPane != nil else { return .ignored }
            terminalFocusRequest += 1
        case (.newSession, _):
            model.promptNewSession()
        case (.quickSession, _):
            model.quickCreateSession()
        case (.search, _):
            focus.wrappedValue = .search
        case (.cheatSheet, _):
            openWindow(id: ShortcutsView.windowID)
        case (.rename, _):
            guard let session else { break }
            if let window = model.selectedWindow {
                SessionPrompts.renameWindow(window, model: model)
            } else {
                SessionPrompts.rename(session, model: model)
            }
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
    let draggable: Bool
    @State private var isHovered = false

    var body: some View {
        let github = model.inbox[session]
        return HStack(spacing: 6) {
            DragHandle(isVisible: isHovered && draggable)
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
    /// False while the list holds every group open.
    let foldable: Bool
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
            .disabled(!foldable)
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
private struct WindowRow: View {
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
