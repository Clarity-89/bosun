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
    /// The model setting's key: an omp model or role alias.
    static let modelKey = "todos.agentModel"

    /// The terminal omp runs in; nil before the first start and once it ended.
    private(set) var pane: TerminalPane?
    /// How the last omp ended; nil before the first start and while one runs.
    private(set) var exit: ProcessExit?
    /// The command line of the last launch, for its tooltip and for running
    /// it by hand once it ended.
    private(set) var command: String?
    let todos: TodoStore

    @ObservationIgnored private let defaults: any Defaults
    /// Set while asked for the keyboard before there was a terminal to take it.
    @ObservationIgnored private var focusOnLaunch = false

    init(todos: TodoStore, defaults: any Defaults) {
        self.todos = todos
        self.defaults = defaults
    }

    /// The first time the list shows. One that ended waits for Restart, so
    /// a crash never loops.
    func start() {
        guard pane == nil, exit == nil else { return }
        launch()
    }

    /// A new process, which picks up the last conversation; a running one
    /// goes first.
    func restart() {
        let running = pane
        pane = nil
        running?.teardown()
        launch()
    }

    /// The keyboard into the agent, now or once it has a terminal.
    func focus() {
        if let pane {
            pane.focusTerminal()
        } else {
            focusOnLaunch = true
        }
    }

    private func launch() {
        let model = defaults.string(forKey: Self.modelKey) ?? TodoAgentLaunch.defaultModel
        let launch = TodoAgentLaunch(list: todos.url, model: model)
        writeInstructionsIfMissing(launch)
        command = launch.command
        exit = nil
        let pane = TerminalPane.owned(command: launch.command, directory: launch.directory) { [weak self] pane, exit in
            guard let self, self.pane === pane else { return }
            self.pane = nil
            self.exit = exit
        }
        self.pane = pane
        if focusOnLaunch {
            focusOnLaunch = false
            pane.focusTerminal()
        }
    }

    /// The prompt file omp is pointed at, yours to change once written. The
    /// list's directory is there: the store made it as it started.
    private func writeInstructionsIfMissing(_ launch: TodoAgentLaunch) {
        guard !FileManager.default.fileExists(atPath: launch.instructionsFile.path) else { return }
        do {
            try Data(launch.instructions.utf8).write(to: launch.instructionsFile, options: .atomic)
        } catch {
            logger.error("writing \(launch.instructionsFile.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
