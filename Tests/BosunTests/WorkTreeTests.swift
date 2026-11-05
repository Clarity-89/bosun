import Foundation
import Testing
@testable import Bosun

/// The toolbar's uncommitted count: Grafana's enterprise link in a go.mod
/// is never committed, so a go.mod with nothing else changed is no change.
@Suite struct WorkTreeChangesTests {
    /// `git diff -U0 --no-prefix HEAD` in a Grafana worktree with the link,
    /// a module that also has a real change, and a deleted module whose
    /// lines were all the link.
    static let diff = """
        diff --git apps/iam/go.mod apps/iam/go.mod
        index 93fb2faf18b..a33f97a2a80 100644
        --- apps/iam/go.mod
        +++ apps/iam/go.mod
        @@ -152,0 +153,2 @@ require (
        +
        +replace github.com/grafana/grafana-enterprise => ../../../grafana-enterprise
        diff --git apps/plugins/go.mod apps/plugins/go.mod
        index 1111111..2222222 100644
        --- apps/plugins/go.mod
        +++ apps/plugins/go.mod
        @@ -10 +10 @@ require (
        -	github.com/grafana/grafana-app-sdk v0.40.0
        +	github.com/grafana/grafana-app-sdk v0.41.0
        @@ -152,0 +153,2 @@ require (
        +
        +replace github.com/grafana/grafana-enterprise => ../../../grafana-enterprise
        diff --git apps/old/go.mod apps/old/go.mod
        deleted file mode 100644
        index 3333333..0000000
        --- apps/old/go.mod
        +++ /dev/null
        @@ -1 +0,0 @@
        -replace github.com/grafana/grafana-enterprise => ../../../grafana-enterprise
        diff --git go.mod go.mod
        index 7ea418478d5..e609bc92ee8 100644
        --- go.mod
        +++ go.mod
        @@ -476,0 +477 @@ require (
        +	github.com/grafana/grafana-enterprise v0.0.0
        @@ -732,0 +734,2 @@ exclude k8s.io/client-go v12.0.0+incompatible
        +
        +replace github.com/grafana/grafana-enterprise => ../grafana-enterprise
        """

    /// A real change counts, and so does a module gone.
    @Test func onlyModulesWithNothingButTheLinkAreLinked() {
        #expect(WorkTreeChanges.enterpriseLinkOnly(diff: Self.diff) == ["apps/iam/go.mod", "go.mod"])
    }

    /// Through git itself: outside a repository there is nothing; inside,
    /// the status lists the linked module, the scan drops it, and keeps a
    /// module with a real change and a new one.
    @Test func theScanDropsOnlyLinkedModules() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "bosun-gomod-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "apps/iam"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ arguments: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path, "-c", "user.name=t", "-c", "user.email=t@t"] + arguments
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, "git \(arguments)")
        }
        func write(_ path: String, _ text: String) throws {
            try text.write(to: root.appending(path: path), atomically: true, encoding: .utf8)
        }
        #expect(try await WorkTreeChanges.scan(root.path) == nil)
        let module = "module x\n\nrequire (\n\tgithub.com/a/b v1.0.0\n)\n"
        try git("init", "-q")
        try write("go.mod", module)
        try write("apps/iam/go.mod", module)
        try git("add", ".")
        try git("commit", "-q", "-m", "init")
        let link = "\nreplace github.com/grafana/grafana-enterprise => ../grafana-enterprise\n"
        try write("go.mod", module + link)
        try write("apps/iam/go.mod", module.replacingOccurrences(of: "v1.0.0", with: "v1.1.0") + link)
        try FileManager.default.createDirectory(at: root.appending(path: "apps/new"), withIntermediateDirectories: true)
        try write("apps/new/go.mod", link)
        #expect(try await WorkTreeChanges.scan(root.path) == [" M apps/iam/go.mod", "?? apps/new/"])
    }
}

/// One directory followed at a time, its scans landing one after another.
@MainActor
@Suite struct WorkTreeCenterTests {
    /// Scans that wait to be answered, oldest first, so a test can ask for
    /// more while one runs.
    @MainActor
    private final class Gate {
        private(set) var asked = 0
        private var waiting: [CheckedContinuation<[String]?, any Error>] = []

        func scan(_ path: String) async throws -> [String]? {
            asked += 1
            return try await withCheckedThrowingContinuation { waiting.append($0) }
        }

        func answer(_ changes: [String]?) {
            waiting.removeFirst().resume(returning: changes)
        }

        func fail() {
            waiting.removeFirst().resume(throwing: CancellationError())
        }
    }

    /// Git's nil is an answer: no repository, so no mark. No answer at all,
    /// as when git runs out of time, leaves the last one on show.
    @Test func noAnswerKeepsTheLastOne() async {
        let gate = Gate()
        let center = WorkTreeCenter { try await gate.scan($0) }
        center.follow("/a")
        #expect(await eventually { gate.asked == 1 })
        gate.answer([" M x"])
        #expect(await eventually { center["/a"] == [" M x"] })
        center.rescan()
        #expect(await eventually { gate.asked == 2 })
        gate.fail()
        await settled()
        #expect(center["/a"] == [" M x"])
        center.rescan()
        #expect(await eventually { gate.asked == 3 })
        gate.answer(nil)
        #expect(await eventually { center["/a"] == nil })
    }

    /// Rescans asked for during a scan run once after it, so a slow
    /// repository's scan is never cut short; a turn ending elsewhere asks
    /// for nothing; following another directory drops the scan in flight.
    @Test func rescansCoalesceBehindTheOneRunning() async {
        let gate = Gate()
        let center = WorkTreeCenter { try await gate.scan($0) }
        center.follow("/a")
        #expect(await eventually { gate.asked == 1 })
        center.rescan()
        center.rescan(ifFollowing: "/b")
        center.rescan(ifFollowing: "/a")
        await settled()
        #expect(gate.asked == 1)
        gate.answer([])
        #expect(await eventually { gate.asked == 2 })
        #expect(center["/a"] == [])
        gate.answer([" M y"])
        #expect(await eventually { center["/a"] == [" M y"] })
        await settled()
        #expect(gate.asked == 2)
        // A scan in flight as the pane moves on is dropped: its answer is
        // nobody's any more.
        center.rescan()
        #expect(await eventually { gate.asked == 3 })
        center.follow("/b")
        #expect(await eventually { gate.asked == 4 })
        gate.answer(["?? dropped"])
        gate.answer(["?? z"])
        #expect(await eventually { center["/b"] == ["?? z"] })
        #expect(center["/a"] == [" M y"])
    }
}
