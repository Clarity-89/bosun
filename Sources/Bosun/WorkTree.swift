import BosunCore
import Foundation
import Observation
import SwiftUI

/// What counts as an uncommitted change in a session's directory: what
/// `git status` lists, less the noise a build leaves in tracked files.
/// `make` in a Grafana checkout writes a `replace` for grafana-enterprise
/// into every go.mod, and it is never committed; a go.mod with no other
/// change is no change.
enum WorkTreeChanges {
    static let enterpriseModule = "github.com/grafana/grafana-enterprise"

    /// Each change as `git status --porcelain` lists it; nil when `path` is
    /// not in a repository. Throws when git gave no answer.
    static func scan(_ path: String) async throws -> [String]? {
        guard let lines = try await GitRepo.status(path: path) else { return nil }
        let modules = lines.filter { !$0.hasPrefix("??") }.map { String($0.dropFirst(3)) }.filter { $0 == "go.mod" || $0.hasSuffix("/go.mod") }
        guard !modules.isEmpty, let diff = try await GitRepo.diff(path: path, files: modules) else { return lines }
        let linked = enterpriseLinkOnly(diff: diff)
        return lines.filter { !linked.contains(String($0.dropFirst(3))) }
    }

    /// The files in a `git diff --no-prefix` whose every changed line names
    /// grafana-enterprise; blank lines, which the link brings with it, do
    /// not count either way.
    static func enterpriseLinkOnly(diff: String) -> Set<String> {
        var linked: Set<String> = []
        var file: String?
        var onlyLink = false
        func close() {
            if let file, onlyLink { linked.insert(file) }
        }
        for line in diff.split(separator: "\n") {
            if line.hasPrefix("diff --git ") {
                close()
                file = nil
            } else if line.hasPrefix("+++ ") {
                // The new side names the file; a deleted file has none and
                // stays closed.
                let name = line.dropFirst("+++ ".count)
                file = name == "/dev/null" ? nil : String(name)
                onlyLink = false
            } else if line.hasPrefix("--- ") {
                continue
            } else if line.hasPrefix("+") || line.hasPrefix("-") {
                guard file != nil, !line.dropFirst().allSatisfy(\.isWhitespace) else { continue }
                guard line.contains(enterpriseModule) else {
                    file = nil
                    continue
                }
                onlyLink = true
            }
        }
        close()
        return linked
    }
}

/// The uncommitted changes of the directory on view, for the toolbar.
/// `git status` stats every tracked file, which `GitRepo.info` spares the
/// rows, so one directory is followed at a time: the shown one's, read as
/// the pane comes to it, as its agent's turn ends and with each list.
@MainActor
@Observable
final class WorkTreeCenter {
    /// Each directory's changes at its last scan; absent until a scan
    /// lands, and after one that found no repository.
    private(set) var changes: [String: [String]] = [:]
    @ObservationIgnored private let scan: @Sendable (String) async throws -> [String]?
    /// The directory on view, the one `rescan` reads.
    @ObservationIgnored private var followed: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// A rescan asked for while one ran: it runs once that lands, instead
    /// of cutting it short, so scans of a slow repository always land.
    @ObservationIgnored private var rescanWanted = false

    /// `scan` answers for a directory; a test answers from memory.
    init(scan: @escaping @Sendable (String) async throws -> [String]? = WorkTreeChanges.scan) {
        self.scan = scan
    }

    subscript(path: String) -> [String]? {
        changes[path]
    }

    /// The directory now on view, read at once; nil, or an empty path, as
    /// none is. A scan of the one before is dropped; the same directory,
    /// under another session, is read again.
    func follow(_ path: String?) {
        let path = path.flatMap { $0.isEmpty ? nil : $0 }
        guard path != followed else { return rescan() }
        followed = path
        task?.cancel()
        task = nil
        rescanWanted = false
        if let path { start(path) }
    }

    /// Reads the followed directory again: the list came round, and files
    /// change under your own hands with no turn to end.
    func rescan() {
        guard let followed else { return }
        if task != nil {
            rescanWanted = true
        } else {
            start(followed)
        }
    }

    /// `rescan()` when `path` is the followed directory: a turn ended there.
    func rescan(ifFollowing path: String) {
        if path == followed { rescan() }
    }

    func stop() {
        task?.cancel()
    }

    private func start(_ path: String) {
        task = Task { [scan, weak self] in
            let answer = await Result { try await scan(path) }
            guard !Task.isCancelled, let self else { return }
            task = nil
            // Git's nil is an answer, no repository; no answer at all keeps
            // the last one, so a slow repository's mark does not blink out
            // while git takes its time.
            if case .success(let found) = answer { changes[path] = found }
            if rescanWanted {
                rescanWanted = false
                start(path)
            }
        }
    }
}

/// The shown session's uncommitted changes, beside its GitHub links: how
/// many paths `git status` lists, each in the tooltip as git prints it.
/// Says, does nothing: the agent or a shell commits.
struct WorkTreeMark: View {
    let changes: [String]

    var body: some View {
        Label {
            Text(verbatim: "\(changes.count) changed").monospacedDigit()
        } icon: {
            Image(systemName: "pencil.line")
        }
        .labelStyle(.titleAndIcon)
        .foregroundStyle(.secondary)
        .help("Not committed in the session's directory:\n" + changes.joined(separator: "\n"))
        .accessibilityLabel("\(changes.count) uncommitted changes")
    }
}
