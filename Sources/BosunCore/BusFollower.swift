@preconcurrency import Foundation

public enum BusFollower {
    public static func stream(
        executable: String,
        environment: [String: String],
        after cursor: UInt64,
        onStart: (@Sendable (pid_t) -> Void)? = nil
    ) -> AsyncThrowingStream<BusFrame, Error> {
        AsyncThrowingStream { continuation in
            let process = FollowerProcess(
                executable: executable,
                environment: environment,
                after: cursor
            )

            let task = Task {
                do {
                    try process.start()
                    onStart?(process.pid)
                    for try await line in process.stdout.fileHandleForReading.bytes.lines {
                        if Task.isCancelled { break }
                        let data = Data(line.utf8)
                        do {
                            let frame = try JSONDecoder().decode(BusFrame.self, from: data)
                            continuation.yield(frame)
                        } catch {
                            throw BusFollowerError.invalidFrame(line)
                        }
                    }
                    process.waitUntilExit()
                    process.stopReadingStderr()
                    if !Task.isCancelled && process.status != 0 {
                        let stderr = process.stderrText
                        if BusFollower.isCursorTooOld(stderr) {
                            throw BusFollowerError.cursorTooOld
                        }
                        throw BusFollowerError.exited(process.status, stderr)
                    }
                    continuation.finish()
                } catch {
                    process.terminate()
                    process.stopReadingStderr()
                    if !Task.isCancelled {
                        continuation.finish(throwing: error)
                    } else {
                        continuation.finish()
                    }
                }
            }

            continuation.onTermination = { @Sendable _ in
                process.terminate()
                task.cancel()
            }
        }
    }

    /// Kills a follower left behind by a previous process that died without
    /// cleanup (crash, SIGKILL). Only a live pid whose command line is an
    /// `agent-deck events follow` is touched; pid reuse by another program
    /// is therefore harmless.
    public static func reapStale(pid: pid_t) async -> Bool {
        guard pid > 0, kill(pid, 0) == 0 else { return false }
        guard let result = try? await ProcessRunner.run(
            executable: "/bin/ps",
            arguments: ["-o", "command=", "-p", String(pid)],
            environment: ["PATH": "/bin:/usr/bin"],
            timeout: 5
        ), result.stdout.contains("agent-deck events follow") || result.stdout.contains(" events follow --json") else {
            return false
        }
        return kill(pid, SIGTERM) == 0
    }

    public static func isCursorTooOld(_ message: String) -> Bool {
        let value = message.lowercased()
        return value.contains("cursor too old")
            || value.contains("cursor older than the retained log")
            || value.contains("cursor_too_old")
    }
}

private final class FollowerProcess: @unchecked Sendable {
    let process: Process
    let stdout: Pipe
    private let stderr: Pipe
    private let stderrData = LockedData()

    init(executable: String, environment: [String: String], after cursor: UInt64) {
        process = Process()
        stdout = Pipe()
        stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [
            "events", "follow", "--json",
            "--after", String(cursor),
            "--kind", "session.status,session.turn",
        ]
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = stderr
    }

    func start() throws {
        let handle = stderr.fileHandleForReading
        let stderrData = stderrData
        handle.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { stderrData.append(data) }
        }
        do {
            try process.run()
        } catch {
            handle.readabilityHandler = nil
            throw ProcessRunnerError.launchFailed(error.localizedDescription)
        }
    }

    func waitUntilExit() {
        process.waitUntilExit()
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    func stopReadingStderr() {
        stderr.fileHandleForReading.readabilityHandler = nil
        stderrData.append(stderr.fileHandleForReading.availableData)
    }

    var status: Int32 { process.terminationStatus }
    var pid: pid_t { process.processIdentifier }
    var stderrText: String { String(decoding: stderrData.value, as: UTF8.self) }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    func append(_ value: Data) {
        guard !value.isEmpty else { return }
        lock.lock()
        data.append(value)
        lock.unlock()
    }
}
