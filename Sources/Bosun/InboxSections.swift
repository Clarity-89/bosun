import BosunCore

/// The Inbox's lists, what needs you first.
enum InboxSectionID: String, CaseIterable {
    case reviews, assigned, mine, teams, opened, mentions

    var title: String {
        switch self {
        case .reviews: "Review requested"
        case .assigned: "Assigned to you"
        case .mine: "Your pull requests"
        case .teams: "Your teams' review requests"
        case .opened: "Issues you opened"
        case .mentions: "Mentions"
        }
    }

    /// The long ones that rarely need you.
    static let foldedByDefault: Set<InboxSectionID> = [.teams, .opened, .mentions]
}

enum InboxEntry: Identifiable, Equatable {
    case pullRequest(GitHubPullRequest)
    case issue(GitHubIssue)

    /// Unique across both: a repository numbers its issues and pull
    /// requests from one sequence.
    var id: String {
        switch self {
        case .pullRequest(let pr): pr.id
        case .issue(let issue): issue.id
        }
    }
}

struct InboxListSection: Identifiable, Equatable {
    let id: InboxSectionID
    let entries: [InboxEntry]
    /// What GitHub counted, less the rows an earlier section already has.
    let total: Int
}

extension GitHubInbox {
    /// An issue shows once: one assigned to you is not listed again as
    /// opened by you or mentioning you.
    var listSections: [InboxListSection] {
        var shown = Set<String>()
        func issueSection(_ id: InboxSectionID, _ section: InboxSection<GitHubIssue>) -> InboxListSection {
            let fresh = section.items.filter { shown.insert($0.id).inserted }
            let repeated = section.items.count - fresh.count
            return InboxListSection(id: id, entries: fresh.map(InboxEntry.issue), total: max(section.total - repeated, fresh.count))
        }
        func pullRequestSection(_ id: InboxSectionID, _ section: InboxSection<GitHubPullRequest>) -> InboxListSection {
            InboxListSection(id: id, entries: section.items.map(InboxEntry.pullRequest), total: section.total)
        }
        return [
            pullRequestSection(.reviews, reviewRequests),
            issueSection(.assigned, assignedIssues),
            pullRequestSection(.mine, pullRequests),
            pullRequestSection(.teams, teamReviewRequests),
            issueSection(.opened, openedIssues),
            issueSection(.mentions, mentions),
        ]
    }

    func entry(id: String) -> InboxEntry? {
        listSections.lazy.flatMap(\.entries).first { $0.id == id }
    }
}
