@preconcurrency import Foundation

public struct ProcessResult: Sendable {
    /// Executable name and arguments, for messages.
    public let command: String
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool { status == 0 }

    public func checkSucceeded() throws {
        guard !succeeded else { return }
        throw SubprocessError.exited(command: command, status: status, stderr: stderr)
    }
}

public enum SubprocessError: Error, LocalizedError, Sendable {
    case launchFailed(command: String, reason: String)
    case timedOut(command: String)
    case exited(command: String, status: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let command, let reason):
            return "\(command): \(reason)"
        case .timedOut(let command):
            return "\(command) timed out"
        case .exited(let command, let status, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "\(command) exited with status \(status)" : detail
        }
    }
}

public enum Subprocess {
    /// Runs to exit, collecting both pipes. The child is terminated when the
    /// timeout elapses or the calling task is cancelled.
    public static func run(
        executable: String,
        arguments: [String] = [],
        environment: [String: String],
        timeout: Duration = .seconds(30)
    ) async throws -> ProcessResult {
        let child = try Child(executable: executable, arguments: arguments, environment: environment)
        async let stdout = child.stdoutData()
        async let stderr = child.stderrData()
        let status: Int32
        do {
            status = try await withThrowingTaskGroup(of: Int32.self) { group in
                group.addTask { try await child.exitStatus() }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw SubprocessError.timedOut(command: child.command)
                }
                defer { group.cancelAll() }
                // Two tasks were added, so the first result is never nil.
                return try await group.next()!
            }
        } catch {
            child.terminate()
            throw error
        }
        return await ProcessResult(
            command: child.command,
            status: status,
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self)
        )
    }

    /// Stdout lines of a process expected to run until stopped. Any exit is
    /// an error (`exited`, with the collected stderr). Cancelling the consumer
    /// or dropping the iterator terminates the child.
    public static func lines(
        executable: String,
        arguments: [String] = [],
        environment: [String: String]
    ) throws -> ProcessLines {
        ProcessLines(child: try Child(executable: executable, arguments: arguments, environment: environment))
    }
}

public struct ProcessLines: AsyncSequence, Sendable {
    public typealias Element = String

    private let child: Child

    fileprivate init(child: Child) {
        self.child = child
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(child: child)
    }

    /// A class so that the child dies with the iterator, however the consumer
    /// stops: a producer task holding a stream continuation would outlive it.
    public final class Iterator: AsyncIteratorProtocol {
        private let child: Child
        private var chunks: AsyncStream<Data>.Iterator
        private let stderr: Task<Data, Never>
        private var pending = Data()
        private var lines: [String] = []

        fileprivate init(child: Child) {
            self.child = child
            chunks = child.stdoutChunks.makeAsyncIterator()
            // Drained from the start so a chatty child never blocks on a full pipe.
            stderr = Task { await child.stderrData() }
        }

        deinit {
            child.terminate()
        }

        public func next() async throws -> String? {
            while lines.isEmpty {
                guard let chunk = await chunks.next() else {
                    try Task.checkCancellation()
                    if !pending.isEmpty {
                        defer { pending.removeAll() }
                        return String(decoding: pending, as: UTF8.self)
                    }
                    let status = try await child.exitStatus()
                    throw SubprocessError.exited(
                        command: child.command,
                        status: status,
                        stderr: String(decoding: await stderr.value, as: UTF8.self)
                    )
                }
                pending.append(chunk)
                var parts = pending.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
                pending = Data(parts.removeLast())
                lines = parts.filter { !$0.isEmpty }.map { String(decoding: $0, as: UTF8.self) }
            }
            return lines.removeFirst()
        }
    }
}

private final class Child: @unchecked Sendable {
    let command: String
    private let process = Process()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let exit: AsyncStream<Int32>

    init(executable: String, arguments: [String], environment: [String: String]) throws {
        command = ([URL(fileURLWithPath: executable).lastPathComponent] + arguments).joined(separator: " ")
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = stderr
        let (exit, exited) = AsyncStream.makeStream(of: Int32.self)
        self.exit = exit
        // Installed before run(), so an exit before the first await is not missed.
        process.terminationHandler = { process in
            exited.yield(process.terminationStatus)
            exited.finish()
        }
        do {
            try process.run()
        } catch {
            throw SubprocessError.launchFailed(command: command, reason: error.localizedDescription)
        }
    }

    var stdoutChunks: AsyncStream<Data> {
        chunks(of: stdout.fileHandleForReading)
    }

    func stdoutData() async -> Data {
        await chunks(of: stdout.fileHandleForReading).reduce(into: Data()) { $0.append($1) }
    }

    func stderrData() async -> Data {
        await chunks(of: stderr.fileHandleForReading).reduce(into: Data()) { $0.append($1) }
    }

    /// Chunks until EOF via the readability handler (a dispatch source), so no
    /// thread sits in read(2). `FileHandle.bytes` blocks one per reader, and
    /// two concurrent readers wedge each other.
    ///
    /// Cancelling the reader terminates the child right inside `cancel()`:
    /// a quitting app does not come back to run the reader's unwinding.
    private func chunks(of handle: FileHandle) -> AsyncStream<Data> {
        AsyncStream { continuation in
            handle.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(chunk)
                }
            }
            continuation.onTermination = { reason in
                handle.readabilityHandler = nil
                if case .cancelled = reason { self.terminate() }
            }
        }
    }

    /// Throws `CancellationError` when the awaiting task is cancelled first;
    /// `terminationStatus` must not be read while the child still runs.
    func exitStatus() async throws -> Int32 {
        for await status in exit { return status }
        throw CancellationError()
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }
}
