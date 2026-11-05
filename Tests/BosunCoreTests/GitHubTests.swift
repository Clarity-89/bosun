@preconcurrency import Foundation
import Testing
@testable import BosunCore

/// Repositories from `git remote get-url`.
@Suite struct RepoSlugTests {
    @Test(arguments: [
        ("git@github.com:octo-org/octo-repo.git", "octo-org/octo-repo"),
        ("https://github.com/Clarity-89/bosun", "Clarity-89/bosun"),
        ("https://github.com/Clarity-89/bosun.git", "Clarity-89/bosun"),
        ("ssh://git@github.com/asheshgoplani/agent-deck.git", "asheshgoplani/agent-deck"),
        ("https://github.com/octo-org/second/", "octo-org/second"),
        ("https://GitHub.com/octo-org/sdk.git\n", "octo-org/sdk"),
    ])
    func readsGitHubRemotes(remote: String, slug: String) {
        #expect(RepoSlug(remoteURL: remote)?.description == slug)
    }

    /// Other hosts, and paths that are not one repository.
    @Test(arguments: [
        "git@gitlab.com:octo-org/octo-repo.git",
        "https://example.com/github.com/a/b",
        "https://github.com/octo-org",
        "https://github.com/octo-org/octo-repo/pull/1",
        "/Users/me/dev/local-only",
    ])
    func ignoresEverythingElse(remote: String) {
        #expect(RepoSlug(remoteURL: remote) == nil)
    }
}

/// What someone types into Link to Issue…, and the URL in a prompt.
@Suite struct IssueRefTests {
    static let bosun = RepoSlug(owner: "Clarity-89", name: "bosun")

    @Test(arguments: [
        ("https://github.com/octo-org/octo-repo/issues/136268", "octo-org/octo-repo#136268"),
        ("https://github.com/octo-org/octo-repo/issues/136268#issuecomment-1", "octo-org/octo-repo#136268"),
        ("  octo-org/third#1420 ", "octo-org/third#1420"),
        ("#16", "Clarity-89/bosun#16"),
        ("16", "Clarity-89/bosun#16"),
    ])
    func readsTypedReferences(text: String, ref: String) {
        #expect(IssueRef(parsing: text, defaultRepo: Self.bosun)?.description == ref)
    }

    /// A bare number needs the session's repository; a pull request's URL
    /// is not an issue.
    @Test func rejectsWhatNamesNoIssue() {
        #expect(IssueRef(parsing: "#16", defaultRepo: nil) == nil)
        #expect(IssueRef(parsing: "https://github.com/octo-org/octo-repo/pull/136272", defaultRepo: Self.bosun) == nil)
        #expect(IssueRef(parsing: "fix the homepage", defaultRepo: Self.bosun) == nil)
        #expect(IssueRef(parsing: "#0", defaultRepo: Self.bosun) == nil)
    }

    @Test func findsTheFirstIssueURLInProse() {
        let prompt = "Implement https://github.com/Clarity-89/bosun/issues/16, then see https://github.com/Clarity-89/bosun/issues/17"
        #expect(IssueRef.firstURL(in: prompt)?.description == "Clarity-89/bosun#16")
        #expect(IssueRef.firstURL(in: "Review https://github.com/octo-org/octo-repo/pull/134116") == nil)
    }
}

@Suite struct GitRepoInfoTests {
    /// Only a branch of its own can have a pull request.
    @Test(arguments: [
        ("me/feature", "main", "me/feature"),
        ("main", "main", nil),
        ("develop", "develop", nil),
        ("master", nil, nil),
        ("omp-support", nil, "omp-support"),
    ] as [(String, String?, String?)])
    func featureBranch(branch: String, defaultBranch: String?, expected: String?) {
        let info = GitRepoInfo(branch: branch, defaultBranch: defaultBranch, repos: [], unpushed: nil)
        #expect(info.featureBranch == expected)
    }

    @Test func detachedHeadHasNoBranch() {
        #expect(GitRepoInfo(branch: nil, defaultBranch: "main", repos: [], unpushed: nil).featureBranch == nil)
    }

    /// A branch of its own is worth asking GitHub about only with a
    /// github.com remote to ask.
    @Test func asksGitHubOnlyWithARemote() {
        let octo = RepoSlug(owner: "octo-org", name: "octo-repo")
        #expect(GitRepoInfo(branch: "me/x", defaultBranch: "main", repos: [octo], unpushed: 2).branchRef == BranchRef(branch: "me/x", repos: [octo]))
        #expect(GitRepoInfo(branch: "me/x", defaultBranch: "main", repos: [], unpushed: 2).branchRef == nil)
        #expect(GitRepoInfo(branch: "main", defaultBranch: "main", repos: [octo], unpushed: nil).branchRef == nil)
    }
}

/// `gh api graphql` answers, trimmed from live ones.
@Suite struct GitHubDecodingTests {
    static func pr(_ number: Int, repo: String = "octo-org/octo-repo", head: String = "me/branch", headRepo: String? = "octo-org/octo-repo",
                   state: String = "OPEN", draft: Bool = false, updated: String = "2026-10-29T15:28:56Z",
                   checks: String? = "SUCCESS", review: String? = "REVIEW_REQUIRED", mergeable: String = "MERGEABLE",
                   threads: [Bool] = [], closing: String = "") -> String {
        let rollup = checks.map { "{\"state\":\"\($0)\"}" } ?? "null"
        let headRepository = headRepo.map { "{\"nameWithOwner\":\"\($0)\"}" } ?? "null"
        let closingField = closing.isEmpty ? "" : ",\"closingIssuesReferences\":{\"nodes\":[\(closing)]}"
        return """
        {"number":\(number),"title":"PR \(number)","url":"https://github.com/\(repo)/pull/\(number)","isDraft":\(draft),
         "state":"\(state)","updatedAt":"\(updated)","headRefName":"\(head)","baseRefName":"main",
         "author":{"login":"Clarity-89"},"repository":{"nameWithOwner":"\(repo)"},"headRepository":\(headRepository),
         "reviewDecision":\(review.map { "\"\($0)\"" } ?? "null"),"mergeable":"\(mergeable)",
         "commits":{"nodes":[{"commit":{"statusCheckRollup":\(rollup)}}]},
         "reviewThreads":{"nodes":[\(threads.map { "{\"isResolved\":\($0)}" }.joined(separator: ","))]}\(closingField)}
        """
    }

    static func issue(_ number: Int, repo: String = "octo-org/octo-repo", state: String = "OPEN", reason: String? = nil,
                      closedBy: String = "") -> String {
        let closedByField = closedBy.isEmpty ? "" : ",\"closedByPullRequestsReferences\":{\"nodes\":[\(closedBy)]}"
        return """
        {"number":\(number),"title":"Issue \(number)","url":"https://github.com/\(repo)/issues/\(number)",
         "state":"\(state)","stateReason":\(reason.map { "\"\($0)\"" } ?? "null"),"updatedAt":"2026-10-28T11:11:14Z",
         "author":{"login":"tdbishop"},"repository":{"nameWithOwner":"\(repo)"},
         "labels":{"nodes":[{"name":"internal"}]},"assignees":{"nodes":[{"login":"Clarity-89"}]},
         "comments":{"totalCount":10}\(closedByField)}
        """
    }

    static func search(_ count: Int, _ nodes: [String]) -> String {
        "{\"issueCount\":\(count),\"nodes\":[\(nodes.joined(separator: ","))]}"
    }

    /// The two inbox answers; `errors` goes with the issues one, as when
    /// GitHub cannot run one of its searches.
    static func inbox(errors: String = "") throws -> GitHubInbox {
        let errorsField = errors.isEmpty ? "" : ",\"errors\":[{\"message\":\"\(errors)\"}]"
        let pullRequests = Data("""
        {"data":{
         "direct":\(search(1, [pr(134116, checks: "FAILURE", review: "CHANGES_REQUESTED", mergeable: "CONFLICTING", threads: [false, true, false])])),
         "requested":\(search(31, [pr(134116), pr(136472), "{}"])),
         "mine":\(search(9, [pr(136272, closing: issue(136268)), pr(136105, draft: true, checks: "PENDING", review: nil)]))}}
        """.utf8)
        let issues = Data("""
        {"data":{
         "assigned":\(search(4, [issue(136268, closedBy: pr(136272))])),
         "opened":\(search(44, [issue(1420, repo: "octo-org/third", state: "CLOSED", reason: "COMPLETED"),
                                 issue(14, repo: "Clarity-89/bosun", state: "CLOSED", reason: "NOT_PLANNED")])),
         "mentions":null}\(errorsField)}
        """.utf8)
        return try GitHubInbox(pullRequestsGraphQL: pullRequests, issuesGraphQL: issues)
    }

    @Test func readsThePullRequestStateThatMatters() throws {
        let inbox = try Self.inbox()
        let direct = try #require(inbox.reviewRequests.items.first)
        #expect(direct.checks == .failing)
        #expect(direct.review == .changesRequested)
        #expect(direct.hasConflicts)
        #expect(direct.unresolvedThreads == 2)
        let draft = try #require(inbox.pullRequests.items.last)
        #expect(draft.state == .draft)
        #expect(draft.checks == .pending)
        #expect(draft.review == nil)
    }

    /// GitHub has no search for team requests alone: they are all review
    /// requests less the ones by name, and so is their count.
    @Test func teamRequestsAreTheOnesNotByName() throws {
        let inbox = try Self.inbox()
        #expect(inbox.reviewRequests.items.map(\.number) == [134116])
        #expect(inbox.teamReviewRequests.items.map(\.number) == [136472])
        #expect(inbox.teamReviewRequests.total == 30)
    }

    @Test func linksIssuesAndThePullRequestsThatCloseThem() throws {
        let inbox = try Self.inbox()
        #expect(inbox.pullRequests.items.first?.closingIssues.map(\.number) == [136268])
        #expect(inbox.assignedIssues.items.first?.pullRequests.map(\.number) == [136272])
    }

    @Test func closedIssuesSayWhy() throws {
        let inbox = try Self.inbox()
        #expect(inbox.openedIssues.items.map(\.state) == [.completed, .notPlanned])
        #expect(inbox.openedIssues.total == 44)
    }

    /// Partial answers keep what came: an unmatched node drops out, a
    /// search GitHub could not run is empty.
    @Test func keepsWhatCameWithErrors() throws {
        let inbox = try Self.inbox(errors: "Something went wrong while executing your query.")
        #expect(inbox.mentions.items.isEmpty)
        #expect(inbox.mentions.total == 0)
        #expect(inbox.assignedIssues.total == 4)
    }

    @Test func noDataIsTheReportedError() {
        let data = Data(#"{"errors":[{"message":"Your token has not been granted the required scopes"}]}"#.utf8)
        #expect(throws: GitHubDecodingError.reported("Your token has not been granted the required scopes")) {
            try GitHubInbox(pullRequestsGraphQL: data, issuesGraphQL: data)
        }
    }

    /// `head:` matches other forks' branches of the same name; only the
    /// session's own repositories count.
    @Test func branchPullRequestsAreTheBranchsOwn() throws {
        let agentDeck = BranchRef(
            branch: "feat/surface-worktree-setup-warnings",
            repos: [RepoSlug(owner: "Clarity-89", name: "agent-deck"), RepoSlug(owner: "asheshgoplani", name: "agent-deck")]
        )
        let octo = BranchRef(branch: "me/other", repos: [RepoSlug(owner: "octo-org", name: "octo-repo")])
        let data = Data("""
        {"data":{
         "b0":\(Self.search(3, [
             Self.pr(1696, repo: "asheshgoplani/agent-deck", head: "feat/surface-worktree-setup-warnings", headRepo: "Clarity-89/agent-deck", state: "MERGED"),
             Self.pr(1700, repo: "asheshgoplani/agent-deck", head: "feat/surface-worktree-setup-warnings", headRepo: "someone/agent-deck"),
             Self.pr(1701, repo: "asheshgoplani/agent-deck", head: "feat/surface-worktree-setup-warnings-2", headRepo: "Clarity-89/agent-deck"),
         ])),
         "b1":null}}
        """.utf8)
        let found = try GitHubQueries.decodePullRequests(data, forBranches: [agentDeck, octo])
        #expect(found[agentDeck]?.map(\.number) == [1696])
        #expect(found[octo] == [])
    }

    @Test func aBranchShowsItsLivePullRequestFirst() throws {
        let data = Data("""
        {"data":{"b0":\(Self.search(3, [
            Self.pr(1, state: "MERGED", updated: "2026-10-29T00:00:00Z"),
            Self.pr(2, state: "OPEN", updated: "2026-10-01T00:00:00Z"),
            Self.pr(3, state: "CLOSED", updated: "2026-10-30T00:00:00Z"),
            Self.pr(4, state: "OPEN", draft: true, updated: "2026-10-02T00:00:00Z"),
        ]))}}
        """.utf8)
        let branch = BranchRef(branch: "me/branch", repos: [RepoSlug(owner: "octo-org", name: "octo-repo")])
        let found = try #require(GitHubQueries.decodePullRequests(data, forBranches: [branch])[branch])
        #expect(GitHubPullRequest.preferred(found)?.number == 4)
        #expect(GitHubPullRequest.preferred(found.filter { $0.state != .open && $0.state != .draft })?.number == 1)
    }

    @Test func issuesComeBackInTheOrderAsked() throws {
        let data = Data("""
        {"data":{"i0":{"issue":\(Self.issue(10, repo: "Clarity-89/bosun", state: "CLOSED", reason: "COMPLETED"))},"i1":{"issue":null},"i2":null}}
        """.utf8)
        let issues = try GitHubQueries.decodeIssues(data, count: 3)
        #expect(issues.map { $0?.number } == [10, nil, nil])
    }
}

/// Search strings and branch names travel as variables, so nothing a
/// branch is called can change the query.
@Suite struct GraphQLRequestTests {
    @Test func branchNamesStayOutOfTheQuery() {
        let branch = "me/x\") { viewer { login } }"
        let request = GitHubQueries.pullRequests(forBranches: [BranchRef(branch: branch, repos: [RepoSlug(owner: "octo-org", name: "octo-repo")])])
        #expect(!request.query.contains(branch))
        #expect(request.arguments.contains("b0=is:pr head:\(branch) repo:octo-org/octo-repo"))
    }

    @Test func issueNumbersAreTypedVariables() {
        let request = GitHubQueries.issues([IssueRef(repo: RepoSlug(owner: "Clarity-89", name: "bosun"), number: 16)])
        #expect(request.arguments.suffix(2) == ["-F", "k0=16"])
        #expect(request.strings == ["o0": "Clarity-89", "n0": "bosun"])
    }
}

/// The toolbar's uncommitted count: Grafana's enterprise link in a go.mod
/// is never committed, so a go.mod with nothing else changed is no change.
@Suite struct WorkTreeChangesTests {
    /// `git diff -U0 HEAD` in a Grafana worktree with the link, plus a module
    /// that also has a real change.
    static let diff = """
        diff --git a/apps/iam/go.mod b/apps/iam/go.mod
        index 93fb2faf18b..a33f97a2a80 100644
        --- a/apps/iam/go.mod
        +++ b/apps/iam/go.mod
        @@ -152,0 +153,2 @@ require (
        +
        +replace github.com/grafana/grafana-enterprise => ../../../grafana-enterprise
        diff --git a/apps/plugins/go.mod b/apps/plugins/go.mod
        index 1111111..2222222 100644
        --- a/apps/plugins/go.mod
        +++ b/apps/plugins/go.mod
        @@ -10 +10 @@ require (
        -	github.com/grafana/grafana-app-sdk v0.40.0
        +	github.com/grafana/grafana-app-sdk v0.41.0
        @@ -152,0 +153,2 @@ require (
        +
        +replace github.com/grafana/grafana-enterprise => ../../../grafana-enterprise
        diff --git a/go.mod b/go.mod
        index 7ea418478d5..e609bc92ee8 100644
        --- a/go.mod
        +++ b/go.mod
        @@ -476,0 +477 @@ require (
        +	github.com/grafana/grafana-enterprise v0.0.0
        @@ -732,0 +734,2 @@ exclude k8s.io/client-go v12.0.0+incompatible
        +
        +replace github.com/grafana/grafana-enterprise => ../grafana-enterprise
        """

    @Test func aModuleWithARealChangeStillCounts() {
        #expect(GitRepo.enterpriseLinkOnly(diff: Self.diff) == ["apps/iam/go.mod", "go.mod"])
    }

    /// Through git itself: the status lists the linked module, the scan
    /// drops it, and keeps a module with a real change and a new one.
    @Test func theScanDropsOnlyLinkedModules() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "bosun-gomod-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "apps/iam"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ arguments: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path, "-c", "user.name=t", "-c", "user.email=t@t"] + arguments
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, "git \(arguments)")
        }
        func write(_ path: String, _ text: String) throws {
            try text.write(to: root.appending(path: path), atomically: true, encoding: .utf8)
        }
        let module = "module x\n\nrequire (\n\tgithub.com/a/b v1.0.0\n)\n"
        try git("init", "-q")
        try write("go.mod", module)
        try write("apps/iam/go.mod", module)
        try git("add", ".")
        try git("commit", "-q", "-m", "init")
        let link = "\nreplace github.com/grafana/grafana-enterprise => ../grafana-enterprise\n"
        try write("go.mod", module + link)
        try write("apps/iam/go.mod", module.replacingOccurrences(of: "v1.0.0", with: "v1.1.0") + link)
        try FileManager.default.createDirectory(at: root.appending(path: "apps/new"), withIntermediateDirectories: true)
        try write("apps/new/go.mod", link)
        #expect(await GitRepo.changes(path: root.path) == [" M apps/iam/go.mod", "?? apps/new/"])
    }
}
