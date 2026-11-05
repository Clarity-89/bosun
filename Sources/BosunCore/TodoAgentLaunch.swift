import Foundation

/// The to-do agent's command line: omp in the list's directory, told by a
/// prompt file there that the list is its one artifact, and picking up its
/// last conversation when it starts again.
public struct TodoAgentLaunch: Equatable, Sendable {
    /// omp's fast role: a list keeper needs no more.
    public static let defaultModel = "@smol"
    /// Its conversations, apart from your coding sessions' history.
    static let sessionsDirectory = "agent-sessions"

    /// For `sh`, as libghostty runs it: the login shell, interactive so
    /// `.zshrc` sets its PATH as for `readLoginPath()`, then omp in its
    /// place. Shown when the agent ends, so it can be run by hand to see
    /// why, a missing omp included.
    public let command: String
    /// The list's directory, where omp runs and keeps its conversations.
    public let directory: String
    /// omp's prompt, in the list's directory; Bosun writes it when it is
    /// missing and you may edit it, so a restart reads it again.
    public let instructionsFile: URL
    public let instructions: String

    /// `list` is the to-do file. An empty `model` leaves the choice to
    /// omp's default.
    public init(list: URL, model: String) {
        let directory = list.deletingLastPathComponent()
        self.directory = directory.path
        instructionsFile = directory.appending(path: "todo-agent.md")
        instructions = Self.instructions(list: list.lastPathComponent)
        let model = model.trimmingCharacters(in: .whitespaces)
        let omp = (["omp"]
            + (model.isEmpty ? [] : ["--model", Terminal.shellQuote(model)])
            + [
                // Quick answers: a list edit needs no deep thought.
                "--thinking", "low",
                "--session-dir", Terminal.shellQuote("\(directory.path)/\(Self.sessionsDirectory)"), "--continue",
                // Appended, so omp's own prompt for its tools stays whole.
                "--append-system-prompt", Terminal.shellQuote(instructionsFile.path),
                // Coding skills and a language server for markdown only cost tokens.
                "--no-skills", "--no-lsp",
                "--warn-cost", "2",
            ]).joined(separator: " ")
        command = "/bin/zsh -lic \(Terminal.shellQuote("exec " + omp))"
    }

    static func instructions(list: String) -> String {
        """
        # To-do agent

        You keep one artifact: `\(list)` in this directory, the user's to-do list. Bosun shows \
        it as a checklist beside this terminal and follows the file, so each edit you make shows \
        there at once. The user ticks and types in it too, so read the file again before each edit.

        Format: markdown. `#` headings are sections; `- [ ]` and `- [x]` lines are items, one per \
        line, with inline markdown allowed. Keep the user's order and wording unless asked to \
        change them. Tick items rather than deleting them; when asked to tidy, move ticked items \
        under `# Done`.

        Scope: edit `\(list)` only, and create it if it is missing. Answer in one line that says \
        what changed. To see the user's agent sessions and their branches, run \
        `agent-deck list --json` and `git -C <path> status`.

        """
    }
}
