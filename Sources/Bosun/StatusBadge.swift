import BosunCore
import SwiftUI

/// A session's status dot. Idle is hollow: the agent has nothing to do, and
/// a filled green dot read as a session busy or doing well.
struct StatusBadge: View {
    let status: SessionStatus

    var body: some View {
        Group {
            if status == .idle {
                Circle().strokeBorder(.secondary, lineWidth: 1.5)
            } else {
                Circle().fill(fill)
            }
        }
        .frame(width: 8, height: 8)
    }

    private var fill: Color {
        switch status {
        case .running: .blue
        case .waiting: .orange
        case .error: .red
        case .stopped: .gray
        case .starting: .yellow
        case .queued: .indigo
        case .idle, .unknown: .secondary
        }
    }
}
