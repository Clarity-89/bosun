import AppKit
import BosunCore
import SwiftUI

extension PullRequestState {
    var symbol: String { self == .merged ? "arrow.triangle.merge" : "arrow.triangle.pull" }

    var color: Color {
        switch self {
        case .open: .green
        case .draft: .secondary
        case .merged: .purple
        case .closed: .red
        }
    }

    var label: String {
        switch self {
        case .open: "Open"
        case .draft: "Draft"
        case .merged: "Merged"
        case .closed: "Closed"
        }
    }
}

extension IssueState {
    var symbol: String {
        switch self {
        case .open: "smallcircle.filled.circle"
        case .completed: "checkmark.circle"
        case .notPlanned: "slash.circle"
        }
    }

    var color: Color {
        switch self {
        case .open: .green
        case .completed: .purple
        case .notPlanned: .secondary
        }
    }

    var label: String {
        switch self {
        case .open: "Open"
        case .completed: "Closed"
        case .notPlanned: "Not planned"
        }
    }
}

extension CheckState {
    var symbol: String {
        switch self {
        case .passing: "checkmark.circle.fill"
        case .failing: "xmark.circle.fill"
        case .pending: "clock.fill"
        }
    }

    var color: Color {
        switch self {
        case .passing: .green
        case .failing: .red
        case .pending: .yellow
        }
    }

    var label: String {
        switch self {
        case .passing: "Checks pass"
        case .failing: "Checks fail"
        case .pending: "Checks running"
        }
    }
}

extension ReviewDecision {
    var label: String {
        switch self {
        case .required: "Review required"
        case .approved: "Approved"
        case .changesRequested: "Changes requested"
        }
    }
}

extension GitHubPullRequest {
    /// `Open pull request #12: Title · Checks pass`, for a tooltip.
    var summary: String {
        "\(state.label) pull request #\(number): \(title)\(checks.map { " · \($0.label)" } ?? "")"
    }
}

extension LinkedIssue {
    /// `Issue #12: Title`, or the bare reference while GitHub has yet to
    /// describe it, for a tooltip.
    var summary: String {
        issue.map { "Issue #\($0.number): \($0.title)" } ?? "Issue \(ref)"
    }
}

/// `12m`, `3h`, `2d`, `5w`, `3mo`, `9y`: an age that fits a row.
enum ShortAge {
    static func text(since date: Date, now: Date = .now) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let minutes = Int(seconds / 60)
        let hours = minutes / 60
        let days = hours / 24
        return switch days {
        case 365...: "\(days / 365)y"
        case 30...: "\(days / 30)mo"
        case 7...: "\(days / 7)w"
        case 1...: "\(days)d"
        default: hours > 0 ? "\(hours)h" : "\(max(minutes, 1))m"
        }
    }
}

enum GitHubLinks {
    /// Only github.com pages: a URL from GitHub's answers, never another scheme.
    static func open(_ url: URL) {
        guard url.scheme == "https", url.host?.lowercased() == "github.com" else { return }
        NSWorkspace.shared.open(url)
    }

    static func copy(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
}
