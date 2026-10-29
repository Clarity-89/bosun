import Foundation
import Testing
@testable import Bosun
@testable import BosunCore

private let grafana = RepoSlug(owner: "grafana", name: "grafana")
private let bosun = RepoSlug(owner: "Clarity-89", name: "bosun")
private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func issue(_ number: Int, in repo: RepoSlug = grafana) -> GitHubIssue {
    GitHubIssue(
        repo: repo, number: number, title: "Issue \(number)", url: IssueRef(repo: repo, number: number).url,
        author: nil, state: .open, labels: [], assignees: [], comments: 0, pullRequests: [], updatedAt: now
    )
}

private func pullRequest(closing: [GitHubIssue]) -> GitHubPullRequest {
    GitHubPullRequest(
        repo: grafana, number: 136272, title: "PR", url: URL(string: "https://github.com/grafana/grafana/pull/136272")!,
        author: nil, state: .open, headBranch: "alexk/homepage-remove-toggle", headRepo: grafana, baseBranch: "main",
        checks: nil, review: nil, hasConflicts: false, unresolvedThreads: 0, closingIssues: closing, updatedAt: now
    )
}

/// Which issue a session row names: yours over its pull request's over its
/// omp prompt's, so a link fixes a wrong guess and removing it brings the
/// guess back.
@Suite struct SessionIssueTests {
    let flag = issue(136268)
    let prompt = IssueRef(repo: bosun, number: 10)

    @Test func yourLinkWinsEvenBeforeGitHubDescribesIt() {
        let linked = IssueRef(repo: bosun, number: 16)
        let found = SessionGitHub.issue(linked: linked, pullRequest: pullRequest(closing: [flag]), prompt: prompt, known: [:])
        #expect(found?.ref == linked)
        #expect(found?.source == .linked)
        #expect(found?.issue == nil)
    }

    @Test func withoutALinkThePullRequestsIssueComesFirst() {
        let found = SessionGitHub.issue(linked: nil, pullRequest: pullRequest(closing: [flag]), prompt: prompt, known: [:])
        #expect(found == LinkedIssue(ref: flag.ref, issue: flag, source: .pullRequest))
    }

    @Test func thePromptIsTheLastGuess() {
        let described = issue(10, in: bosun)
        let found = SessionGitHub.issue(linked: nil, pullRequest: pullRequest(closing: []), prompt: prompt, known: [prompt: described])
        #expect(found == LinkedIssue(ref: prompt, issue: described, source: .prompt))
        #expect(SessionGitHub.issue(linked: nil, pullRequest: nil, prompt: nil, known: [:]) == nil)
    }

    /// `#12` typed for a fork's session means the upstream's issue.
    @Test func aForksIssuesAreItsUpstreams() {
        let upstream = RepoSlug(owner: "asheshgoplani", name: "agent-deck")
        let repo = GitRepoInfo(branch: "feat/x", defaultBranch: "main", repos: [RepoSlug(owner: "Clarity-89", name: "agent-deck"), upstream], unpushed: 1)
        #expect(SessionGitHub(repo: repo).issueRepo == upstream)
    }
}

/// The Inbox's lists, in the order they need you.
@Suite struct InboxListTests {
    static func section<Item>(_ items: [Item], total: Int) -> InboxSection<Item> { InboxSection(items: items, total: total) }

    /// An issue assigned to you that you also opened shows once, under
    /// Assigned, and the later list's count drops by it.
    @Test func anIssueShowsOnce() {
        let flag = issue(136268)
        let inbox = GitHubInbox(
            login: "Clarity-89",
            reviewRequests: Self.section([], total: 0),
            teamReviewRequests: Self.section([], total: 0),
            pullRequests: Self.section([pullRequest(closing: [flag])], total: 9),
            assignedIssues: Self.section([flag, issue(127458)], total: 4),
            openedIssues: Self.section([flag, issue(135595)], total: 44),
            mentions: Self.section([issue(127458), issue(1)], total: 6)
        )
        let sections = inbox.listSections
        #expect(sections.map(\.id) == [.reviews, .assigned, .mine, .teams, .opened, .mentions])
        let byID = Dictionary(uniqueKeysWithValues: sections.map { ($0.id, $0) })
        #expect(byID[.assigned]?.entries.map(\.id) == ["grafana/grafana#136268", "grafana/grafana#127458"])
        #expect(byID[.opened]?.entries.map(\.id) == ["grafana/grafana#135595"])
        #expect(byID[.opened]?.total == 43)
        #expect(byID[.mentions]?.entries.map(\.id) == ["grafana/grafana#1"])
        #expect(byID[.mentions]?.total == 5)
    }
}
