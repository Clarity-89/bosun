import BosunCore
import Foundation
import Observation
import os

/// The to-do list's file: read when the tab first shows and whenever
/// something else writes it, written as you edit it. The agents you ask
/// edit the same file, so their changes show as they land.
@MainActor
@Observable
final class TodoStore {
    /// A short path to tell an agent, outside every repository.
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/bosun/todo.md")

    let url: URL
    private(set) var document = TodoDocument(text: "")
    /// Why the file could not be read or written; nil once it could.
    private(set) var error: String?

    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// The text as last read from or written to the file, so a write of
    /// Bosun's own landing is told from someone else's.
    @ObservationIgnored private var diskText = ""

    init(url: URL = defaultURL) {
        self.url = url
    }

    /// The path as the To-dos tab shows it, with `~` for home.
    var displayPath: String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    /// Reads the file and follows it from here on. The directory is made
    /// now, so there is something to watch before the first write.
    func start() {
        guard watcher == nil else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        reload()
        watcher = FileWatcher(url: url) { [weak self] in self?.reload() }
    }

    /// Writes what a keystroke left unwritten; the app is quitting.
    func stop() {
        watcher?.stop()
        watcher = nil
        if saveTask != nil {
            saveTask?.cancel()
            saveTask = nil
            save()
        }
    }

    /// The editor's text: shown at once, written 400 ms after the last change.
    func edit(_ text: String) {
        guard text != document.text else { return }
        document = TodoDocument(text: text)
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            saveTask = nil
            save()
        }
    }

    /// Ticks or unticks the item on the line, written at once.
    func toggle(lineAt index: Int) {
        guard let text = document.toggling(lineAt: index) else { return }
        document = TodoDocument(text: text)
        saveTask?.cancel()
        saveTask = nil
        save()
    }

    /// An empty file where there is none, for an editor to open.
    func createIfMissing() {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        save()
    }

    /// What is on disk, when it is not what Bosun last read or wrote. It
    /// wins over a keystroke not yet written: an agent's whole edit against
    /// a moment of typing, which the editor shows go.
    private func reload() {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            text = ""
        } catch {
            self.error = "Could not read \(displayPath): \(error.localizedDescription)"
            return
        }
        error = nil
        guard text != diskText else { return }
        diskText = text
        if saveTask != nil {
            logger.info("\(self.displayPath, privacy: .public) changed on disk under an edit; the disk wins")
            saveTask?.cancel()
            saveTask = nil
        }
        if text != document.text {
            document = TodoDocument(text: text)
        }
    }

    private func save() {
        let text = document.text
        diskText = text
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            error = nil
        } catch {
            self.error = "Could not save \(displayPath): \(error.localizedDescription)"
            logger.error("saving \(self.displayPath, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Calls back when a file changes, is replaced or appears. A source on the
/// file sees a write in place; one on its directory sees the rename an
/// atomic write or a first write is, after which the file source is armed
/// again on the file now there.
@MainActor
private final class FileWatcher {
    private let url: URL
    private let onChange: @MainActor @Sendable () -> Void
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?

    init(url: URL, onChange: @escaping @MainActor @Sendable () -> Void) {
        self.url = url
        self.onChange = onChange
        directorySource = Self.source(path: url.deletingLastPathComponent().path, events: [.write, .rename, .delete]) { [weak self] in
            self?.changed()
        }
        armFile()
    }

    func stop() {
        directorySource?.cancel()
        directorySource = nil
        fileSource?.cancel()
        fileSource = nil
    }

    /// Every event re-arms the file source: cheap, and the only way to
    /// follow the file to the inode an atomic write left in its place.
    private func changed() {
        armFile()
        onChange()
    }

    private func armFile() {
        fileSource?.cancel()
        fileSource = Self.source(path: url.path, events: [.write, .extend, .attrib, .delete, .rename, .revoke]) { [weak self] in
            self?.changed()
        }
    }

    /// Nil while the path does not exist.
    private static func source(path: String, events: DispatchSource.FileSystemEvent, handler: @escaping @MainActor @Sendable () -> Void) -> DispatchSourceFileSystemObject? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: events, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated(handler)
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        return source
    }
}
