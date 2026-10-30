import BosunCore
import SwiftUI

/// A session's status dot. Idle is hollow: the agent has nothing to do, and
/// a filled green dot read as a session busy or doing well. Waiting is
/// hollow too, as it means only that the agent is at its prompt; the ring
/// says whether you saw what it did. Orange is a question that waits for
/// you. The ring is in the text colour, as an accent-coloured mark read as
/// Running's blue dot.
struct StatusBadge: View {
    let status: SessionStatus
    var asks = false
    var unread = false

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
        // Outside the dot's frame, so a row's layout is the same read or unread.
        .overlay {
            if unread {
                Circle()
                    .strokeBorder(.primary, lineWidth: 1.5)
                    .frame(width: 14, height: 14)
                    .accessibilityLabel("Unread")
            }
        }
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
