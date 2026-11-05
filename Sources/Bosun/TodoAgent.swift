import BosunCore
import BosunTerminal
import Foundation
import Observation

/// omp beside the to-do list, in its directory, as a terminal Bosun runs
/// itself: no agent-deck session, no notifications, and it ends with Bosun.
/// The list never depends on it; the file is all the two share, so an agent
/// that ends or errs leaves the list as it was.
@MainActor
@Observable
final class TodoAgent {
    enum State {
        /// Not started since Bosun launched.
        case idle
        /// Finding omp and the login shell's PATH.
        case launching
        case running(TerminalPane)
        case ended(ProcessExit)
        case notInstalled
    }

    /// The model setting's key: an omp model or role alias.
    static let modelKey = "todos.agentModel"

    private(set) var state = State.idle
    /// The command line of the last launch, for its tooltip and for running
    /// it by hand once it ended.
    private(set) var command: String?
    let directory: URL

    @ObservationIgnored private let defaults: any Defaults
    /// Set while asked for the keyboard before there was a terminal to take it.
    @ObservationIgnored private var focusOnLaunch = false

    init(directory: URL, defaults: any Defaults) {
        self.directory = directory
        self.defaults = defaults
    }

    /// The first time the list shows. One that ended waits for Restart, so
    /// a crash never loops.
    func start() {
        guard case .idle = state else { return }
        launch()
    }

    /// A new process, which picks up the last conversation; a running one
    /// goes first. One being found already is the new one.
    func restart() {
        switch state {
        case .launching:
            return
        case .running(let pane):
            state = .idle
            pane.teardown()
        case .idle, .ended, .notInstalled:
            break
        }
        launch()
    }

    /// The keyboard into the agent, now or once it has a terminal.
    func focus() {
        if case .running(let pane) = state {
            pane.focusTerminal()
        } else {
            focusOnLaunch = true
        }
    }

    private func launch() {
        state = .launching
        let model = defaults.string(forKey: Self.modelKey) ?? TodoAgentLaunch.defaultModel
        writeInstructionsIfMissing()
        Task {
            guard let launch = await TodoAgentLaunch.resolve(model: model, directory: directory.path) else {
                state = .notInstalled
                return
            }
            guard case .launching = state else { return }
            command = launch.command
            // Smaller than the session's terminal, as the side shells are: it shares a narrow column.
            let pane = TerminalPane(command: launch.command, environment: launch.environment, workingDirectory: directory.path, fontSizeOffset: -2)
            pane.yieldsKeyEquivalent = { Shortcut.menuAction(for: $0) != nil }
            pane.onProcessExit = { [weak self, weak pane] exit in
                guard let self, let pane, case .running(let current) = state, current === pane else { return }
                state = .ended(exit)
                // The engine reports the end from inside its own callback, which
                // has to return before the surface goes; so it goes after.
                Task { pane.teardown() }
            }
            state = .running(pane)
            if focusOnLaunch {
                focusOnLaunch = false
                pane.focusTerminal()
            }
        }
    }

    /// The prompt file omp is pointed at, yours to change once written.
    private func writeInstructionsIfMissing() {
        let file = directory.appending(path: TodoAgentLaunch.instructionsFile)
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(TodoAgentLaunch.instructions.utf8).write(to: file, options: .atomic)
        } catch {
            logger.error("writing \(file.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
