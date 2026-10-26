import BosunCore
import SwiftUI

@MainActor
struct MenuView: View {
    let model: DeckModel

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
                Text(model.connection.label)
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
                if model.sessions.isEmpty {
                    ContentUnavailableView(
                        "No sessions",
                        systemImage: "rectangle.stack",
                        description: Text("No active agent-deck sessions")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 50)
                } else {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.sessions) { session in
                                SessionRow(session: session) {
                                    model.attach(session)
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
            if !model.statusEventsEnabled {
                Label("Live status events are off", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let error = model.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
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

    private var groups: [SessionGroup] {
        Dictionary(grouping: model.sessions) { session in
            let group = session.group?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return group.isEmpty ? "Ungrouped" : group
        }
        .map { SessionGroup(name: $0.key, sessions: $0.value) }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

private struct SessionGroup: Identifiable {
    let name: String
    let sessions: [DeckSession]
    var id: String { name }
}

private struct SessionRow: View {
    let session: DeckSession
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.body)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
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

    private var subtitle: String {
        let tool = session.tool?.isEmpty == false ? session.tool! : "agent"
        if let substate = session.substate, !substate.isEmpty {
            return "\(tool) · \(session.status.label) · \(substate)"
        }
        return "\(tool) · \(session.status.label)"
    }

    private var statusColor: Color {
        switch session.status {
        case .running: .blue
        case .waiting: .orange
        case .idle: .green
        case .error: .red
        case .stopped: .gray
        case .starting: .yellow
        case .unknown: .secondary
        }
    }
}
