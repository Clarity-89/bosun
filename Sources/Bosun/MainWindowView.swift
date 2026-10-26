import BosunCore
import BosunTerminal
import SwiftUI

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
        model.sessions.first { $0.id == model.selectedSessionID }
    }

    private var titleText: String {
        guard let selected else { return "Bosun" }
        let terminalTitle = model.terminalTitles[selected.id] ?? ""
        return terminalTitle.isEmpty ? selected.title : "\(selected.title) · \(terminalTitle)"
    }

    private var sidebar: some View {
        List(selection: Binding(
            get: { model.selectedSessionID },
            set: { model.select($0) }
        )) {
            ForEach(model.groups) { group in
                Section(group.name) {
                    ForEach(group.sessions) { session in
                        SessionRow(session: session)
                            .tag(session.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay(alignment: .bottom) {
            footer
        }
    }

    private var detail: some View {
        TerminalHost(key: model.terminalKey) { sessionID, title in
            model.terminalTitleChanged(sessionID: sessionID, title: title)
        } onExit: { sessionID in
            model.terminalExited(sessionID: sessionID)
        }
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
