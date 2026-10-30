import BosunCore
import SwiftUI

/// The pull request from a session's branch, or the commits on a branch
/// without one that are not pushed yet; nothing for a branch with neither.
/// A placeholder of its size while Bosun has yet to read the folder or
/// GitHub to say.
struct BranchChip: View {
    let branch: SessionGitHub.Branch

    var body: some View {
        switch branch {
        case .loading:
            Text(verbatim: "#000000")
                .monospacedDigit()
                .chip()
                .modifier(LoadingPulse())
                // Redacted text is hidden from VoiceOver; a fresh element says what loads.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Loading pull request")
        case .none, .unpushed(_, nil), .unpushed(_, 0?):
            EmptyView()
        case .unpushed(let name, let commits?):
            Text(verbatim: "↑\(commits)")
                .monospacedDigit()
                .chip()
                .help("\(commits) commit\(commits == 1 ? "" : "s") on \(name) not pushed; no pull request")
        case .pullRequest(let pr):
            HStack(spacing: 3) {
                Image(systemName: pr.state.symbol).foregroundStyle(pr.state.color)
                Text(verbatim: "#\(pr.number)").monospacedDigit()
                if pr.state == .open || pr.state == .draft {
                    if let checks = pr.checks { Image(systemName: checks.symbol).foregroundStyle(checks.color) }
                    if pr.unresolvedThreads > 0 { Image(systemName: "bubble.left.fill").foregroundStyle(.orange) }
                }
            }
            .chip()
            .help("\(pr.state.label) pull request #\(pr.number): \(pr.title)")
        }
    }
}

private extension View {
    func chip() -> some View {
        font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.quaternary.opacity(0.6), in: .capsule)
    }
}

/// An issue as a row's subtitle names it: its state and number, the state
/// once GitHub describes it. Its title is in the row's tooltip.
struct IssueMark: View {
    let issue: LinkedIssue

    var body: some View {
        HStack(spacing: 3) {
            if case .issue(let described) = issue.answer {
                Image(systemName: described.state.symbol).foregroundStyle(described.state.color)
            }
            Text(verbatim: "#\(issue.ref.number)")
        }
    }
}

/// The selected session's issue and pull request, each opening on GitHub.
struct GitHubToolbarLinks: View {
    let github: SessionGitHub

    var body: some View {
        if let issue = github.issue {
            Button {
                GitHubLinks.open(issue.ref.url)
            } label: {
                Label {
                    Text(verbatim: "#\(issue.ref.number)")
                } icon: {
                    Image(systemName: (issue.issue?.state ?? .open).symbol)
                }
            }
            .labelStyle(.titleAndIcon)
            .help(issue.summary)
        }
        if let pr = github.branch.pullRequest {
            Button {
                GitHubLinks.open(pr.url)
            } label: {
                Label {
                    Text(verbatim: "#\(pr.number)")
                } icon: {
                    Image(systemName: pr.state.symbol)
                }
            }
            .labelStyle(.titleAndIcon)
            .help(pr.summary)
        }
    }
}
