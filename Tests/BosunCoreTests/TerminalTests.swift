import Foundation
import Testing
@testable import BosunCore

/// The command libghostty runs as `sh -c "exec <command>"`; agent-deck's
/// session ids and the binary path must survive `sh` quoting.
@Suite struct AttachCommandTests {
    /// No `exec` of its own: libghostty adds one, and a second yields
    /// "exec: exec: not found".
    @Test func quotesPathAndSessionForSh() {
        let command = Terminal.attachCommand(executablePath: "/Users/me/.local/bin/agent-deck", sessionID: "8fdb4c7d-1792761516")
        #expect(command == "'/Users/me/.local/bin/agent-deck' session attach '8fdb4c7d-1792761516'")
    }

    @Test func escapesSingleQuotesInsideQuotedWords() {
        let command = Terminal.attachCommand(executablePath: "/Users/o'brien/agent-deck", sessionID: "id")
        #expect(command.hasPrefix("'/Users/o'\\''brien/agent-deck' "))
    }

    @Test func ghosttyPopOutUsesExecOnceAndQuitsWithItsWindow() {
        let arguments = Terminal.attachArguments(executablePath: "/x/agent-deck", sessionID: "y")
        #expect(arguments.contains("--quit-after-last-window-closed=true"))
        #expect(arguments.last?.hasPrefix("exec '/x/agent-deck' session attach") == true)
    }
}

/// The to-do agent's command, run as libghostty runs it: `sh` starts the
/// login shell, whose rc files set PATH, and omp gets each path whole,
/// whatever spaces or quotes the directory has. `ZDOTDIR` points zsh at rc
/// files of the test's own, so the user's never run.
@Suite struct TodoAgentLaunchTests {
    @Test func theLoginShellFindsOmpAndHandsItItsArgumentsWhole() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "bosun o'todo \(UUID().uuidString)")
        let bin = directory.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Stands in for omp: prints each argument it got on a line of its own.
        let omp = bin.appending(path: "omp")
        try "#!/bin/sh\nfor argument in \"$@\"; do printf '%s\\n' \"$argument\"; done\n".write(to: omp, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: omp.path)
        // As an installer adds its directory to .zshrc.
        try "export PATH=\(Terminal.shellQuote(bin.path)):$PATH\n".write(to: directory.appending(path: ".zshrc"), atomically: true, encoding: .utf8)
        let launch = TodoAgentLaunch(list: directory.appending(path: "todo.md"), model: "@smol")
        let result = try await Subprocess.run(
            executable: "/bin/sh", arguments: ["-c", "exec " + launch.command],
            environment: ["PATH": "/usr/bin:/bin", "HOME": directory.path, "ZDOTDIR": directory.path], timeout: .seconds(10)
        )
        #expect(result.stdout.split(separator: "\n").map(String.init) == [
            "--model", "@smol", "--thinking", "low",
            "--session-dir", "\(directory.path)/agent-sessions", "--continue",
            "--append-system-prompt", "\(directory.path)/todo-agent.md",
            "--no-skills", "--no-lsp", "--warn-cost", "2",
        ])
    }

    /// The prompt names the list as the file is called, so the agent and
    /// the list never disagree on it.
    @Test func anEmptyModelLeavesTheChoiceToOmpAndThePromptNamesTheList() {
        let launch = TodoAgentLaunch(list: URL(fileURLWithPath: "/d/later.md"), model: "  ")
        #expect(!launch.command.contains("--model"))
        #expect(launch.directory == "/d")
        #expect(launch.instructionsFile.path == "/d/todo-agent.md")
        #expect(launch.instructions.contains("`later.md`"))
    }
}
