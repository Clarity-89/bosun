import BosunCore
import Foundation
import Observation

/// What the shown session's directory has that is not committed, for the
/// toolbar. `git status` stats every tracked file, which `GitRepo.info`
/// spares the rows, so one directory is read at a time: the shown one's,
/// as the pane comes to it, as its agent's turn ends and with each list.
@MainActor
@Observable
final class WorkTreeCenter {
    /// Each directory's changes at its last scan, as `git status
    /// --porcelain` lists them; absent until a scan lands, and after one
    /// that found no repository.
    private(set) var changes: [String: [String]] = [:]
    @ObservationIgnored private let scan: @Sendable (String) async -> [String]?
    @ObservationIgnored private var task: Task<Void, Never>?

    /// `scan` answers for a directory; a test answers from memory.
    init(scan: @escaping @Sendable (String) async -> [String]? = GitRepo.changes(path:)) {
        self.scan = scan
    }

    subscript(path: String) -> [String]? {
        changes[path]
    }

    /// Reads `path`, dropping a scan still running: a newer answer is wanted
    /// for the directory now shown.
    func rescan(_ path: String) {
        task?.cancel()
        task = Task { [scan, weak self] in
            let found = await scan(path)
            guard !Task.isCancelled, let self else { return }
            changes[path] = found
        }
    }

    func stop() {
        task?.cancel()
    }
}
