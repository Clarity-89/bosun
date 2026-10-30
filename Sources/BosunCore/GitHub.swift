@preconcurrency import Foundation

/// A GitHub repository, `owner/name`.
public struct RepoSlug: Hashable, Codable, Sendable, CustomStringConvertible {
    public let owner: String
    public let name: String

    public init(owner: String, name: String) {
        self.owner = owner
        self.name = name
    }

    /// `owner/name`; nil for anything else.
    public init?(_ text: String) {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy(Self.isNamePart) else { return nil }
        self.init(owner: String(parts[0]), name: String(parts[1]))
    }

    /// The repository of a github.com remote: `git@github.com:o/n.git`,
    /// `ssh://git@github.com/o/n.git` or `https://github.com/o/n`. Nil for
    /// other hosts, which Bosun does not ask GitHub about.
    public init?(remoteURL: String) {
        let url = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: Substring
        if let range = url.range(of: "github.com:"), url.hasPrefix("git@") {
            path = url[range.upperBound...]
        } else if let components = URLComponents(string: url), components.host?.lowercased() == "github.com" {
            path = Substring(components.path.drop { $0 == "/" })
        } else {
            return nil
        }
        let trimmed = path.hasSuffix(".git") ? path.dropLast(4) : path
        self.init(String(trimmed.hasSuffix("/") ? trimmed.dropLast() : trimmed))
    }

    public var description: String { "\(owner)/\(name)" }

    private static func isNamePart(_ part: Substring) -> Bool {
        !part.isEmpty && part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
    }
}

/// An issue, by repository and number.
public struct IssueRef: Hashable, Codable, Sendable, CustomStringConvertible {
    public let repo: RepoSlug
    public let number: Int

    public init(repo: RepoSlug, number: Int) {
        self.repo = repo
        self.number = number
    }

    /// What someone types to name an issue: its URL, `owner/name#12`, or
    /// `#12` (or `12`) in `defaultRepo`.
    public init?(parsing text: String, defaultRepo: RepoSlug?) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let found = Self.firstURL(in: text), text.hasPrefix("http") {
            self = found
        } else if let match = text.wholeMatch(of: /([\w.-]+\/[\w.-]+)#(\d+)/),
                  let repo = RepoSlug(String(match.1)), let number = Int(match.2), number > 0 {
            self.init(repo: repo, number: number)
        } else if let defaultRepo, let match = text.wholeMatch(of: /#?(\d+)/), let number = Int(match.1), number > 0 {
            self.init(repo: defaultRepo, number: number)
        } else {
            return nil
        }
    }

    /// The first github.com issue URL in `text`, as an agent's prompt
    /// carries the issue it starts from.
    public static func firstURL(in text: String) -> IssueRef? {
        guard let match = text.firstMatch(of: /https?:\/\/github\.com\/([\w.-]+)\/([\w.-]+)\/issues\/(\d+)/),
              let number = Int(match.3), number > 0
        else { return nil }
        return IssueRef(repo: RepoSlug(owner: String(match.1), name: String(match.2)), number: number)
    }

    public var url: URL {
        URL(string: "https://github.com/\(repo)/issues/\(number)")!
    }

    public var description: String { "\(repo)#\(number)" }
}

/// A branch and the repositories it can have a pull request in: `origin`,
/// then `upstream` for a fork.
public struct BranchRef: Hashable, Sendable {
    public let branch: String
    public let repos: [RepoSlug]

    public init(branch: String, repos: [RepoSlug]) {
        self.branch = branch
        self.repos = repos
    }
}

public enum PullRequestState: Sendable {
    case open, draft, merged, closed
}

public enum CheckState: Sendable {
    case passing, failing, pending
}

public enum ReviewDecision: Sendable {
    case required, approved, changesRequested
}

public enum IssueState: Sendable {
    case open, completed, notPlanned
}

public struct GitHubPullRequest: Identifiable, Equatable, Sendable {
    public let repo: RepoSlug
    public let number: Int
    public let title: String
    public let url: URL
    public let author: String?
    public let state: PullRequestState
    public let headBranch: String
    /// Nil when the fork it came from is gone.
    public let headRepo: RepoSlug?
    public let baseBranch: String
    public let checks: CheckState?
    public let review: ReviewDecision?
    public let hasConflicts: Bool
    public let unresolvedThreads: Int
    /// The issues it closes when merged; empty where Bosun did not ask.
    public let closingIssues: [GitHubIssue]
    public let updatedAt: Date

    public var id: String { "\(repo)#\(number)" }

    /// The one to show for a branch: a live one over a merged one over a
    /// closed one, the newest among equals.
    public static func preferred(_ candidates: [GitHubPullRequest]) -> GitHubPullRequest? {
        candidates.max { lhs, rhs in
            (lhs.rank, lhs.updatedAt) < (rhs.rank, rhs.updatedAt)
        }
    }

    private var rank: Int {
        switch state {
        case .open, .draft: 2
        case .merged: 1
        case .closed: 0
        }
    }
}

public struct GitHubIssue: Identifiable, Equatable, Sendable {
    public let repo: RepoSlug
    public let number: Int
    public let title: String
    public let url: URL
    public let author: String?
    public let state: IssueState
    public let labels: [String]
    public let assignees: [String]
    public let comments: Int
    /// The pull requests that close it; empty where Bosun did not ask.
    public let pullRequests: [GitHubPullRequest]
    public let updatedAt: Date

    public var id: String { "\(repo)#\(number)" }
    public var ref: IssueRef { IssueRef(repo: repo, number: number) }
}

/// One list of the Inbox: what one search found, of `total`.
public struct InboxSection<Item: Equatable & Sendable>: Equatable, Sendable {
    public let items: [Item]
    public let total: Int

    public init(items: [Item], total: Int) {
        self.items = items
        self.total = total
    }

    static var empty: Self { Self(items: [], total: 0) }
}

/// What GitHub has for you: pull requests that ask your review, by name or
/// through a team, yours, and issues assigned to you, opened by you or
/// mentioning you.
public struct GitHubInbox: Equatable, Sendable {
    public let reviewRequests: InboxSection<GitHubPullRequest>
    public let teamReviewRequests: InboxSection<GitHubPullRequest>
    public let pullRequests: InboxSection<GitHubPullRequest>
    public let assignedIssues: InboxSection<GitHubIssue>
    public let openedIssues: InboxSection<GitHubIssue>
    public let mentions: InboxSection<GitHubIssue>
}

/// A session folder's branch and where it pushes.
public struct GitRepoInfo: Equatable, Sendable {
    /// Nil on a detached HEAD.
    public let branch: String?
    public let defaultBranch: String?
    /// `origin` first, then `upstream`: a fork's pull requests live in the
    /// repository it was forked from.
    public let repos: [RepoSlug]
    /// Commits not on the branch's upstream, or not on the default branch
    /// for one never pushed; nil when neither is known.
    public let unpushed: Int?

    public init(branch: String?, defaultBranch: String?, repos: [RepoSlug], unpushed: Int?) {
        self.branch = branch
        self.defaultBranch = defaultBranch
        self.repos = repos
        self.unpushed = unpushed
    }

    /// A branch of its own: work that can have a pull request.
    public var featureBranch: String? {
        guard let branch, branch != defaultBranch, !["main", "master", "HEAD"].contains(branch) else { return nil }
        return branch
    }

    /// Its own branch and where to ask GitHub about it; nil on the default
    /// branch, or with no github.com remote to ask.
    public var branchRef: BranchRef? {
        guard let featureBranch, !repos.isEmpty else { return nil }
        return BranchRef(branch: featureBranch, repos: repos)
    }
}

// MARK: Queries

/// A `gh api graphql` call: the query and its variables, so no search
/// string or branch name is ever spliced into GraphQL text.
public struct GraphQLRequest: Equatable, Sendable {
    public let query: String
    public let strings: [String: String]
    public let ints: [String: Int]

    /// Arguments after `gh`; `-f` passes strings as they are, `-F` numbers
    /// as numbers.
    public var arguments: [String] {
        ["api", "graphql", "-f", "query=\(query)"]
            + strings.sorted { $0.key < $1.key }.flatMap { ["-f", "\($0.key)=\($0.value)"] }
            + ints.sorted { $0.key < $1.key }.flatMap { ["-F", "\($0.key)=\($0.value)"] }
    }
}

public enum GitHubQueries {
    /// Everything a pull request's row and detail show.
    static let pullRequestFields = """
        fragment PullRequestFields on PullRequest {
          number title url isDraft state updatedAt headRefName baseRefName
          author { login }
          repository { nameWithOwner }
          headRepository { nameWithOwner }
          reviewDecision mergeable
          commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
          reviewThreads(first: 100) { nodes { isResolved } }
        }
        """

    /// A pull request inside another result, or in a folded list: state and
    /// checks, not its threads, which GitHub times out on in bulk.
    static let pullRequestSummary = """
        fragment PullRequestSummary on PullRequest {
          number title url isDraft state updatedAt headRefName baseRefName
          author { login }
          repository { nameWithOwner }
          headRepository { nameWithOwner }
          commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
        }
        """

    static let issueFields = """
        fragment IssueFields on Issue {
          number title url state stateReason updatedAt
          author { login }
          repository { nameWithOwner }
          labels(first: 10) { nodes { name } }
          assignees(first: 10) { nodes { login } }
          comments { totalCount }
        }
        """

    // Search results are a union: fields beyond the fragments go in an
    // inline fragment on their type.
    static let closing = "... on PullRequest { closingIssuesReferences(first: 5) { nodes { ...IssueFields } } }"
    static let closedBy = "closedByPullRequestsReferences(first: 5, includeClosedPrs: true) { nodes { ...PullRequestSummary } }"

    /// The Inbox's pull requests. Team requests are every review request
    /// less the ones by name, worked out after.
    public static let inboxPullRequests = searches([
        ("direct", "is:pr is:open archived:false user-review-requested:@me sort:updated-desc", "...PullRequestFields"),
        ("requested", "is:pr is:open archived:false review-requested:@me sort:updated-desc", "...PullRequestSummary"),
        ("mine", "is:pr is:open archived:false author:@me sort:updated-desc", "...PullRequestFields \(closing)"),
    ], first: 50, fragments: [pullRequestFields, pullRequestSummary, issueFields])

    /// The Inbox's issues, with the pull requests that close them.
    public static let inboxIssues = searches([
        ("assigned", "is:issue is:open archived:false assignee:@me sort:updated-desc", "... on Issue { ...IssueFields \(closedBy) }"),
        ("opened", "is:issue is:open archived:false author:@me sort:updated-desc", "... on Issue { ...IssueFields \(closedBy) }"),
        ("mentions", "is:issue is:open archived:false mentions:@me -author:@me sort:updated-desc",
         "... on Issue { ...IssueFields \(closedBy) }"),
    ], first: 50, fragments: [issueFields, pullRequestSummary])

    /// Pull requests whose head is each branch in its repositories, one
    /// alias per index (`b0`, `b1`, …), so all branches cost one request.
    public static func pullRequests(forBranches branches: [BranchRef]) -> GraphQLRequest {
        searches(
            branches.enumerated().map { index, branch in
                ("b\(index)", (["is:pr", "head:\(branch.branch)"] + branch.repos.map { "repo:\($0)" }).joined(separator: " "),
                 "...PullRequestFields \(closing)")
            },
            first: 5, fragments: [pullRequestFields, issueFields]
        )
    }

    /// Issues by reference, one alias per index (`i0`, `i1`, …).
    public static func issues(_ refs: [IssueRef]) -> GraphQLRequest {
        var strings: [String: String] = [:]
        var ints: [String: Int] = [:]
        for (index, ref) in refs.enumerated() {
            strings["o\(index)"] = ref.repo.owner
            strings["n\(index)"] = ref.repo.name
            ints["k\(index)"] = ref.number
        }
        return GraphQLRequest(
            query: query(
                declarations: refs.indices.map { "$o\($0): String!, $n\($0): String!, $k\($0): Int!" },
                selections: refs.indices.map {
                    "i\($0): repository(owner: $o\($0), name: $n\($0)) { issue(number: $k\($0)) { ...IssueFields \(closedBy) } }"
                },
                fragments: [issueFields, pullRequestSummary]
            ),
            strings: strings, ints: ints
        )
    }

    /// One search per alias, its string a variable of the same name, the
    /// first `first` of what it finds.
    private static func searches(
        _ searches: [(alias: String, query: String, fields: String)], first: Int, fragments: [String]
    ) -> GraphQLRequest {
        GraphQLRequest(
            query: query(
                declarations: searches.map { "$\($0.alias): String!" },
                selections: searches.map {
                    "\($0.alias): search(query: $\($0.alias), type: ISSUE, first: \(first)) { issueCount nodes { \($0.fields) } }"
                },
                fragments: fragments
            ),
            strings: Dictionary(uniqueKeysWithValues: searches.map { ($0.alias, $0.query) }),
            ints: [:]
        )
    }

    /// GraphQL rejects a fragment a query does not use, so each query lists
    /// its own.
    private static func query(declarations: [String], selections: [String], fragments: [String]) -> String {
        "query(\(declarations.joined(separator: ", "))) {\n  \(selections.joined(separator: "\n  "))\n}\n"
            + fragments.joined(separator: "\n")
    }
}

// MARK: Decoding

public enum GitHubDecodingError: Error, LocalizedError, Equatable, Sendable {
    /// GitHub answered with errors and no data.
    case reported(String)

    public var errorDescription: String? {
        switch self {
        case .reported(let message): message
        }
    }
}

extension GitHubInbox {
    /// The answers to `inboxPullRequests` and `inboxIssues`. GitHub can
    /// answer with data and errors both, a search it could not run say;
    /// what came is kept.
    public init(pullRequestsGraphQL: Data, issuesGraphQL: Data) throws {
        let raw = try GraphQLResponse<RawInboxPullRequests>.payload(pullRequestsGraphQL)
        let rawIssues = try GraphQLResponse<RawInboxIssues>.payload(issuesGraphQL)
        let direct = raw.direct?.section ?? .empty
        let requested = raw.requested?.section ?? .empty
        let directIDs = Set(direct.items.map(\.id))
        let teams = requested.items.filter { !directIDs.contains($0.id) }
        self.init(
            reviewRequests: direct,
            teamReviewRequests: InboxSection(items: teams, total: max(requested.total - direct.total, teams.count)),
            pullRequests: raw.mine?.section ?? .empty,
            assignedIssues: rawIssues.assigned?.section ?? .empty,
            openedIssues: rawIssues.opened?.section ?? .empty,
            mentions: rawIssues.mentions?.section ?? .empty
        )
    }
}

extension GitHubQueries {
    /// A `pullRequests(forBranches:)` answer: each branch's pull requests
    /// whose head really is that branch in one of its repositories, as
    /// `head:` also matches other forks' branches of the same name. A
    /// branch GitHub would not search has none.
    public static func decodePullRequests(_ data: Data, forBranches branches: [BranchRef]) throws -> [BranchRef: [GitHubPullRequest]] {
        let raw = try GraphQLResponse<[String: RawSearch<RawPullRequest>?]>.payload(data)
        let found = branches.enumerated().map { index, branch in
            let own = (raw["b\(index)"] ?? nil)?.pullRequests.filter { pr in
                pr.headBranch == branch.branch && (pr.headRepo.map(branch.repos.contains) ?? true)
            }
            return (branch, own ?? [])
        }
        return Dictionary(found, uniquingKeysWith: { first, _ in first })
    }

    /// An `issues(_:)` answer, in the order asked; nil where an issue was
    /// not found or GitHub would not say.
    public static func decodeIssues(_ data: Data, count: Int) throws -> [GitHubIssue?] {
        let raw = try GraphQLResponse<[String: RawRepositoryIssue?]>.payload(data)
        return (0..<count).map { index in (raw["i\(index)"] ?? nil)?.issue?.issue }
    }
}

struct GraphQLResponse<Payload: Decodable>: Decodable {
    let data: Payload?
    let errors: [Message]?

    struct Message: Decodable {
        let message: String
    }

    /// The data, or the first error GitHub gave instead of any.
    static func payload(_ data: Data) throws -> Payload {
        let response = try JSONDecoder().decode(Self.self, from: data)
        guard let payload = response.data else {
            throw GitHubDecodingError.reported(response.errors?.first?.message ?? "GitHub returned no data")
        }
        return payload
    }
}

/// `inboxPullRequests`' aliases; nil where GitHub could not run a search.
struct RawInboxPullRequests: Decodable {
    let direct: RawSearch<RawPullRequest>?
    let requested: RawSearch<RawPullRequest>?
    let mine: RawSearch<RawPullRequest>?
}

/// `inboxIssues`' aliases; nil where GitHub could not run a search.
struct RawInboxIssues: Decodable {
    let assigned: RawSearch<RawIssue>?
    let opened: RawSearch<RawIssue>?
    let mentions: RawSearch<RawIssue>?
}

struct Login: Decodable {
    let login: String
}

struct NameWithOwner: Decodable {
    let nameWithOwner: String
}

/// A search's nodes, any of which may be some other type GitHub matched
/// (an empty object to these fragments) or fail to decode; those drop out.
struct RawSearch<Node: Decodable>: Decodable {
    let issueCount: Int
    let nodes: [Lossy<Node>]

    var values: [Node] { nodes.compactMap(\.value) }
}

extension RawSearch where Node == RawPullRequest {
    var pullRequests: [GitHubPullRequest] { values.compactMap(\.pullRequest) }
    var section: InboxSection<GitHubPullRequest> { InboxSection(items: pullRequests, total: issueCount) }
}

extension RawSearch where Node == RawIssue {
    var section: InboxSection<GitHubIssue> { InboxSection(items: values.compactMap(\.issue), total: issueCount) }
}

struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

struct Connection<Node: Decodable>: Decodable {
    let nodes: [Lossy<Node>]?

    var values: [Node] { nodes?.compactMap(\.value) ?? [] }
}

struct RawRepositoryIssue: Decodable {
    let issue: RawIssue?
}

/// A pull request as `PullRequestFields` spells it, or `PullRequestSummary`,
/// which leaves out its review and threads.
struct RawPullRequest: Decodable {
    let number: Int
    let title: String
    let url: String
    let state: String
    let isDraft: Bool
    let updatedAt: String
    let headRefName: String
    let baseRefName: String
    let author: Login?
    let repository: NameWithOwner
    let headRepository: NameWithOwner?
    let commits: Connection<CommitNode>?
    let reviewDecision: String?
    let mergeable: String?
    let reviewThreads: Connection<Thread>?
    let closingIssuesReferences: Connection<RawIssue>?

    struct CommitNode: Decodable {
        let commit: Commit
        struct Commit: Decodable {
            let statusCheckRollup: Rollup?
            struct Rollup: Decodable {
                let state: String
            }
        }
    }

    struct Thread: Decodable {
        let isResolved: Bool
    }

    var pullRequest: GitHubPullRequest? {
        guard let repo = RepoSlug(repository.nameWithOwner), let url = URL(string: url), let updated = Date(rfc3339: updatedAt)
        else { return nil }
        let state: PullRequestState = switch self.state {
        case "MERGED": .merged
        case "CLOSED": .closed
        default: isDraft ? .draft : .open
        }
        return GitHubPullRequest(
            repo: repo, number: number, title: title, url: url, author: author?.login, state: state,
            headBranch: headRefName, headRepo: headRepository.flatMap { RepoSlug($0.nameWithOwner) },
            baseBranch: baseRefName,
            checks: commits?.values.first?.commit.statusCheckRollup.flatMap { Self.checks($0.state) },
            review: reviewDecision.flatMap(Self.review),
            hasConflicts: mergeable == "CONFLICTING",
            unresolvedThreads: reviewThreads?.values.count { !$0.isResolved } ?? 0,
            closingIssues: closingIssuesReferences?.values.compactMap(\.issue) ?? [],
            updatedAt: updated
        )
    }

    /// A rollup's state: pending covers checks queued or running, failing
    /// covers errors too.
    private static func checks(_ state: String) -> CheckState? {
        switch state {
        case "SUCCESS": .passing
        case "FAILURE", "ERROR": .failing
        case "PENDING", "EXPECTED": .pending
        default: nil
        }
    }

    private static func review(_ decision: String) -> ReviewDecision? {
        switch decision {
        case "REVIEW_REQUIRED": .required
        case "APPROVED": .approved
        case "CHANGES_REQUESTED": .changesRequested
        default: nil
        }
    }
}

/// An issue as `IssueFields` spells it.
struct RawIssue: Decodable {
    let number: Int
    let title: String
    let url: String
    let state: String
    let stateReason: String?
    let updatedAt: String
    let author: Login?
    let repository: NameWithOwner
    let labels: Connection<Name>?
    let assignees: Connection<Login>?
    let comments: Count?
    let closedByPullRequestsReferences: Connection<RawPullRequest>?

    struct Name: Decodable {
        let name: String
    }

    struct Count: Decodable {
        let totalCount: Int
    }

    var issue: GitHubIssue? {
        guard let repo = RepoSlug(repository.nameWithOwner), let url = URL(string: url), let updated = Date(rfc3339: updatedAt)
        else { return nil }
        let state: IssueState = switch (self.state, stateReason) {
        case ("OPEN", _): .open
        case (_, "NOT_PLANNED"), (_, "DUPLICATE"): .notPlanned
        default: .completed
        }
        return GitHubIssue(
            repo: repo, number: number, title: title, url: url, author: author?.login, state: state,
            labels: labels?.values.map(\.name) ?? [], assignees: assignees?.values.map(\.login) ?? [],
            comments: comments?.totalCount ?? 0,
            pullRequests: closedByPullRequestsReferences?.values.compactMap(\.pullRequest) ?? [],
            updatedAt: updated
        )
    }
}
