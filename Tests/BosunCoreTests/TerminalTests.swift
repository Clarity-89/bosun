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

/// The to-do agent's command, run as libghostty runs it: `sh` must hand omp
/// each path whole, whatever spaces or quotes the directory has.
@Suite struct TodoAgentLaunchTests {
    @Test func shHandsOmpItsArgumentsWhole() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "bosun o'todo \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Stands in for omp: prints each argument it got on a line of its own.
        let omp = directory.appending(path: "omp")
        try "#!/bin/sh\nfor argument in \"$@\"; do printf '%s\\n' \"$argument\"; done\n".write(to: omp, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: omp.path)
        let launch = TodoAgentLaunch(executable: omp.path, model: "@smol", directory: directory.path, path: "/usr/bin:/bin")
        let result = try await Subprocess.run(
            executable: "/bin/sh", arguments: ["-c", "exec " + launch.command], environment: ["PATH": "/usr/bin:/bin"], timeout: .seconds(5)
        )
        #expect(result.stdout.split(separator: "\n").map(String.init) == [
            "--model", "@smol", "--thinking", "low",
            "--session-dir", "\(directory.path)/agent-sessions", "--continue",
            "--append-system-prompt", "\(directory.path)/todo-agent.md",
            "--no-skills", "--no-lsp", "--warn-cost", "2",
        ])
        #expect(launch.environment == ["PATH": "/usr/bin:/bin"])
    }

    @Test func anEmptyModelLeavesTheChoiceToOmp() {
        let launch = TodoAgentLaunch(executable: "/bin/omp", model: "  ", directory: "/d", path: nil)
        #expect(!launch.command.contains("--model"))
        #expect(launch.environment.isEmpty)
    }
}
