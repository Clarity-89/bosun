import BosunCore
import Foundation
import Observation
import os

@MainActor
@Observable
final class DeckModel {
    static let shared = DeckModel()

    var sessions: [DeckSession] = []
    var connection: ConnectionState = .starting
    var statusEventsEnabled = false
    var isRefreshing = false
    var lastError: String?

    @ObservationIgnored private let cli = AgentDeckCLI()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var followerTask: Task<Void, Never>?
    @ObservationIgnored private var reconcileTask: Task<Void, Never>?
    @ObservationIgnored private var delayedRefreshTask: Task<Void, Never>?
    @ObservationIgnored private let defaults = UserDefaults.standard

    private init() {}

    var waitingCount: Int {
        sessions.count(where: { $0.status.needsAttention })
    }

    func start() {
        guard !started else { return }
        started = true
        Task { [weak self] in
            await self?.bootstrap()
        }
    }

    func stop() {
        followerTask?.cancel()
        reconcileTask?.cancel()
        delayedRefreshTask?.cancel()
        followerTask = nil
        reconcileTask = nil
        delayedRefreshTask = nil
    }

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let rows = try await cli.list()
            sessions = rows
                .filter { !$0.archived }
                .sorted { lhs, rhs in
                    let leftGroup = lhs.group ?? ""
                    let rightGroup = rhs.group ?? ""
                    return (leftGroup, lhs.title, lhs.id) < (rightGroup, rhs.title, rhs.id)
                }
            lastError = nil
            BosunLog.logger.info("list loaded \(self.sessions.count, privacy: .public) sessions")
        } catch {
            lastError = error.localizedDescription
            BosunLog.logger.error("list failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func attach(_ session: DeckSession) {
        lastError = nil
        Task { [weak self] in
            do {
                try await self?.cli.openGhosttyAttach(sessionID: session.id)
                BosunLog.logger.info("opened Ghostty for \(session.id, privacy: .public)")
            } catch {
                self?.lastError = error.localizedDescription
                BosunLog.logger.error("Ghostty attach failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func bootstrap() async {
        do {
            if let stale = defaults.object(forKey: "followerPID") as? NSNumber,
               await BusFollower.reapStale(pid: stale.int32Value) {
                BosunLog.logger.info("reaped stale follower \(stale.int32Value, privacy: .public)")
            }
            _ = try await cli.executablePath()
            statusEventsEnabled = try await cli.statusEventsEnabled()
            await refresh()

            let currentCursor = try await cli.eventsStats().cursor
            let cursor = savedCursor() ?? currentCursor
            if cursor > currentCursor {
                storeCursor(currentCursor)
                BosunLog.logger.info("reset future cursor to \(currentCursor, privacy: .public)")
            } else if savedCursor() == nil {
                storeCursor(cursor)
            }

            startFollower(after: min(cursor, currentCursor))
            startReconcileLoop()
        } catch {
            connection = .failed(error.localizedDescription)
            lastError = error.localizedDescription
            BosunLog.logger.error("startup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func startFollower(after initialCursor: UInt64) {
        followerTask?.cancel()
        followerTask = Task { [weak self] in
            await self?.followLoop(after: initialCursor)
        }
    }

    private func followLoop(after initialCursor: UInt64) async {
        var cursor = initialCursor
        var retryDelay: UInt64 = 1

        while !Task.isCancelled {
            do {
                connection = .reconnecting
                let stream = try await cli.follow(after: cursor) { pid in
                    UserDefaults.standard.set(NSNumber(value: pid), forKey: "followerPID")
                }
                connection = .live(cursor)
                retryDelay = 1
                BosunLog.logger.info("follower live after \(cursor, privacy: .public)")

                for try await frame in stream {
                    if Task.isCancelled { return }
                    cursor = max(cursor, frame.cursor)
                    storeCursor(cursor)
                    apply(frame)
                }

                if !Task.isCancelled {
                    throw BusFollowerError.exited(0, "event follower ended")
                }
            } catch is CancellationError {
                return
            } catch BusFollowerError.cursorTooOld {
                do {
                    cursor = try await cli.eventsStats().cursor
                    storeCursor(cursor)
                    await refresh()
                    BosunLog.logger.info("follower resynced at \(cursor, privacy: .public)")
                } catch {
                    lastError = error.localizedDescription
                }
            } catch {
                if Task.isCancelled { return }
                connection = .reconnecting
                lastError = error.localizedDescription
                BosunLog.logger.error("follower failed: \(error.localizedDescription, privacy: .public)")
                await sleep(seconds: retryDelay)
                retryDelay = min(retryDelay * 2, 30)
            }
        }
    }

    private func startReconcileLoop() {
        reconcileTask?.cancel()
        reconcileTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sleep(seconds: 60)
                if Task.isCancelled { return }
                await self?.refresh()
            }
        }
    }

    private func apply(_ frame: BusFrame) {
        guard frame.kind == "session.status", let sessionID = frame.sessionID else { return }
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else {
            scheduleRefresh()
            return
        }
        guard let destination = frame.data?.to else { return }
        sessions[index].status = SessionStatus(rawValue: destination.lowercased()) ?? .unknown
        sessions[index].statusSource = "bus"
        if let substate = frame.data?.substate {
            sessions[index].substate = substate
        }
        if let tool = frame.data?.tool {
            sessions[index].tool = tool
        }
        if let tmuxSession = frame.data?.tmuxSession {
            sessions[index].tmuxSession = tmuxSession
        }
        if let changedAt = frame.data?.changedAt {
            sessions[index].lastActivityAt = changedAt
        }
        connection = .live(frame.cursor)
        BosunLog.logger.info("status \(sessionID, privacy: .public) -> \(destination, privacy: .public)")
    }

    private func scheduleRefresh() {
        guard delayedRefreshTask == nil else { return }
        delayedRefreshTask = Task { [weak self] in
            await self?.sleep(seconds: 5)
            guard !Task.isCancelled else { return }
            await self?.refresh()
            self?.delayedRefreshTask = nil
        }
    }

    private func savedCursor() -> UInt64? {
        guard let number = defaults.object(forKey: "busCursor") as? NSNumber else { return nil }
        return number.uint64Value
    }

    private func storeCursor(_ cursor: UInt64) {
        defaults.set(NSNumber(value: cursor), forKey: "busCursor")
    }

    private func sleep(seconds: UInt64) async {
        try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
    }
}

enum ConnectionState: Equatable, Sendable {
    case starting
    case live(UInt64)
    case reconnecting
    case failed(String)

    var label: String {
        switch self {
        case .starting: "Starting"
        case .live(let cursor): "Live · \(cursor)"
        case .reconnecting: "Reconnecting"
        case .failed: "Unavailable"
        }
    }
}
