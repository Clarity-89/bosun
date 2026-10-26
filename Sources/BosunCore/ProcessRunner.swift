@preconcurrency import Foundation
import Dispatch

public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool { status == 0 }
}

public enum ProcessRunner {
    public static func run(
        executable: String,
        arguments: [String] = [],
        environment: [String: String],
        timeout: TimeInterval? = 30
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments
                    process.environment = environment

                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe
                    try process.run()

                    let output = LockedData()
                    let errors = LockedData()
                    let readers = DispatchGroup()

                    readers.enter()
                    DispatchQueue.global(qos: .utility).async {
                        output.replace(with: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                        readers.leave()
                    }
                    readers.enter()
                    DispatchQueue.global(qos: .utility).async {
                        errors.replace(with: stderrPipe.fileHandleForReading.readDataToEndOfFile())
                        readers.leave()
                    }

                    let deadline = timeout.map { Date().addingTimeInterval($0) }
                    var timedOut = false
                    while process.isRunning {
                        if let deadline, Date() >= deadline {
                            timedOut = true
                            process.terminate()
                            break
                        }
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                    process.waitUntilExit()
                    readers.wait()

                    if timedOut {
                        continuation.resume(throwing: ProcessRunnerError.timedOut(
                            ([executable] + arguments).joined(separator: " ")
                        ))
                        return
                    }

                    continuation.resume(returning: ProcessResult(
                        status: process.terminationStatus,
                        stdout: String(decoding: output.value, as: UTF8.self),
                        stderr: String(decoding: errors.value, as: UTF8.self)
                    ))
                } catch {
                    continuation.resume(throwing: ProcessRunnerError.launchFailed(error.localizedDescription))
                }
            }
        }
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    func replace(with value: Data) {
        lock.lock()
        data = value
        lock.unlock()
    }
}
