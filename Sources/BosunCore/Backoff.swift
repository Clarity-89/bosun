/// Tries again after a failure that may pass: after `firstDelay`, then
/// twice as long each time, `retries` times, then gives up with the last
/// error.
struct Backoff: Sendable {
    var retries = 3
    var firstDelay: Duration = .seconds(1)

    /// `operation` until it succeeds, fails in a way `isTransient` rules
    /// out, or the retries run out. Cancelling ends a wait at once.
    func run<T>(
        retrying isTransient: (any Error) -> Bool,
        onRetry: (_ error: any Error, _ delay: Duration) -> Void = { _, _ in },
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        _ operation: () async throws -> T
    ) async throws -> T {
        var delay = firstDelay
        for _ in 0..<retries {
            do {
                return try await operation()
            } catch {
                guard isTransient(error) else { throw error }
                onRetry(error, delay)
                try await sleep(delay)
                delay *= 2
            }
        }
        return try await operation()
    }
}
