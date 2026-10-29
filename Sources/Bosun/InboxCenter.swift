import BosunCore
import Foundation
import Observation
import os

/// An issue a session works on, and how Bosun knows: your link, the pull
/// request that closes it, or the prompt omp started from.
struct LinkedIssue: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case linked, pullRequest, prompt
    }

    let ref: IssueRef
    /// Nil until GitHub answers, or when it would not say.
    let issue: GitHubIssue?
    let source: Source
}

/// A session's git and GitHub side: its branch, the pull request from it,
/// and the issue it works on.
struct SessionGitHub: Equatable, Sendable {
    var repo: GitRepoInfo?
    var pullRequest: GitHubPullRequest?
    var issue: LinkedIssue?
    /// GitHub has yet to say whether its branch has a pull request.
    var pullRequestLoading = false
    /// GitHub has yet to describe its issue.
    var issueLoading = false

    /// The issue it works on: yours if you linked one, else the one its
    /// pull request closes, else the one its omp prompt names.
    static func issue(
        linked: IssueRef?, pullRequest: GitHubPullRequest?, prompt: IssueRef?, known: [IssueRef: GitHubIssue]
    ) -> LinkedIssue? {
        if let linked {
            return LinkedIssue(ref: linked, issue: known[linked], source: .linked)
        }
        if let closing = pullRequest?.closingIssues.first {
            return LinkedIssue(ref: closing.ref, issue: closing, source: .pullRequest)
        }
        if let prompt {
            return LinkedIssue(ref: prompt, issue: known[prompt], source: .prompt)
        }
        return nil
    }

    /// Where `#12` typed for this session lives: a fork's issues are its
    /// upstream's.
    var issueRepo: RepoSlug? { repo?.repos.last }
}

/// GitHub for the Inbox and the session rows, read-only: what asks for you
/// there, and each session's branch, pull request and issue. Your links
/// from session to issue stay in Bosun.
@MainActor
@Observable
final class InboxCenter {
    enum Status: Equatable {
        case idle, loading, ready
        case notInstalled, signedOut
        case failed(String)
    }

    private(set) var inbox: GitHubInbox?
    private(set) var status = Status.idle
    private(set) var updatedAt: Date?
    /// By session id.
    private(set) var sessionGitHub: [String: SessionGitHub] = [:]
    /// Sessions to issues, as you linked them; Bosun's alone.
    private(set) var links = InboxCenter.savedLinks() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(links), forKey: Self.linksKey) }
    }

    @ObservationIgnored private let gitHub = GitHubCLI()
    @ObservationIgnored private var sessions: [DeckSession] = []
    /// The folders the last load read, so a new session's folder reloads.
    @ObservationIgnored private var loadedPaths: Set<String>?
    /// Each folder's git info and omp prompt, from the last load.
    @ObservationIgnored private var folders: [String: Folder] = [:]
    /// Issues GitHub described, for links and prompts outside the Inbox.
    @ObservationIgnored private var known: [IssueRef: GitHubIssue] = [:]
    /// What GitHub was asked about, answered or not: until then a row shows
    /// where its pull request or issue will go.
    @ObservationIgnored private var askedBranches: Set<BranchKey> = []
    @ObservationIgnored private var askedIssues: Set<IssueRef> = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var loopTask: Task<Void, Never>?

    private struct Folder: Sendable {
        let repo: GitRepoInfo?
        let prompt: IssueRef?
    }

    subscript(sessionID: String) -> SessionGitHub? { sessionGitHub[sessionID] }

    /// The sessions working on `pullRequest`, from its branch.
    func sessions(working pullRequest: GitHubPullRequest) -> [DeckSession] {
        sessions.filter { sessionGitHub[$0.id]?.pullRequest?.id == pullRequest.id }
    }

    /// The sessions working on `issue`, by link, pull request or prompt.
    func sessions(working issue: GitHubIssue) -> [DeckSession] {
        sessions.filter { sessionGitHub[$0.id]?.issue?.ref == issue.ref }
    }

    /// Reloads every 5 min from now on; the first list starts it.
    func start() {
        guard loopTask == nil else { return }
        loopTask = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        refreshTask?.cancel()
    }

    /// A new session list. A folder the last load did not read reloads
    /// everything; the rest waits for the next round. A deleted session's
    /// link goes with it.
    func listed(_ sessions: [DeckSession]) {
        self.sessions = sessions
        let ids = Set(sessions.map(\.id))
        if links.keys.contains(where: { !ids.contains($0) }) {
            links = links.filter { ids.contains($0.key) }
        }
        guard let loadedPaths else { return }
        if !Set(sessions.map(\.path)).isSubset(of: loadedPaths) {
            Task { await refresh() }
        } else {
            rebuildSessions()
        }
    }

    /// One load at a time; asking during one waits for it.
    func refresh() async {
        if let refreshTask {
            return await refreshTask.value
        }
        let task = Task { await load() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    // MARK: Links

    /// The issue a link or its removal now shows may be one GitHub has not
    /// described yet: the prompt's, hidden behind the link until now.
    func link(_ ref: IssueRef, toSession sessionID: String) {
        links[sessionID] = ref
        rebuildSessions()
        Task { await describeUnknownIssues() }
    }

    func unlink(session sessionID: String) {
        links[sessionID] = nil
        rebuildSessions()
        Task { await describeUnknownIssues() }
    }

    private func load() async {
        if inbox == nil { status = .loading }
        let sessions = self.sessions
        let paths = Set(sessions.map(\.path))
        // git and omp's logs are local and quick; reading them off the main
        // actor keeps the window responsive.
        let folders = await withTaskGroup(of: (String, Folder).self) { group in
            for path in paths {
                group.addTask {
                    (path, Folder(repo: await GitRepo.info(path: path), prompt: OmpLog.firstIssue(forWorkingDirectory: path)))
                }
            }
            var folders: [String: Folder] = [:]
            for await (path, folder) in group { folders[path] = folder }
            return folders
        }
        // Shown at once, so GitHub's part fills in around what is known.
        self.folders = folders
        loadedPaths = paths
        rebuildSessions()
        let branches = Self.branches(in: folders.values.compactMap(\.repo))

        let gitHub = gitHub
        async let inbox = result { try await gitHub.inbox() }
        async let found = result { try await gitHub.pullRequests(forBranches: branches) }
        let inboxResult = await inbox
        let foundResult = await found

        askedBranches.formUnion(branches.map(BranchKey.init))
        var pullRequests: [BranchKey: GitHubPullRequest] = [:]
        if case .success(let lists) = foundResult {
            for (branch, list) in zip(branches, lists) {
                pullRequests[BranchKey(branch)] = GitHubPullRequest.preferred(list)
            }
            branchPullRequests = pullRequests
        }
        switch inboxResult {
        case .success(let fresh):
            self.inbox = fresh
            remember(fresh)
            status = .ready
            updatedAt = .now
        case .failure(let error):
            status = Self.status(for: error)
            logger.error("inbox failed: \(error.localizedDescription, privacy: .public)")
        }
        if case .failure(let error) = foundResult {
            logger.error("branch pull requests failed: \(error.localizedDescription, privacy: .public)")
        }
        rebuildSessions()
        await describeUnknownIssues()
    }

    /// Pull requests by branch from the last load that reached GitHub.
    @ObservationIgnored private var branchPullRequests: [BranchKey: GitHubPullRequest] = [:]

    private struct BranchKey: Hashable {
        let branch: String
        let repos: [RepoSlug]

        init(_ entry: (branch: String, repos: [RepoSlug])) {
            branch = entry.branch
            repos = entry.repos
        }
    }

    /// Each distinct branch of its own, with the repositories it pushes to.
    private static func branches(in repos: [GitRepoInfo]) -> [(branch: String, repos: [RepoSlug])] {
        var seen = Set<BranchKey>()
        return repos.compactMap { info in
            guard let branch = info.featureBranch, !info.repos.isEmpty else { return nil }
            let entry = (branch: branch, repos: info.repos)
            return seen.insert(BranchKey(entry)).inserted ? entry : nil
        }
    }

    /// The Inbox's issues, and the ones its pull requests close, need no
    /// second request for a link or prompt naming them.
    private func remember(_ inbox: GitHubInbox) {
        let issues = inbox.assignedIssues.items + inbox.openedIssues.items + inbox.mentions.items
            + (inbox.pullRequests.items + inbox.reviewRequests.items).flatMap(\.closingIssues)
        for issue in issues { known[issue.ref] = issue }
    }

    /// Links and prompts naming an issue the Inbox did not bring, in one
    /// request.
    private func describeUnknownIssues() async {
        let wanted = Set(sessionGitHub.values.compactMap { $0.issue?.issue == nil ? $0.issue?.ref : nil })
        let refs = Array(wanted.subtracting(known.keys))
        guard !refs.isEmpty else { return }
        let issues = try? await gitHub.issues(refs)
        askedIssues.formUnion(refs)
        for (ref, issue) in zip(refs, issues ?? []) {
            if let issue { known[ref] = issue }
        }
        rebuildSessions()
    }

    /// Each session's side from what the last load found, your links over
    /// what was worked out.
    private func rebuildSessions() {
        var next: [String: SessionGitHub] = [:]
        for session in sessions {
            let folder = folders[session.path]
            let branch = folder?.repo.flatMap { info in
                info.featureBranch.map { BranchKey((branch: $0, repos: info.repos)) }
            }
            let pullRequest = branch.flatMap { branchPullRequests[$0] }
            let issue = SessionGitHub.issue(linked: links[session.id], pullRequest: pullRequest, prompt: folder?.prompt, known: known)
            next[session.id] = SessionGitHub(
                repo: folder?.repo,
                pullRequest: pullRequest,
                issue: issue,
                pullRequestLoading: branch.map { !askedBranches.contains($0) } ?? false,
                issueLoading: issue.map { $0.issue == nil && !askedIssues.contains($0.ref) } ?? false
            )
        }
        if next != sessionGitHub { sessionGitHub = next }
    }

    private static func status(for error: any Error) -> Status {
        switch error {
        case GitHubCLIError.notInstalled: .notInstalled
        case GitHubCLIError.signedOut: .signedOut
        default: .failed(error.localizedDescription)
        }
    }

    private nonisolated func result<T: Sendable>(_ operation: @Sendable () async throws -> T) async -> Result<T, any Error> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
    }

    // MARK: Saved

    private static let linksKey = "inbox.issueLinks"

    private static func savedLinks() -> [String: IssueRef] {
        UserDefaults.standard.data(forKey: linksKey)
            .flatMap { try? JSONDecoder().decode([String: IssueRef].self, from: $0) } ?? [:]
    }
}
