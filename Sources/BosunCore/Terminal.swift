@preconcurrency import Foundation

public enum Terminal {
    /// `<agent-deck> session attach <id>`, quoted for `sh`.
    public static func attachCommand(executablePath: String, sessionID: String) -> String {
        "\(shellQuote(executablePath)) session attach \(shellQuote(sessionID))"
    }

    /// `open -na` starts a separate Ghostty instance per attach (Ghostty has
    /// no CLI verb for a new window in the running instance). Without
    /// `quit-after-last-window-closed` that instance would outlive its window
    /// and accumulate one orphan process per click.
    static func attachArguments(executablePath: String, sessionID: String) -> [String] {
        [
            "-na", "Ghostty.app", "--args",
            "--quit-after-last-window-closed=true",
            "-e", "/bin/zsh", "-lc", "exec " + attachCommand(executablePath: executablePath, sessionID: sessionID),
        ]
    }

    /// LaunchServices gives Ghostty the login environment, never `open`'s, so
    /// `open` itself runs with ours; nothing in it reaches the attach.
    public static func openAttach(executablePath: String, sessionID: String) async throws {
        let result = try await Subprocess.run(
            executable: "/usr/bin/open",
            arguments: attachArguments(executablePath: executablePath, sessionID: sessionID),
            environment: ProcessInfo.processInfo.environment,
            timeout: .seconds(10)
        )
        try result.checkSucceeded()
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
