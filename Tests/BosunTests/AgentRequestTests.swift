import Foundation
import Testing
@testable import Bosun
@testable import BosunCore

/// Which pull request request a session gets beside the merge: Push while
/// its branch has a live pull request, Open PR otherwise, a merged or
/// closed one included.
@Suite struct AgentRequestChoiceTests {
    private func pullRequest(_ state: PullRequestState) -> GitHubPullRequest {
        let repo = RepoSlug(owner: "Clarity-89", name: "bosun")
        return GitHubPullRequest(
            repo: repo, number: 34, title: "PR", url: URL(string: "https://github.com/Clarity-89/bosun/pull/34")!,
            author: nil, state: state, headBranch: "feat/agent-requests", headRepo: repo, baseBranch: "main",
            checks: nil, review: nil, hasConflicts: false, unresolvedThreads: 0, closingIssues: [], updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test(arguments: [PullRequestState.open, .draft])
    func aLivePullRequestTakesAPush(state: PullRequestState) {
        #expect(AgentRequest.requests(for: pullRequest(state)) == [.mergeMain, .updatePullRequest])
    }

    @Test(arguments: [PullRequestState.merged, .closed])
    func aFinishedPullRequestTakesANewOne(state: PullRequestState) {
        #expect(AgentRequest.requests(for: pullRequest(state)) == [.mergeMain, .submitPullRequest])
    }

    @Test func noPullRequestTakesANewOne() {
        #expect(AgentRequest.requests(for: nil) == [.mergeMain, .submitPullRequest])
    }
}
