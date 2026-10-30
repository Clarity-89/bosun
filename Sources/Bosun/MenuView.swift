import BosunCore
import SwiftUI

struct MenuView: View {
    let model: DeckModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            sessionList
            Divider()
            footer
        }
        .frame(width: 360, height: 460)
        .padding(.top, 8)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Bosun")
                    .font(.headline)
                Text(model.connectionLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if !model.hasLoadedSessions {
                    SessionListPlaceholder()
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                } else if model.sessions.isEmpty {
                    ContentUnavailableView(
                        "No sessions",
                        systemImage: "rectangle.stack",
                        description: Text("No active agent-deck sessions")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 50)
                } else {
                    ForEach(model.groups) { group in
                        Section {
                            ForEach(group.sessions) { session in
                                MenuSessionRow(session: session, attention: model.attention[session], github: model.inbox[session]) {
                                    openInWindow(session)
                                }
                            }
                        } header: {
                            Text(group.name)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.top, 8)
                                .padding(.bottom, 2)
                        }
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            StatusNotices(model: model)
                .font(.caption)
            HStack {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.isRefreshing)
                Spacer()
                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(10)
    }

    /// The menu bar is the quick list; selecting a row shows that session
    /// in the main window, at the pane that wants you, and brings it forward.
    private func openInWindow(_ session: DeckSession) {
        model.reveal(session)
        NSApp.activate()
        openWindow(id: MainWindowView.windowID)
    }
}

private struct MenuSessionRow: View {
    let session: DeckSession
    let attention: SessionAttention
    let github: SessionGitHub
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                SessionRow(session: session, attention: attention, github: github)
                Spacer(minLength: 4)
                Image(systemName: "terminal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

}
