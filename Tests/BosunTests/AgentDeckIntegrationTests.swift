import Foundation
import Testing
@testable import Bosun
@testable import BosunCore

/// A home and a tmux server for one test, apart from the user's: agent-deck
/// keeps its state under the sandbox `HOME`'s XDG paths and runs its
/// sessions on the server `TMUX_TMPDIR` names, and Bosun's own tmux calls
/// land there too. `tearDown()` ends the server and removes it all.
@MainActor
final class Sandbox {
    let root: URL
    let project: String
    let cli: AgentDeckCLI

    init() throws {
        // Under /tmp, not the per-user temporary directory: a Unix socket
        // path is 104 bytes at most, and tmux's goes under `TMUX_TMPDIR`.
        root = URL(fileURLWithPath: "/tmp/bosun-integration-\(UUID().uuidString.prefix(8))")
        let home = root.appending(path: "home")
        let tmux = root.appending(path: "tmux")
        let project = root.appending(path: "project")
        let config = home.appending(path: ".config/agent-deck")
        for directory in [home, tmux, project, config] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // Off by default; without it Bosun would list every minute and never follow.
        try "[macapp]\nstatus_events = true\n".write(to: config.appending(path: "config.toml"), atomically: true, encoding: .utf8)
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["TMUX_TMPDIR"] = tmux.path
        for key in ["XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "AGENTDECK_PROFILE", "CLAUDE_CONFIG_DIR", "CODEX_HOME"] {
            environment[key] = nil
        }
        self.project = project.path
        cli = AgentDeckCLI(environment: environment)
    }

    /// A shell session that stays up until stopped.
    var request: NewSessionRequest {
        NewSessionRequest(title: "probe", directory: project, command: "sleep 600")
    }

    /// Makes `project` a git repository with one commit, for worktrees.
    func makeRepository() async throws {
        try await git(["init", "-q", "-b", "main"])
        try await git(["-c", "user.email=bosun@test", "-c", "user.name=bosun", "commit", "-q", "--allow-empty", "-m", "init"])
    }

    @discardableResult
    func git(_ arguments: [String]) async throws -> String {
        let result = try await Subprocess.run(
            executable: "/usr/bin/git", arguments: ["-C", project] + arguments,
            environment: ["HOME": root.appending(path: "home").path, "PATH": "/usr/bin:/bin"]
        )
        try result.checkSucceeded()
        return result.stdout
    }

    func tearDown() async {
        _ = try? await cli.tmux(["kill-server"])
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private func withSandbox(_ body: (Sandbox) async throws -> Void) async throws {
    let sandbox = try Sandbox()
    do {
        try await body(sandbox)
    } catch {
        await sandbox.tearDown()
        throw error
    }
    await sandbox.tearDown()
}

/// The first frame `frames` yields within `timeout`, else nil.
private func firstFrame(
    of frames: any AsyncSequence<BusFrame, any Error> & Sendable, within timeout: Duration
) async throws -> BusFrame? {
    try await withThrowingTaskGroup(of: BusFrame?.self) { group in
        group.addTask {
            for try await frame in frames { return frame }
            return nil
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            return nil
        }
        let first = try await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// The real agent-deck and tmux, each test in a sandbox of its own. They
/// need both installed, so they run only with `BOSUN_INTEGRATION` set, as
/// `make integration` does; CI leaves them off.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["BOSUN_INTEGRATION"] != nil, "set BOSUN_INTEGRATION=1"))
struct AgentDeckIntegrationTests {
    @Test func theCLIRunsASessionOnThePrivateServerAndHearsItStop() async throws {
        try await withSandbox { sandbox in
            let cli = sandbox.cli
            #expect(try await cli.binary().version >= .minimumSupported)
            #expect(try await cli.list().isEmpty)
            #expect(try await cli.eventsStats().enabled)
            #expect(try await cli.statusEventsEnabled())

            let added = try await cli.addSession(sandbox.request)
            try await cli.startSession(id: added.id)
            let session = try #require(try await cli.list().first { $0.id == added.id })
            let tmuxSession = try #require(session.tmuxSession)
            #expect(session.status != .stopped)
            #expect(try await cli.listAllWindows().windows[tmuxSession]?.count == 1)

            // A view grouped with the session lists the same window under its own name.
            let view = ViewSession.name(paneID: UUID())
            try await cli.createView(view, grouping: tmuxSession, directory: sandbox.project)
            let listing = try await cli.listAllWindows()
            #expect(listing.windows[view] == listing.windows[tmuxSession])
            #expect(listing.currentWindows[view] == listing.windows[tmuxSession]?.first?.windowID)
            #expect(await cli.someoneElseOnWindow(ofView: view) == false)
            #expect(await cli.loneViews().isEmpty)
            await cli.killView(view)
            #expect(try await cli.listAllWindows().windows[view] == nil)

            // `session stop` publishes the one frame nothing else in the sandbox does.
            let frames = try await cli.follow(after: 0)
            try await cli.stopSession(id: added.id)
            let frame = try #require(try await firstFrame(of: frames, within: .seconds(10)))
            #expect(frame.kind == "session.status")
            #expect(frame.sessionID == added.id)
            #expect(frame.data?.to == .stopped)
            #expect(try await cli.list().first { $0.id == added.id }?.status == .stopped)

            try await cli.deleteSession(id: added.id)
            #expect(try await cli.list().isEmpty)
        }
    }

    @Test func theModelRunsASessionsLifeOnTheRealDeck() async throws {
        try await withSandbox { sandbox in
            let model = DeckModel(deck: sandbox.cli, gitHub: FakeGitHub(), defaults: MemoryDefaults())
            defer { model.stop() }
            await model.connect()
            #expect(model.hasLoadedSessions)
            #expect(model.sessions.isEmpty)
            #expect(await eventually(timeout: .seconds(10)) { model.connection == .live })
            // No TUI and no daemon run in the sandbox.
            #expect(model.statusFeedGap == .noPublisher)

            try await model.createSession(sandbox.request)
            let session = try #require(model.sessions.first)
            #expect(session.title == "probe")
            #expect(model.selection == .pane(PaneTarget(sessionID: session.id)))
            #expect(await eventually(timeout: .seconds(10)) { model.attachedPane != nil })
            let pane = try #require(model.attachedPane)
            let view = try #require(pane.view)
            #expect(try await sandbox.cli.listAllWindows().windows[view]?.count == 1)
            #expect(await eventually(timeout: .seconds(10)) { model.windowsBySession[session.id]?.count == 1 })

            model.stopSession(session)
            #expect(await eventually(timeout: .seconds(15)) { model.busySessions.isEmpty && model.sessions.first?.status == .stopped })
            #expect(await eventually(timeout: .seconds(10)) { model.attachedPane == nil })
            #expect(model.shownSessionID == session.id, "the pane offers Restart")
            #expect(try await sandbox.cli.listAllWindows().windows[view] == nil, "the stopped session's view went with its pane")

            model.restartSession(model.sessions[0])
            #expect(await eventually(timeout: .seconds(15)) { model.busySessions.isEmpty && model.sessions.first?.status != .stopped })
            #expect(model.lastError == nil)
            #expect(await eventually(timeout: .seconds(10)) { model.attachedPane != nil && model.attachedPane?.id != pane.id })

            model.deleteSession(model.sessions[0])
            #expect(await eventually(timeout: .seconds(15)) { model.busySessions.isEmpty && model.sessions.isEmpty })
            #expect(model.shownSessionID == nil)
            #expect(model.selection == nil)
            #expect(model.livePanes.isEmpty)
        }
    }

    /// Deleting a worktree session removes its directory and its entry in
    /// the repository; a worktree a second session still works in stays
    /// until that one goes too.
    @Test func deletingAWorktreeSessionRemovesItsDirectory() async throws {
        try await withSandbox { sandbox in
            let cli = sandbox.cli
            try await sandbox.makeRepository()
            var request = NewSessionRequest(title: "owner", directory: sandbox.project, command: "sleep 600", worktreeBranch: "probe", createBranch: true, runsWorktreeSetup: false)
            let owner = try await cli.addSession(request)
            let worktree = try #require(try await cli.list().first { $0.id == owner.id }?.worktreePath)
            #expect(FileManager.default.fileExists(atPath: worktree))
            // agent-deck prefixes a bare branch name with `feature/`.
            #expect(try await sandbox.git(["worktree", "list"]).contains("probe]"))
            try await cli.startSession(id: owner.id)

            // `-w` with the branch's existing worktree joins it.
            request.title = "sharer"
            request.createBranch = false
            let sharer = try await cli.addSession(request)
            #expect(try await cli.list().first { $0.id == sharer.id }?.worktreePath == worktree)

            try await cli.deleteSession(id: owner.id)
            #expect(FileManager.default.fileExists(atPath: worktree), "kept for the sharer")
            try await cli.deleteSession(id: sharer.id)
            #expect(!FileManager.default.fileExists(atPath: worktree))
            #expect(try await !sandbox.git(["worktree", "list"]).contains("probe]"))
            #expect(try await cli.list().isEmpty)
        }
    }

    /// A worktree agent-deck cannot remove, its repository gone, fails the
    /// delete with agent-deck's reason, though the session itself is gone:
    /// the directory is still there, for the user to know about.
    @Test func aWorktreeLeftBehindFailsTheDelete() async throws {
        try await withSandbox { sandbox in
            let cli = sandbox.cli
            try await sandbox.makeRepository()
            let request = NewSessionRequest(title: "orphan", directory: sandbox.project, command: "sleep 600", worktreeBranch: "probe", createBranch: true, runsWorktreeSetup: false)
            let orphan = try await cli.addSession(request)
            let worktree = try #require(try await cli.list().first { $0.id == orphan.id }?.worktreePath)
            try FileManager.default.removeItem(atPath: sandbox.project + "/.git")

            await #expect(throws: AgentDeckCLIError.reported("Worktree remove failed for \(orphan.id): not a git or jujutsu repository: \(worktree)")) {
                try await cli.deleteSession(id: orphan.id)
            }
            #expect(FileManager.default.fileExists(atPath: worktree))
            #expect(try await cli.list().isEmpty)
        }
    }
}
