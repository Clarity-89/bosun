import Foundation
import Testing
@testable import Bosun
@testable import BosunCore

private let octo = RepoSlug(owner: "octo-org", name: "octo-repo")
private let bosun = RepoSlug(owner: "Clarity-89", name: "bosun")
private let branch = BranchRef(branch: "me/feature", repos: [octo])
private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func session(_ id: String, path: String = "/p") -> DeckSession {
    DeckSession(id: id, title: id, path: path, group: "g", tool: "omp", status: .idle, substate: nil, tmuxSession: nil, archived: false, lastActivityAt: nil)
}

private func issue(_ number: Int, in repo: RepoSlug = octo) -> GitHubIssue {
    GitHubIssue(
        repo: repo, number: number, title: "Issue \(number)", url: IssueRef(repo: repo, number: number).url,
        author: nil, state: .open, labels: [], assignees: [], comments: 0, pullRequests: [], updatedAt: now
    )
}

private func pullRequest(closing: [GitHubIssue] = []) -> GitHubPullRequest {
    GitHubPullRequest(
        repo: octo, number: 136272, title: "PR", url: URL(string: "https://github.com/octo-org/octo-repo/pull/136272")!,
        author: nil, state: .open, headBranch: branch.branch, headRepo: octo, baseBranch: "main",
        checks: nil, review: nil, hasConflicts: false, unresolvedThreads: 0, closingIssues: closing, updatedAt: now
    )
}

/// A folder on `branch`, pushed to `repos`.
private func folder(prompt: IssueRef? = nil, repos: [RepoSlug] = [octo], unpushed: Int? = 2) -> InboxState.Folder {
    InboxState.Folder(repo: GitRepoInfo(branch: branch.branch, defaultBranch: "main", repos: repos, unpushed: unpushed), prompt: prompt)
}

/// Which issue a session row names: yours over its pull request's over its
/// omp prompt's, so a link fixes a wrong guess and removing it brings the
/// guess back.
@Suite struct SessionIssueTests {
    let flag = issue(136268)
    let prompt = IssueRef(repo: bosun, number: 10)
    let worker = session("s1")

    /// The folder read, with a prompt, and GitHub's answer for its branch.
    func state(pullRequest: GitHubPullRequest?) -> InboxState {
        var state = InboxState()
        state.folders["/p"] = folder(prompt: prompt)
        state.pullRequests.updateValue(pullRequest, forKey: branch)
        return state
    }

    @Test func yourLinkWinsEvenBeforeGitHubDescribesIt() {
        var state = state(pullRequest: pullRequest(closing: [flag]))
        let linked = IssueRef(repo: bosun, number: 16)
        state.links[worker.id] = linked
        #expect(state.github(for: worker).issue == LinkedIssue(ref: linked, source: .linked, answer: .pending))
    }

    @Test func withoutALinkThePullRequestsIssueComesFirst() {
        let state = state(pullRequest: pullRequest(closing: [flag]))
        #expect(state.github(for: worker).issue == LinkedIssue(ref: flag.ref, source: .pullRequest, answer: .issue(flag)))
    }

    @Test func thePromptIsTheLastGuess() {
        var state = state(pullRequest: pullRequest())
        #expect(state.github(for: worker).issue == LinkedIssue(ref: prompt, source: .prompt, answer: .pending))
        state.received(issues: [nil], for: [prompt])
        #expect(state.github(for: worker).issue?.answer == .missing)
        let described = issue(10, in: bosun)
        state.received(issues: [described], for: [prompt])
        #expect(state.github(for: worker).issue == LinkedIssue(ref: prompt, source: .prompt, answer: .issue(described)))
    }

    @Test func aSessionNamingNothingHasNoIssue() {
        var state = InboxState()
        state.folders["/p"] = folder()
        #expect(state.github(for: worker).issue == nil)
    }

    /// The Inbox's issues, and the ones its pull requests close, need no
    /// second request: a prompt naming one is described at once.
    @Test func theInboxDescribesWhatItBrought() {
        var state = InboxState()
        state.folders["/p"] = folder(prompt: flag.ref)
        state.received(GitHubInbox(
            reviewRequests: .empty, teamReviewRequests: .empty,
            pullRequests: InboxSection(items: [pullRequest(closing: [flag])], total: 1),
            assignedIssues: .empty, openedIssues: .empty, mentions: .empty
        ))
        #expect(state.github(for: worker).issue?.answer == .issue(flag))
    }

    /// `#12` typed for a fork's session means the upstream's issue.
    @Test func aForksIssuesAreItsUpstreams() {
        let upstream = RepoSlug(owner: "asheshgoplani", name: "agent-deck")
        var state = InboxState()
        state.folders["/p"] = folder(repos: [RepoSlug(owner: "Clarity-89", name: "agent-deck"), upstream])
        #expect(state.github(for: worker).issueRepo == upstream)
    }
}

/// What a session row's chip shows for its branch, as Bosun reads the
/// folder and GitHub answers.
@Suite struct SessionBranchTests {
    let worker = session("s1")

    @Test func loadsUntilTheFolderIsReadAndGitHubAnswers() {
        var state = InboxState()
        #expect(state.github(for: worker).branch == .loading)
        state.folders["/p"] = folder()
        #expect(state.github(for: worker).branch == .loading)
        #expect(state.branches == [branch])
        state.received(pullRequests: [branch: []])
        #expect(state.github(for: worker).branch == .unpushed(branch: branch.branch, commits: 2))
        let pr = pullRequest()
        state.received(pullRequests: [branch: [pr]])
        #expect(state.github(for: worker).branch == .pullRequest(pr))
    }

    @Test func nothingToShowOnTheDefaultBranchOrOutsideARepository() {
        var state = InboxState()
        state.folders["/p"] = InboxState.Folder(repo: GitRepoInfo(branch: "main", defaultBranch: "main", repos: [octo], unpushed: nil), prompt: nil)
        #expect(state.github(for: worker).branch == .none)
        state.folders["/p"] = InboxState.Folder(repo: nil, prompt: nil)
        #expect(state.github(for: worker).branch == .none)
        #expect(state.branches.isEmpty)
    }

    /// Without a github.com remote there is nobody to ask: the bare branch
    /// shows at once.
    @Test func aBranchWithNoRemoteNeedsNoAnswer() {
        var state = InboxState()
        state.folders["/p"] = folder(repos: [], unpushed: 3)
        #expect(state.github(for: worker).branch == .unpushed(branch: branch.branch, commits: 3))
        #expect(state.branches.isEmpty)
    }

    /// A request GitHub did not answer keeps what it said before and stops
    /// the rest waiting; a branch git cannot count shows nothing.
    @Test func aFailedRequestKeepsEarlierAnswers() {
        let other = BranchRef(branch: "feat/other", repos: [octo])
        var state = InboxState()
        state.folders["/p"] = folder()
        state.folders["/q"] = InboxState.Folder(repo: GitRepoInfo(branch: other.branch, defaultBranch: "main", repos: [octo], unpushed: nil), prompt: nil)
        let pr = pullRequest()
        state.received(pullRequests: [branch: [pr]])
        state.failed(branches: [branch, other])
        #expect(state.github(for: worker).branch == .pullRequest(pr))
        #expect(state.github(for: session("s2", path: "/q")).branch == .none)
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
        #expect(byID[.assigned]?.entries.map(\.id) == ["octo-org/octo-repo#136268", "octo-org/octo-repo#127458"])
        #expect(byID[.opened]?.entries.map(\.id) == ["octo-org/octo-repo#135595"])
        #expect(byID[.opened]?.total == 43)
        #expect(byID[.mentions]?.entries.map(\.id) == ["octo-org/octo-repo#1"])
        #expect(byID[.mentions]?.total == 5)
    }
}
