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

/// The selected session's issue and pull request, each opening on GitHub,
/// the icon in its state's colour as on the session's row.
struct GitHubToolbarLinks: View {
    let github: SessionGitHub

    var body: some View {
        if let issue = github.issue {
            let state = issue.issue?.state ?? .open
            // Uncoloured until GitHub describes it.
            ToolbarLink(symbol: state.symbol, color: issue.issue == nil ? .secondary : state.color,
                        number: issue.ref.number, help: issue.summary, url: issue.ref.url)
        }
        if let pr = github.branch.pullRequest {
            ToolbarLink(symbol: pr.state.symbol, color: pr.state.color, number: pr.number, help: pr.summary, url: pr.url)
        }
    }
}

/// Looks like a link, not a button: no hover plate, which sat badly beside
/// the toolbar's glass, but the pointing hand and an underline under the
/// pointer.
private struct ToolbarLink: View {
    let symbol: String
    let color: Color
    let number: Int
    let help: String
    let url: URL
    @State private var isHovered = false

    var body: some View {
        Button {
            GitHubLinks.open(url)
        } label: {
            Label {
                Text(verbatim: "#\(number)").underline(isHovered)
            } icon: {
                Image(systemName: symbol).foregroundStyle(color)
            }
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { isHovered = $0 }
        .help(help)
    }
}
