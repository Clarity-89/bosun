@preconcurrency import Foundation

public enum Terminal {
    /// `open -na` starts a separate Ghostty instance per attach (Ghostty has
    /// no CLI verb for a new window in the running instance). Without
    /// `quit-after-last-window-closed` that instance would outlive its window
    /// and accumulate one orphan process per click.
    public static func attachArguments(executablePath: String, sessionID: String) -> [String] {
        let command = "exec \(shellQuote(executablePath)) session attach \(shellQuote(sessionID))"
        return [
            "-na", "Ghostty.app", "--args",
            "--quit-after-last-window-closed=true",
            "-e", "/bin/zsh", "-lc", command,
        ]
    }

    public static func openAttach(
        executablePath: String,
        sessionID: String,
        environment: [String: String]
    ) async throws -> ProcessResult {
        try await ProcessRunner.run(
            executable: "/usr/bin/open",
            arguments: attachArguments(executablePath: executablePath, sessionID: sessionID),
            environment: environment,
            timeout: 10
        )
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
