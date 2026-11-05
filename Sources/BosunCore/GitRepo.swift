@preconcurrency import Foundation

/// Plain questions to git about a work tree. What Bosun makes of the
/// answers is the app's business.
public enum GitRepo {
    /// The branch of the work tree at `path` and where it pushes; nil when
    /// `path` is not in one. Reads refs only, never the index: `git status`
    /// takes seconds on a large repository.
    public static func info(path: String) async -> GitRepoInfo? {
        guard let head = try? await git(path, ["rev-parse", "--abbrev-ref", "HEAD"]) else { return nil }
        async let origin = try? git(path, ["remote", "get-url", "origin"])
        async let upstream = try? git(path, ["remote", "get-url", "upstream"])
        async let originHead = try? git(path, ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"])
        async let ahead = try? git(path, ["rev-list", "--count", "@{upstream}..HEAD"])
        let defaultBranch = await originHead.map { $0.hasPrefix("origin/") ? String($0.dropFirst("origin/".count)) : $0 }
        var unpushed = await ahead.flatMap { Int($0) }
        if unpushed == nil, let defaultBranch {
            unpushed = (try? await git(path, ["rev-list", "--count", "origin/\(defaultBranch)..HEAD"])).flatMap { Int($0) }
        }
        let repos = [await origin, await upstream].compactMap { $0.flatMap(RepoSlug.init(remoteURL:)) }
        return GitRepoInfo(
            branch: head == "HEAD" ? nil : head,
            defaultBranch: defaultBranch,
            repos: repos.reduce(into: []) { if !$0.contains($1) { $0.append($1) } },
            unpushed: unpushed
        )
    }

    /// Each line of `git status --porcelain` for the work tree at `path`,
    /// untracked files included; empty when clean, nil when `path` is not
    /// in a repository. Unlike `info` this stats every tracked file, which
    /// a large repository makes slow, so a caller asks for one directory at
    /// a time.
    public static func status(path: String) async throws -> [String]? {
        try await git(path, ["status", "--porcelain", "--untracked-files=normal"])?
            .split(separator: "\n").map(String.init)
    }

    /// `git diff -U0 HEAD` for `files` under `path`, with no `a/` and `b/`
    /// on the paths in its headers, whatever the user's git config says.
    /// Nil when `path` is not in a repository.
    public static func diff(path: String, files: [String]) async throws -> String? {
        try await git(path, ["diff", "-U0", "--no-prefix", "HEAD", "--"] + files)
    }

    /// Stdout without its final newline; nil when git ran and said no, as
    /// outside a repository. Throws when git gave no answer: not found, or
    /// out of time. Spaces stay: a porcelain line's first column may be one.
    private static func git(_ path: String, _ arguments: [String]) async throws -> String? {
        let executable = try AgentDeckCLI.executablePath(named: "git")
        var environment = AgentDeckCLI.childEnvironment(binaryDirectory: nil, inherited: ProcessInfo.processInfo.environment)
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        let result = try await Subprocess.run(
            executable: executable, arguments: ["-C", path] + arguments, environment: environment, timeout: .seconds(5)
        )
        guard result.succeeded else { return nil }
        return result.stdout.trimmingCharacters(in: .newlines)
    }
}
