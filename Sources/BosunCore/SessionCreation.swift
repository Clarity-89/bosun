import Foundation

/// What `add` creates. An empty field leaves agent-deck its own default.
public struct NewSessionRequest: Sendable, Equatable {
    /// Empty: the directory's name.
    public var title: String
    /// `~` is expanded.
    public var directory: String
    /// A group's `path`; empty: agent-deck's default group.
    public var groupPath: String
    /// As typed in a shell, arguments included. agent-deck picks the harness
    /// from it (claude, codex, omp, …); anything else, or nothing, is a
    /// plain shell.
    public var command: String
    /// The branch for the session's git worktree; nil for no worktree.
    public var worktreeBranch: String?
    /// Creates `worktreeBranch` rather than checking it out.
    public var createBranch: Bool
    /// A quick session: agent-deck generates the title.
    public var quick: Bool

    public init(
        title: String = "",
        directory: String,
        groupPath: String = "",
        command: String,
        worktreeBranch: String? = nil,
        createBranch: Bool = false,
        quick: Bool = false
    ) {
        self.title = title
        self.directory = directory
        self.groupPath = groupPath
        self.command = command
        self.worktreeBranch = worktreeBranch
        self.createBranch = createBranch
        self.quick = quick
    }
}

/// What `add` made: the session, and agent-deck's word on the repository's
/// worktree setup hook when it did not do its job.
public struct AddedSession: Equatable, Sendable {
    public let id: String
    /// agent-deck's line on a hook it skipped as not approved, or that
    /// failed or timed out. Nil without a hook, or when it ran clean.
    public let setupHookNotice: String?
}

/// A group from `group list --json`, empty ones included. A subgroup's
/// `label` names its parents too.
public struct DeckGroup: Identifiable, Equatable, Sendable {
    public let path: String
    public let label: String

    public var id: String { path }

    /// agent-deck's `DefaultGroupPath`: where a session without a group goes,
    /// and the one group it will not delete.
    public static let defaultPath = "my-sessions"

    /// `path` when `groups` lists it, else the first group's; `path` as it
    /// is when there is no list to go by.
    public static func listedPath(_ path: String, in groups: [DeckGroup]) -> String {
        groups.isEmpty || groups.contains { $0.path == path } ? path : groups[0].path
    }
}

extension AgentDeckCLI {
    public func groups() async throws -> [DeckGroup] {
        try Self.decodeGroups(Data(try await run(["group", "list", "--json"]).stdout.utf8))
    }

    /// Adds the session without starting it. A refusal arrives as
    /// `AgentDeckCLIError.reported` with agent-deck's message.
    public func addSession(_ request: NewSessionRequest) async throws -> AddedSession {
        // A worktree is a `git worktree add`, which in a large repository
        // runs well past the 30 s every other command gets.
        let result = try await run(Self.addArguments(request), timeout: .seconds(300))
        return try Self.addedSession(stdout: result.stdout, stderr: result.stderr)
    }

    /// The reply is the JSON object stdout ends with: a worktree setup hook
    /// writes to the same stdout before it, under `--json` too, so the
    /// first line that opens an object and parses to the end is the reply.
    /// Its outcome lines go to stderr, as agent-deck's TUI shows them.
    static func addedSession(stdout: String, stderr: String) throws -> AddedSession {
        let decoder = jsonDecoder()
        var reply: AddReply?
        var lineStart = stdout.startIndex
        while reply == nil, lineStart < stdout.endIndex {
            if stdout[lineStart] == "{" {
                reply = try? decoder.decode(AddReply.self, from: Data(stdout[lineStart...].utf8))
            }
            guard let newline = stdout[lineStart...].firstIndex(where: \.isNewline) else { break }
            lineStart = stdout.index(after: newline)
        }
        let id = try reply?.id ?? decoder.decode(AddReply.self, from: Data(stdout.utf8)).id
        let notice = stderr.split(whereSeparator: \.isNewline).lazy.compactMap { line -> String? in
            if line.hasPrefix("worktree setup hook not run:") { return String(line) }
            if line.hasPrefix("Warning: worktree setup script failed:") { return String(line.dropFirst("Warning: ".count)) }
            return nil
        }.first
        return AddedSession(id: id, setupHookNotice: notice)
    }

    static func addArguments(_ request: NewSessionRequest) -> [String] {
        var arguments = ["add", "--json"]
        let title = request.title.trimmingCharacters(in: .whitespaces)
        if request.quick {
            arguments.append("--quick")
        } else if !title.isEmpty {
            arguments += ["-t", title]
        }
        if !request.groupPath.isEmpty {
            arguments += ["-g", request.groupPath]
        }
        let command = request.command.trimmingCharacters(in: .whitespaces)
        if !command.isEmpty {
            arguments += ["-c", command]
        }
        if let branch = request.worktreeBranch?.trimmingCharacters(in: .whitespaces), !branch.isEmpty {
            arguments += ["-w", branch]
            if request.createBranch {
                arguments.append("-b")
            }
        }
        let directory = request.directory.trimmingCharacters(in: .whitespaces)
        arguments.append((directory as NSString).expandingTildeInPath)
        return arguments
    }

    /// The tree flattened depth first, so a subgroup follows its parent.
    static func decodeGroups(_ json: Data) throws -> [DeckGroup] {
        func flatten(_ nodes: [GroupNode], parents: [String]) -> [DeckGroup] {
            nodes.flatMap { node in
                let names = parents + [node.name]
                return [DeckGroup(path: node.path, label: names.joined(separator: " › "))]
                    + flatten(node.children ?? [], parents: names)
            }
        }
        return flatten(try JSONDecoder().decode(GroupList.self, from: json).groups, parents: [])
    }
}

private struct AddReply: Decodable {
    let id: String
}

private struct GroupList: Decodable {
    let groups: [GroupNode]
}

private struct GroupNode: Decodable {
    let name: String
    let path: String
    let children: [GroupNode]?
}
