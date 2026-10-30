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

    /// What GitHub said of it.
    enum Answer: Equatable, Sendable {
        /// Nothing yet.
        case pending
        /// It would not say: gone, private, or never there.
        case missing
        case issue(GitHubIssue)
    }

    let ref: IssueRef
    let source: Source
    let answer: Answer

    var issue: GitHubIssue? {
        if case .issue(let issue) = answer { issue } else { nil }
    }
}

/// A session's git and GitHub side: what its branch has, and the issue it
/// works on.
struct SessionGitHub: Equatable, Sendable {
    enum Branch: Equatable, Sendable {
        /// Bosun has yet to read the folder, or GitHub to answer for the branch.
        case loading
        /// Nothing to show: no repository, or its default branch.
        case none
        /// A branch of its own without a pull request, and how many of its
        /// commits are not pushed, when git knows.
        case unpushed(branch: String, commits: Int?)
        case pullRequest(GitHubPullRequest)

        var pullRequest: GitHubPullRequest? {
            if case .pullRequest(let pullRequest) = self { pullRequest } else { nil }
        }
    }

    let branch: Branch
    let issue: LinkedIssue?
    /// Where `#12` typed for this session lives: a fork's issues are its
    /// upstream's.
    let issueRepo: RepoSlug?
}

/// What Bosun has from git, omp and GitHub, and the rules for what each
/// session shows of it. InboxCenter feeds it what it read and asked.
struct InboxState: Equatable, Sendable {
    /// A session folder's branch and omp prompt.
    struct Folder: Equatable, Sendable {
        let repo: GitRepoInfo?
        let prompt: IssueRef?
    }

    /// Each folder read, by path.
    var folders: [String: Folder] = [:]
    /// Sessions to issues, as you linked them; Bosun's alone.
    var links: [String: IssueRef] = [:]
    /// Each branch asked about, and the pull request GitHub found for it.
    var pullRequests: [BranchRef: GitHubPullRequest?] = [:]
    /// Each issue asked about, and what GitHub said of it.
    var issues: [IssueRef: GitHubIssue?] = [:]
    var inbox: GitHubInbox?

    /// The branches to ask GitHub about: each folder's own, with its
    /// repositories.
    var branches: [BranchRef] {
        Array(Set(folders.values.compactMap { $0.repo?.branchRef }))
    }

    func github(for session: DeckSession) -> SessionGitHub {
        let folder = folders[session.path]
        let branch = branch(of: folder)
        return SessionGitHub(
            branch: branch,
            issue: issue(linked: links[session.id], pullRequest: branch.pullRequest, prompt: folder?.prompt),
            issueRepo: folder?.repo?.repos.last
        )
    }

    /// What a folder's branch has: unknown before the folder is read, and
    /// before GitHub answers for a branch that has somewhere to ask.
    private func branch(of folder: Folder?) -> SessionGitHub.Branch {
        guard let folder else { return .loading }
        guard let repo = folder.repo, let name = repo.featureBranch else { return .none }
        let unpushed = SessionGitHub.Branch.unpushed(branch: name, commits: repo.unpushed)
        guard let ref = repo.branchRef else { return unpushed }
        guard let asked = pullRequests[ref] else { return .loading }
        return asked.map(SessionGitHub.Branch.pullRequest) ?? unpushed
    }

    /// The issue a session works on: yours if you linked one, else the one
    /// its pull request closes, else the one its omp prompt names.
    func issue(linked: IssueRef?, pullRequest: GitHubPullRequest?, prompt: IssueRef?) -> LinkedIssue? {
        if let linked {
            return LinkedIssue(ref: linked, source: .linked, answer: answer(for: linked))
        }
        if let closing = pullRequest?.closingIssues.first {
            return LinkedIssue(ref: closing.ref, source: .pullRequest, answer: .issue(closing))
        }
        if let prompt {
            return LinkedIssue(ref: prompt, source: .prompt, answer: answer(for: prompt))
        }
        return nil
    }

    private func answer(for ref: IssueRef) -> LinkedIssue.Answer {
        guard let asked = issues[ref] else { return .pending }
        return asked.map(LinkedIssue.Answer.issue) ?? .missing
    }

    // MARK: What came

    /// The Inbox's issues, and the ones its pull requests close, need no
    /// second request for a link or prompt naming them.
    mutating func received(_ inbox: GitHubInbox) {
        self.inbox = inbox
        let described = inbox.assignedIssues.items + inbox.openedIssues.items + inbox.mentions.items
            + (inbox.pullRequests.items + inbox.reviewRequests.items).flatMap(\.closingIssues)
        for issue in described { issues.updateValue(issue, forKey: issue.ref) }
    }

    /// Each branch's pull request, the preferred one of what GitHub found.
    mutating func received(pullRequests found: [BranchRef: [GitHubPullRequest]]) {
        for (ref, candidates) in found { pullRequests.updateValue(GitHubPullRequest.preferred(candidates), forKey: ref) }
    }

    /// GitHub's answers for `refs`, nil for an issue it would not describe.
    mutating func received(issues answers: [GitHubIssue?], for refs: [IssueRef]) {
        for (ref, answer) in zip(refs, answers) { issues.updateValue(answer, forKey: ref) }
    }

    /// GitHub did not answer for these branches: until it does, one it has
    /// never answered for shows as without a pull request, not as loading.
    mutating func failed(branches: [BranchRef]) {
        for ref in branches where pullRequests[ref] == nil { pullRequests.updateValue(nil, forKey: ref) }
    }
}

/// GitHub for the Inbox and the session rows, read-only: what asks for you
/// there, and each session's branch, pull request and issue. InboxState
/// holds what came and the rules; this reads git and omp, asks GitHub and
/// keeps your links across a quit.
@MainActor
@Observable
final class InboxCenter {
    enum Status: Equatable {
        case idle, loading, ready
        case notInstalled, signedOut
        case failed(String)
    }

    private(set) var state = InboxState(links: InboxCenter.savedLinks()) {
        didSet {
            guard oldValue.links != state.links else { return }
            UserDefaults.standard.set(try? JSONEncoder().encode(state.links), forKey: Self.linksKey)
        }
    }
    private(set) var status = Status.idle
    private(set) var updatedAt: Date?
    private(set) var sessions: [DeckSession] = []

    @ObservationIgnored private let gitHub = GitHubCLI()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var loopTask: Task<Void, Never>?

    var inbox: GitHubInbox? { state.inbox }

    subscript(session: DeckSession) -> SessionGitHub { state.github(for: session) }

    /// The sessions working on `pullRequest`, from its branch.
    func sessions(working pullRequest: GitHubPullRequest) -> [DeckSession] {
        sessions.filter { self[$0].branch.pullRequest?.id == pullRequest.id }
    }

    /// The sessions working on `issue`, by link, pull request or prompt.
    func sessions(working issue: GitHubIssue) -> [DeckSession] {
        sessions.filter { self[$0].issue?.ref == issue.ref }
    }

    /// GitHub last answered over a minute ago.
    var isStale: Bool {
        updatedAt.map { Date.now.timeIntervalSince($0) > 60 } ?? false
    }

    /// Reloads every 5 min from now on; the first list starts it, so the
    /// first load has folders to read.
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

    /// A new session list. A deleted session's link goes with it. A folder
    /// no load has read is read now, with its branch's pull request; the
    /// rest waits for the next round.
    func listed(_ sessions: [DeckSession]) {
        self.sessions = sessions
        let ids = Set(sessions.map(\.id))
        update { state in state.links = state.links.filter { ids.contains($0.key) } }
        guard loopTask != nil, !Set(sessions.map(\.path)).isSubset(of: state.folders.keys) else { return }
        Task { await loadSessions() }
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

    /// A link, or its removal, can show an issue GitHub has not described:
    /// the prompt's, hidden behind the link until now.
    func link(_ ref: IssueRef, toSession sessionID: String) {
        update { $0.links[sessionID] = ref }
        Task { await describePendingIssues() }
    }

    func unlink(session sessionID: String) {
        update { $0.links[sessionID] = nil }
        Task { await describePendingIssues() }
    }

    // MARK: Loading

    /// Everything: the sessions' folders and branches alongside the Inbox,
    /// then the issues neither brought.
    private func load() async {
        if state.inbox == nil { status = .loading }
        async let inbox: Void = askInbox()
        await askBranches(await readFolders())
        await inbox
        await describePendingIssues()
    }

    /// The sessions' folders and branches, and the issues their prompts name.
    private func loadSessions() async {
        await askBranches(await readFolders())
        await describePendingIssues()
    }

    /// Every session folder's branch and omp prompt, shown at once so
    /// GitHub's part fills in around what is known. Read off the main actor:
    /// local, but not free on a large repository.
    private func readFolders() async -> [BranchRef] {
        let paths = Set(sessions.map(\.path))
        let folders = await withTaskGroup(of: (String, InboxState.Folder).self) { group in
            for path in paths {
                group.addTask {
                    (path, InboxState.Folder(repo: await GitRepo.info(path: path), prompt: OmpLog.firstIssue(forWorkingDirectory: path)))
                }
            }
            var folders: [String: InboxState.Folder] = [:]
            for await (path, folder) in group { folders[path] = folder }
            return folders
        }
        update { $0.folders = folders }
        return state.branches
    }

    /// Each branch's pull request, in one request.
    private func askBranches(_ branches: [BranchRef]) async {
        guard !branches.isEmpty else { return }
        do {
            let found = try await gitHub.pullRequests(forBranches: branches)
            update { $0.received(pullRequests: found) }
        } catch {
            update { $0.failed(branches: branches) }
            logger.error("branch pull requests failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func askInbox() async {
        do {
            let fresh = try await gitHub.inbox()
            update { $0.received(fresh) }
            status = .ready
            updatedAt = .now
        } catch {
            status = Self.status(for: error)
            logger.error("inbox failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Links and prompts naming an issue GitHub has not described, in one
    /// request; one it will not answer for stops waiting.
    private func describePendingIssues() async {
        let refs = Array(Set(sessions.compactMap { session in
            self[session].issue.flatMap { $0.answer == .pending ? $0.ref : nil }
        }))
        guard !refs.isEmpty else { return }
        let answers = (try? await gitHub.issues(refs)) ?? refs.map { _ in nil }
        update { $0.received(issues: answers, for: refs) }
    }

    /// Applies a change and publishes it if it made one.
    private func update(_ change: (inout InboxState) -> Void) {
        var next = state
        change(&next)
        if next != state { state = next }
    }

    private static func status(for error: any Error) -> Status {
        switch error {
        case GitHubCLIError.notInstalled: .notInstalled
        case GitHubCLIError.signedOut: .signedOut
        default: .failed(error.localizedDescription)
        }
    }

    // MARK: Saved

    private static let linksKey = "inbox.issueLinks"

    private static func savedLinks() -> [String: IssueRef] {
        UserDefaults.standard.data(forKey: linksKey)
            .flatMap { try? JSONDecoder().decode([String: IssueRef].self, from: $0) } ?? [:]
    }
}
