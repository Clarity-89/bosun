import Foundation
import Testing
@testable import Bosun
@testable import BosunCore

/// The to-do file under its store: edits reach the disk a moment after the
/// last one, and what others write reaches the list.
@MainActor
@Suite struct TodoStoreTests {
    /// A directory of its own for each test's file, so none sees another's writes.
    private final class Sandbox {
        let url = FileManager.default.temporaryDirectory.appending(path: "bosun-todo-tests-\(UUID().uuidString)/todo.md")

        func write(_ text: String, atomically: Bool) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: atomically, encoding: .utf8)
        }

        var text: String? {
            try? String(contentsOf: url, encoding: .utf8)
        }

        deinit {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }

    /// An agent's edit tool writes in place; an editor's save renames a new
    /// file over the old one. Both show, and the file is followed through
    /// the rename to the inode now at its path.
    @Test func followsWritesInPlaceAndByRename() async throws {
        let sandbox = Sandbox()
        try sandbox.write("# A\n- [ ] one\n", atomically: true)
        let store = TodoStore(url: sandbox.url)
        store.start()
        defer { store.stop() }
        #expect(store.document.openCount == 1)
        try sandbox.write("# A\n- [ ] one\n- [ ] two\n", atomically: false)
        #expect(await eventually { store.document.openCount == 2 })
        try sandbox.write("# A\n", atomically: true)
        #expect(await eventually { store.document.openCount == 0 })
        try sandbox.write("- [ ] three\n", atomically: false)
        #expect(await eventually { store.document.lines.first == .item(done: false, text: "three", indent: 0) })
    }

    @Test func aMissingFileIsAnEmptyListUntilTheFirstEdit() async throws {
        let sandbox = Sandbox()
        let store = TodoStore(url: sandbox.url)
        store.start()
        defer { store.stop() }
        #expect(store.document.isEmpty)
        #expect(store.error == nil)
        #expect(sandbox.text == nil)
        store.edit("- [ ] first")
        #expect(store.document.openCount == 1)
        #expect(await eventually { sandbox.text == "- [ ] first" })
        await settled()
        #expect(store.document.text == "- [ ] first")
    }

    /// A tick is a click, written as it lands; keystrokes come in runs, and
    /// one write serves the run.
    @Test func aToggleWritesAtOnceAndKeystrokesWaitForTheLast() async throws {
        let sandbox = Sandbox()
        try sandbox.write("- [ ] a\n- [ ] b\n", atomically: true)
        let store = TodoStore(url: sandbox.url)
        store.start()
        defer { store.stop() }
        store.toggle(lineAt: 0)
        #expect(sandbox.text == "- [x] a\n- [ ] b\n")
        store.edit("- [x] a\n- [ ] b\n- [ ] c")
        store.edit("- [x] a\n- [ ] b\n- [ ] cd")
        #expect(sandbox.text == "- [x] a\n- [ ] b\n")
        #expect(await eventually { sandbox.text == "- [x] a\n- [ ] b\n- [ ] cd" })
    }

    /// Written to while a keystroke waits, the file's text takes the
    /// editor, and the keystroke is not written over it.
    @Test func theDiskWinsOverAnUnwrittenKeystroke() async throws {
        let sandbox = Sandbox()
        try sandbox.write("- [ ] a\n", atomically: true)
        let store = TodoStore(url: sandbox.url)
        store.start()
        defer { store.stop() }
        store.edit("- [ ] a\n- [ ] typing")
        try sandbox.write("- [ ] a\n- [ ] from the agent\n", atomically: false)
        #expect(await eventually { store.document.text == "- [ ] a\n- [ ] from the agent\n" })
        try await Task.sleep(for: .milliseconds(600))
        #expect(sandbox.text == "- [ ] a\n- [ ] from the agent\n")
    }

    @Test func stoppingWritesWhatWaits() async throws {
        let sandbox = Sandbox()
        let store = TodoStore(url: sandbox.url)
        store.start()
        store.edit("- [ ] last words")
        store.stop()
        #expect(sandbox.text == "- [ ] last words")
    }
}
