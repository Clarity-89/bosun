import BosunCore
import BosunTerminal
import SwiftUI

/// What the pane shows: a session, optionally one of its tmux windows.
struct PaneTarget: Hashable {
    let sessionID: String
    let windowIndex: Int?

    init(sessionID: String, windowIndex: Int? = nil) {
        self.sessionID = sessionID
        self.windowIndex = windowIndex
    }
}

@MainActor
struct MainWindowView: View {
    @Bindable var model: DeckModel

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
        } detail: {
            detail
        }
        .navigationTitle(titleText)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let selected {
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

    private var selected: DeckSession? {
        guard let id = model.selection?.sessionID else { return nil }
        return model.sessions.first { $0.id == id }
    }

    private var titleText: String {
        guard let selected else { return "Bosun" }
        let terminalTitle = model.terminalTitles[selected.id] ?? ""
        return terminalTitle.isEmpty ? selected.title : "\(selected.title) · \(terminalTitle)"
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
                        // Window 0 is the agent itself; only extra windows get rows.
                        ForEach(model.windows(for: session.id).filter { $0.index != 0 }) { window in
                            WindowRow(window: window)
                                .tag(PaneTarget(sessionID: session.id, windowIndex: window.index))
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
        .overlay(alignment: .bottom) {
            footer
        }
    }

    @ViewBuilder
    private func sessionMenu(for session: DeckSession) -> some View {
        shellActions(for: session)
        Divider()
        Button("Open in Ghostty") { model.openInGhostty(session) }
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

    private var detail: some View {
        TerminalHost(key: model.terminalKey) { sessionID, title in
            model.terminalTitleChanged(sessionID: sessionID, title: title)
        } onExit: { sessionID in
            model.terminalExited(sessionID: sessionID)
        }
        .background(Color.black)
        .overlay {
            // The host stays mounted; only this placeholder toggles.
            if model.terminalKey == nil {
                ContentUnavailableView(
                    "Select a session",
                    systemImage: "rectangle.stack",
                    description: Text(TerminalPane.engineError ?? "The session attaches here, inside Bosun.")
                )
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !model.statusEventsEnabled {
                Label("Live status events are off", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if let error = model.lastError {
                Text(error).foregroundStyle(.red).lineLimit(2)
            }
            Text(model.connection.label).foregroundStyle(.secondary)
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
