import BosunCore
import SwiftUI

@MainActor
struct MainWindowView: View {
    @Bindable var model: DeckModel
    @FocusState private var sidebarFocused: Bool
    /// Monotonic; TerminalHost moves first responder into the pane on each new value.
    @State private var terminalFocusRequest = 0

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
        } detail: {
            detail
        }
        .focusedSceneValue(\.sidebarFocused, Binding(get: { sidebarFocused }, set: { sidebarFocused = $0 }))
        .focusedSceneValue(\.terminalFocusRequest, model.pane == nil ? nil : $terminalFocusRequest)
        .navigationTitle(titleText)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let selected = model.selectedSession {
                    Menu {
                        shellActions(for: selected)
                    } label: {
                        Label("Open Shell Here", systemImage: "plus.rectangle.on.rectangle")
                    }
                    .help("New shell window or split in this session")
                    Button {
                        model.openInGhostty(selected)
                    } label: {
                        Label("Open in Ghostty", systemImage: "macwindow.on.rectangle")
                    }
                    .help("Open this session in a separate Ghostty window")
                }
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshing)
            }
        }
    }

    private var titleText: String {
        guard let selected = model.selectedSession else { return "Bosun" }
        guard let pane = model.pane, pane.sessionID == selected.id, !pane.title.isEmpty else { return selected.title }
        return "\(selected.title) · \(pane.title)"
    }

    private var sidebar: some View {
        List(selection: Binding(
            get: { model.selection },
            set: { model.select($0) }
        )) {
            ForEach(model.groups) { group in
                Section(group.name) {
                    ForEach(group.sessions) { session in
                        SidebarSessionRow(model: model, session: session)
                            .tag(PaneTarget(sessionID: session.id))
                            .contextMenu { sessionMenu(for: session) }
                        ForEach(model.extraWindows(for: session.id)) { window in
                            WindowRow(window: window)
                                .tag(PaneTarget(sessionID: session.id, windowID: window.windowID))
                                .contextMenu {
                                    Button("Close Window", role: .destructive) {
                                        model.closeWindow(window, in: session)
                                    }
                                }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .focused($sidebarFocused)
        // Arrow keys keep navigating the list; Return hands the keyboard to
        // the attached terminal.
        .onKeyPress(.return) {
            guard model.pane != nil else { return .ignored }
            terminalFocusRequest += 1
            return .handled
        }
        // The TUI's keys, d to delete and r to rename. Only the focused list
        // sees them, so every letter still reaches the terminal.
        .onKeyPress(keys: ["d", "r"]) { press in
            guard press.modifiers.isEmpty,
                  model.selection?.windowID == nil,
                  let session = model.selectedSession,
                  !model.busySessionIDs.contains(session.id)
            else { return .ignored }
            if press.key == "d" {
                SessionPrompts.confirmDelete(session, model: model)
            } else {
                SessionPrompts.rename(session, model: model)
            }
            return .handled
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footer
        }
    }

    @ViewBuilder
    private func sessionMenu(for session: DeckSession) -> some View {
        shellActions(for: session)
        Divider()
        Button("Open in Ghostty") { model.openInGhostty(session) }
        Divider()
        SessionActionItems(model: model, session: session)
    }

    /// The TUI's "open shell here" choices: a new window, or a split of
    /// the active window, each with `$SHELL` in the session's directory.
    @ViewBuilder
    private func shellActions(for session: DeckSession) -> some View {
        Button {
            model.newShellWindow(in: session)
        } label: {
            Label("New Shell Window", systemImage: "plus.rectangle")
        }
        Button {
            model.split(session, .sideBySide)
        } label: {
            Label("Split Side by Side", systemImage: "rectangle.split.2x1")
        }
        Button {
            model.split(session, .topAndBottom)
        } label: {
            Label("Split Top and Bottom", systemImage: "rectangle.split.1x2")
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let pane = model.pane {
            TerminalHost(launch: pane.launch, focusRequest: terminalFocusRequest) { title in
                model.paneTitleChanged(sessionID: pane.sessionID, title: title)
            } onExit: {
                model.paneExited(sessionID: pane.sessionID)
            }
            .id(pane.sessionID)
        } else {
            ContentUnavailableView(
                "Select a session",
                systemImage: "rectangle.stack",
                description: Text(model.engineError ?? "The session attaches here, inside Bosun.")
            )
        }
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

/// A sidebar row: highlighted on hover, with Rename and Delete fading in at
/// the trailing edge so the common actions need no context menu. They take
/// room only while shown, so the subtitle uses the full width otherwise.
@MainActor
private struct SidebarSessionRow: View {
    let model: DeckModel
    let session: DeckSession
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            SessionRow(session: session)
            Spacer(minLength: 0)
            if isHovered {
                HStack(spacing: 4) {
                    RowActionButton(systemImage: "pencil", help: "Rename (r)") {
                        SessionPrompts.rename(session, model: model)
                    }
                    RowActionButton(systemImage: "trash", help: "Delete (d)", destructive: true) {
                        SessionPrompts.confirmDelete(session, model: model)
                    }
                }
                .disabled(model.busySessionIDs.contains(session.id))
                .transition(.opacity)
            }
        }
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
        .foregroundStyle(isHovered ? (destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary)) : AnyShapeStyle(.secondary))
        .background(.primary.opacity(isHovered ? 0.22 : 0), in: .rect(cornerRadius: 5))
        .onHover { isHovered = $0 }
        .pointerStyle(.link)
        .help(help)
    }
}

struct SessionRow: View {
    let session: DeckSession

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(session.status.color)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        // The full text when the row is too narrow for it.
        .help("\(session.title)\n\(subtitle)")
    }

    private var subtitle: String {
        let tool = session.tool.isEmpty ? "agent" : session.tool
        if let substate = session.substate {
            return "\(tool) · \(session.status.label) · \(substate)"
        }
        return "\(tool) · \(session.status.label)"
    }
}

/// An extra tmux window of a session, indented under its session row.
struct WindowRow: View {
    let window: SessionWindow

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(window.name.isEmpty ? "window \(window.index)" : window.name)
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

extension SessionStatus {
    var color: Color {
        switch self {
        case .running: .blue
        case .waiting: .orange
        case .idle: .green
        case .error: .red
        case .stopped: .gray
        case .starting: .yellow
        case .queued: .indigo
        case .unknown: .secondary
        }
    }
}
