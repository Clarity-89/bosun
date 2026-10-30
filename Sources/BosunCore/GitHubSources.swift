@preconcurrency import Foundation
import os

private let gitHubLog = Logger(subsystem: "com.bosun.Bosun", category: "GitHub")

public enum GitHubCLIError: Error, LocalizedError, Equatable, Sendable {
    case notInstalled
    case signedOut
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled: "GitHub CLI (gh) is not installed"
        case .signedOut: "GitHub CLI is not signed in; run gh auth login"
        case .failed(let message): message
        }
    }
}

/// GitHub through `gh api graphql`, which owns the sign-in: Bosun keeps no
/// token of its own.
public struct GitHubCLI: Sendable {
    public init() {}

    /// Two requests at once: as one, GitHub's gateway times out.
    public func inbox() async throws -> GitHubInbox {
        async let pullRequests = run(GitHubQueries.inboxPullRequests)
        async let issues = run(GitHubQueries.inboxIssues)
        return try GitHubInbox(pullRequestsGraphQL: try await pullRequests, issuesGraphQL: try await issues)
    }

    /// Each branch's pull requests.
    public func pullRequests(forBranches branches: [BranchRef]) async throws -> [BranchRef: [GitHubPullRequest]] {
        guard !branches.isEmpty else { return [:] }
        return try GitHubQueries.decodePullRequests(
            try await run(GitHubQueries.pullRequests(forBranches: branches)), forBranches: branches
        )
    }

    public func issues(_ refs: [IssueRef]) async throws -> [GitHubIssue?] {
        guard !refs.isEmpty else { return [] }
        return try GitHubQueries.decodeIssues(try await run(GitHubQueries.issues(refs)), count: refs.count)
    }

    /// Up to three more tries, 1 s, 2 s and 4 s apart: gh often cannot reach
    /// GitHub for a moment, as while the network comes up at launch.
    private static let backoff = Backoff()

    private func run(_ request: GraphQLRequest) async throws -> Data {
        try await Self.backoff.run(retrying: Self.isTransient, onRetry: { error, delay in
            gitHubLog.info("GitHub request failed, retrying in \(delay, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }) {
            try await attempt(request)
        }
    }

    /// What another try can fix: gh not reaching GitHub (a dial timeout, a
    /// 502) or not finishing in time. A missing gh or sign-in stays missing,
    /// and an answer GitHub gave, errors and all, is its answer.
    static func isTransient(_ error: any Error) -> Bool {
        switch error {
        case GitHubCLIError.failed, SubprocessError.timedOut: true
        default: false
        }
    }

    /// gh exits non-zero when GitHub answers with errors, partial data
    /// included; any JSON on stdout goes to the decoder, which keeps what
    /// came.
    private func attempt(_ request: GraphQLRequest) async throws -> Data {
        guard let gh = try? AgentDeckCLI.executablePath(named: "gh") else { throw GitHubCLIError.notInstalled }
        let result = try await Subprocess.run(
            executable: gh, arguments: request.arguments, environment: Self.environment(), timeout: .seconds(30)
        )
        if result.stdout.first == "{" {
            return Data(result.stdout.utf8)
        }
        let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        // gh exits 1 for a missing login as for anything else; its message
        // is the only tell.
        if detail.contains("gh auth login") || detail.contains("not logged") || detail.contains("HTTP 401") {
            throw GitHubCLIError.signedOut
        }
        throw GitHubCLIError.failed(detail.isEmpty ? "gh exited with status \(result.status)" : detail)
    }

    /// The agent-deck child environment, plus whatever tells gh which host
    /// and token to use when the launching environment has it.
    static func environment(inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = AgentDeckCLI.childEnvironment(binaryDirectory: nil, inherited: inherited)
        for key in ["GH_TOKEN", "GITHUB_TOKEN", "GH_HOST", "GH_CONFIG_DIR", "GH_ENTERPRISE_TOKEN"] {
            if let value = inherited[key], !value.isEmpty { environment[key] = value }
        }
        environment["GH_PROMPT_DISABLED"] = "1"
        return environment
    }
}

public enum GitRepo {
    /// The branch of the work tree at `path` and where it pushes; nil when
    /// `path` is not in one. Reads refs only, never the index: `git status`
    /// takes seconds on a large repository.
    public static func info(path: String) async -> GitRepoInfo? {
        guard let head = await git(path, ["rev-parse", "--abbrev-ref", "HEAD"]) else { return nil }
        async let origin = git(path, ["remote", "get-url", "origin"])
        async let upstream = git(path, ["remote", "get-url", "upstream"])
        async let originHead = git(path, ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"])
        async let ahead = git(path, ["rev-list", "--count", "@{upstream}..HEAD"])
        let defaultBranch = await originHead.map { $0.hasPrefix("origin/") ? String($0.dropFirst("origin/".count)) : $0 }
        var unpushed = await ahead.flatMap { Int($0) }
        if unpushed == nil, let defaultBranch {
            unpushed = await git(path, ["rev-list", "--count", "origin/\(defaultBranch)..HEAD"]).flatMap { Int($0) }
        }
        let repos = [await origin, await upstream].compactMap { $0.flatMap(RepoSlug.init(remoteURL:)) }
        return GitRepoInfo(
            branch: head == "HEAD" ? nil : head,
            defaultBranch: defaultBranch,
            repos: repos.reduce(into: []) { if !$0.contains($1) { $0.append($1) } },
            unpushed: unpushed
        )
    }

    /// Trimmed stdout, nil on any failure.
    private static func git(_ path: String, _ arguments: [String]) async -> String? {
        guard let executable = try? AgentDeckCLI.executablePath(named: "git") else { return nil }
        var environment = AgentDeckCLI.childEnvironment(binaryDirectory: nil)
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        guard let result = try? await Subprocess.run(
            executable: executable, arguments: ["-C", path] + arguments, environment: environment, timeout: .seconds(5)
        ), result.succeeded else { return nil }
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }
}
