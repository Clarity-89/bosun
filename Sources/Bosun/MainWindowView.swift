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
                        SessionRow(session: session)
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

struct SessionRow: View {
    let session: DeckSession

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(session.status.color)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
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
