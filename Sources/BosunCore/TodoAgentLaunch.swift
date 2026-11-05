import Foundation

/// The to-do agent's command line: omp in the list's directory, told by a
/// prompt file there that the list is its one artifact, and picking up its
/// last conversation when it starts again.
public struct TodoAgentLaunch: Equatable, Sendable {
    /// omp's fast role: a list keeper needs no more.
    public static let defaultModel = "@smol"
    /// In the list's directory; Bosun writes it when it is missing and you
    /// may edit it, so a restart reads it again.
    public static let instructionsFile = "todo-agent.md"
    /// Its conversations, apart from your coding sessions' history.
    static let sessionsDirectory = "agent-sessions"

    public static let instructions = """
        # To-do agent

        You keep one artifact: `todo.md` in this directory, the user's to-do list. Bosun shows \
        it as a checklist beside this terminal and follows the file, so each edit you make shows \
        there at once. The user ticks and types in it too, so read the file again before each edit.

        Format: markdown. `#` headings are sections; `- [ ]` and `- [x]` lines are items, one per \
        line, with inline markdown allowed. Keep the user's order and wording unless asked to \
        change them. Tick items rather than deleting them; when asked to tidy, move ticked items \
        under `# Done`.

        Scope: edit `todo.md` only, and create it if it is missing. Answer in one line that says \
        what changed. To see the user's agent sessions and their branches, run \
        `agent-deck list --json` and `git -C <path> status`.

        """

    /// For `sh`, as libghostty runs it; shown when the agent ends, so it can
    /// be run by hand to see why.
    public let command: String
    /// Added to Bosun's own for the agent: the login shell's PATH, which an
    /// app opened from the Dock lacks and the agent's tools need.
    public let environment: [String: String]

    /// An empty `model` leaves the choice to omp's default.
    init(executable: String, model: String, directory: String, path: String?) {
        let model = model.trimmingCharacters(in: .whitespaces)
        command = ([Terminal.shellQuote(executable)]
            + (model.isEmpty ? [] : ["--model", Terminal.shellQuote(model)])
            + [
                // Quick answers: a list edit needs no deep thought.
                "--thinking", "low",
                "--session-dir", Terminal.shellQuote("\(directory)/\(Self.sessionsDirectory)"), "--continue",
                // Appended, so omp's own prompt for its tools stays whole.
                "--append-system-prompt", Terminal.shellQuote("\(directory)/\(Self.instructionsFile)"),
                // Coding skills and a language server for markdown only cost tokens.
                "--no-skills", "--no-lsp",
                "--warn-cost", "2",
            ]).joined(separator: " ")
        environment = path.map { ["PATH": $0] } ?? [:]
    }

    /// Nil when omp is not on the login shell's PATH.
    public static func resolve(model: String, directory: String) async -> TodoAgentLaunch? {
        await AgentDeckCLI.readLoginPath()
        let environment = AgentDeckCLI.childEnvironment(binaryDirectory: nil, inherited: ProcessInfo.processInfo.environment)
        guard let omp = AgentDeckCLI.executablePaths(named: "omp", environment: environment).first else { return nil }
        return TodoAgentLaunch(executable: omp, model: model, directory: directory, path: environment["PATH"])
    }
}
