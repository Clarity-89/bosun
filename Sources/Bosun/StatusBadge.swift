import BosunCore
import SwiftUI

/// A session's status dot. Idle is hollow: the agent has nothing to do, and
/// a filled green dot read as a session busy or doing well. Waiting is
/// hollow too, as it means only that the agent is at its prompt; the row's
/// unread look says whether you saw what it did. Orange is a question that
/// waits for you.
struct StatusBadge: View {
    let status: SessionStatus
    var asks = false

    var body: some View {
        Group {
            if asks {
                Circle().fill(.orange)
            } else if status == .idle || status == .waiting {
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
        case .error: .red
        case .stopped: .gray
        case .starting: .yellow
        case .queued: .indigo
        case .idle, .waiting, .unknown: .secondary
        }
    }
}
