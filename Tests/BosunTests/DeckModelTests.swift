import Foundation
import Testing
@testable import Bosun
@testable import BosunCore
import BosunTerminal

/// Startup and the list: what `connect()` asks agent-deck, in what order,
/// and what the sidebar shows while it cannot.
@MainActor
@Suite struct DeckModelConnectTests {
    @Test func listsInDeckOrderAndFollowsFromTheCursorTakenBeforeTheList() async {
        let fixture = DeckFixture(
            sessions: [deckSession("b1", group: "b"), deckSession("a1", group: "a"), deckSession("b2", group: "b")],
            groups: ["a", "b"]
        )
        fixture.deck.stats = EventsStats(enabled: true, cursor: 7, statusOwner: .tui)
        // Published between the cursor and the list, as a change can be
        // while Bosun starts.
        fixture.deck.publish(.waiting, for: "a1", cursor: 8)
        await fixture.model.connect()
        #expect(fixture.sessions.map(\.id) == ["a1", "b1", "b2"])
        #expect(fixture.model.groups.map(\.name) == ["a", "b"])
        #expect(fixture.model.hasLoadedSessions)
        #expect(await eventually { fixture.model.connection == .live })
        #expect(fixture.model.statusFeedGap == nil)
        #expect(fixture.model.connectionLabel == "Live")
        // The follower starts at the cursor taken before the list, so the
        // frame replays onto it; one read the other way round would be lost.
        #expect(fixture.deck.followedAfter == [7])
        #expect(await eventually { fixture.session("a1").status == .waiting })
        let commands = fixture.deck.commands
        #expect(commands.firstIndex(of: "events stats")! < commands.firstIndex(of: "list")!)
    }

    @Test func archivedSessionsAreHiddenButGoWithTheirGroup() async {
        let fixture = DeckFixture(sessions: [deckSession("a"), deckSession("c", archived: true)])
        await fixture.model.connect()
        #expect(fixture.sessions.map(\.id) == ["a"])
        #expect(fixture.model.sessions(inGroupTree: "g").map(\.id) == ["a", "c"])
    }

    /// Without the group order, each group's rows still stay together.
    @Test func aFailedGroupListStillListsTheSessions() async {
        let fixture = DeckFixture(sessions: [deckSession("b1", group: "b"), deckSession("a1", group: "a")], groups: ["b", "a"])
        fixture.deck.failures["group list"] = AgentDeckCLIError.reported("no groups")
        await fixture.model.connect()
        #expect(fixture.sessions.map(\.id) == ["a1", "b1"])
        #expect(fixture.model.deckGroups.isEmpty)
        #expect(fixture.model.lastError == nil)
    }

    @Test func oneListRunsAtATime() async {
        let fixture = DeckFixture(sessions: [deckSession("a")])
        await fixture.model.connect()
        let listed = fixture.deck.calls("list").count
        fixture.deck.holdsList = true
        async let first: Void = fixture.model.refresh()
        async let second: Void = fixture.model.refresh()
        #expect(await eventually { fixture.deck.calls("list").count == listed + 1 })
        await settled()
        #expect(fixture.deck.calls("list").count == listed + 1)
        #expect(fixture.model.isRefreshing)
        fixture.deck.releaseList()
        await first
        await second
        #expect(!fixture.model.isRefreshing)
    }

    /// The list's own failure goes with the next list that works.
    @Test func aFailedListKeepsTheRowsAndSaysWhyUntilOneWorks() async {
        let fixture = DeckFixture(sessions: [deckSession("a")])
        await fixture.model.connect()
        fixture.deck.failures["list"] = AgentDeckCLIError.reported("state.db is locked")
        await fixture.model.refresh()
        #expect(fixture.model.lastError == "state.db is locked")
        #expect(fixture.sessions.map(\.id) == ["a"])
        #expect(fixture.model.hasLoadedSessions)
        fixture.deck.failures["list"] = nil
        await fixture.model.refresh()
        #expect(fixture.model.lastError == nil)
    }

    @Test func noAgentDeckIsUnavailableWithAnEmptyList() async {
        let fixture = DeckFixture(sessions: [deckSession("a")])
        fixture.deck.failures["binary"] = AgentDeckCLIError.notFound(rejected: [])
        await fixture.model.connect()
        #expect(fixture.model.connection == .unavailable)
        #expect(fixture.model.hasLoadedSessions)
        #expect(fixture.sessions.isEmpty)
        #expect(fixture.model.lastError == "agent-deck was not found")
        #expect(fixture.deck.calls("list").isEmpty)
    }

    @Test func aDisabledBusListsButNeverFollows() async {
        let fixture = DeckFixture(sessions: [deckSession("a")])
        fixture.deck.stats = EventsStats(enabled: false, cursor: 0, statusOwner: nil)
        await fixture.model.connect()
        #expect(fixture.sessions.map(\.id) == ["a"])
        #expect(fixture.model.connection == .unavailable)
        #expect(fixture.model.lastError == "The event bus is disabled; statuses refresh every 60 s")
        #expect(fixture.deck.followedAfter.isEmpty)
    }

    @Test func liveWithNoPublisherIsSaidToUpdateEveryMinute() async {
        let fixture = DeckFixture(sessions: [deckSession("a")])
        fixture.deck.stats = EventsStats(enabled: true, cursor: 0, statusOwner: .nobody)
        await fixture.model.connect()
        #expect(await eventually { fixture.model.connection == .live })
        #expect(fixture.model.statusFeedGap == .noPublisher)
        #expect(fixture.model.connectionLabel == "Updates every 60 s")
    }

    @Test func statusEventsOffIsAGapOfItsOwn() async {
        let fixture = DeckFixture(sessions: [deckSession("a")])
        fixture.deck.statusEvents = false
        await fixture.model.connect()
        #expect(fixture.model.statusFeedGap == .eventsOff)
    }

    /// The daemon's first pass, a moment after launchd starts it, is what
    /// makes it the owner; the offer stays up until then.
    @Test func installingTheNotifyDaemonWaitsForItToPublish() async {
        let fixture = DeckFixture(sessions: [deckSession("a")])
        fixture.deck.stats = EventsStats(enabled: true, cursor: 0, statusOwner: .nobody)
        await fixture.model.connect()
        fixture.model.installNotifyDaemon()
        #expect(fixture.model.isInstallingNotifyDaemon)
        #expect(await eventually { fixture.deck.calls("notify-daemon install").count == 1 })
        fixture.deck.stats = EventsStats(enabled: true, cursor: 0, statusOwner: .notifyDaemon)
        #expect(await eventually { !fixture.model.isInstallingNotifyDaemon })
        #expect(fixture.model.statusFeedGap == nil)
        #expect(fixture.model.lastError == nil)
    }
}

/// `session.status` frames from the bus, and the follower that reads them.
@MainActor
@Suite struct DeckModelStatusTests {
    @Test func aFrameMovesTheRowAndCountsTheTurnEnd() async {
        let fixture = DeckFixture(sessions: [deckSession("a", substate: "tool-call"), deckSession("b")])
        await fixture.model.connect()
        #expect(await eventually { fixture.model.connection == .live })
        fixture.deck.publish(.waiting, for: "a", cursor: 1)
        #expect(await eventually { fixture.session("a").status == .waiting })
        // The bus carries no substate; the old one described the previous status.
        #expect(fixture.session("a").substate == nil)
        #expect(fixture.model.attention.count == 1)
        // The same status again is not another turn.
        fixture.deck.publish(.waiting, for: "a", cursor: 2)
        fixture.deck.publish(.waiting, for: "b", cursor: 3)
        #expect(await eventually { fixture.session("b").status == .waiting })
        #expect(fixture.model.attention.count == 2)
        #expect(fixture.session("a").status == .waiting)
    }

    @Test func aFrameToStoppedDropsThePaneAndOffersRestart() async throws {
        let fixture = DeckFixture(sessions: [deckSession("a")])
        await fixture.model.connect()
        let pane = try await fixture.selectAndAttach("a")
        fixture.deck.publish(.stopped, for: "a", cursor: 1)
        #expect(await eventually { fixture.model.attachedPane == nil })
        #expect(fixture.model.shownSessionID == "a")
        #expect(fixture.model.paneSession?.status == .stopped)
        #expect(fixture.model.livePanes.isEmpty)
        #expect(await eventually { fixture.deck.calls("kill-session") == ["kill-session \(pane.view!)"] })
    }

    /// `events follow` refuses a cursor older than the retained log; the
    /// follower takes a fresh one and lists, so no change is missed.
    @Test func aCursorTooOldResyncsWithoutAnError() async {
        let fixture = DeckFixture(sessions: [deckSession("a")])
        fixture.deck.stats = EventsStats(enabled: true, cursor: 42, statusOwner: .tui)
        fixture.deck.followErrors = [
            SubprocessError.exited(command: "agent-deck events follow", status: 1, stderr: "events: cursor older than the retained log"),
        ]
        await fixture.model.connect()
        #expect(await eventually(timeout: .seconds(5)) { fixture.model.connection == .live })
        #expect(fixture.deck.followedAfter == [42, 42])
        #expect(fixture.deck.calls("events stats").count == 2)
        #expect(fixture.deck.calls("list").count == 2)
        #expect(fixture.model.lastError == nil)
    }

    /// The failure is the follower's to take back: a reconnect clears it,
    /// and no list in between does.
    @Test func aFollowerFailureIsReportedUntilItReconnects() async {
        let fixture = DeckFixture(sessions: [deckSession("a")])
        fixture.deck.followErrors = [
            SubprocessError.exited(command: "agent-deck events follow", status: 1, stderr: "bus: permission denied"),
        ]
        await fixture.model.connect()
        #expect(await eventually { fixture.model.lastError == "bus: permission denied" })
        #expect(fixture.model.connection == .reconnecting)
        await fixture.model.refresh()
        #expect(fixture.model.lastError == "bus: permission denied")
        #expect(await eventually(timeout: .seconds(5)) { fixture.model.connection == .live })
        #expect(fixture.model.lastError == nil)
        #expect(fixture.deck.followedAfter.count == 2)
    }
}

/// What the pane shows for a selection, and what happens to its terminal.
@MainActor
@Suite struct DeckModelSelectionTests {
    let windows = ["agentdeck_a": [window("@1", index: 0, name: "codex"), window("@2", index: 1)]]

    @Test func selectingASessionShowsItAndAttachesAView() async {
        let fixture = DeckFixture(sessions: [deckSession("a"), deckSession("b")], windows: windows)
        await fixture.model.connect()
        fixture.select("a")
        #expect(fixture.model.shownSessionID == "a")
        #expect(fixture.model.selectedSession?.id == "a")
        #expect(fixture.model.isAttaching)
        #expect(fixture.model.attachedPane == nil)
        #expect(await eventually { fixture.model.attachedPane != nil })
        let pane = fixture.model.attachedPane!
        #expect(pane.view?.hasPrefix("bosun-view-") == true)
        #expect(fixture.deck.calls("new-session") == ["new-session agentdeck_a \(pane.view!)"])
        #expect(!pane.yieldsSize, "nobody else is on the window, so the pane sizes it")
        #expect(pane.restartsIfDead, "a session you switch to should run")
        #expect(!fixture.model.isAttaching)
        #expect(fixture.model.livePanes.count == 1)
    }

    @Test func aStoppedSessionGetsRestartNotAnAttach() async {
        let fixture = DeckFixture(sessions: [deckSession("a", status: .stopped)])
        await fixture.model.connect()
        fixture.select("a")
        #expect(fixture.model.shownSessionID == "a")
        #expect(!fixture.model.isAttaching)
        await settled()
        #expect(fixture.model.attachedPane == nil)
        #expect(fixture.deck.calls("new-session").isEmpty)
    }

    /// A view tmux will not group (a session on its default server, a tmux
    /// older than 3.2) is let go, and the pane attaches through agent-deck,
    /// which knows the session's socket.
    @Test func withoutAViewThePaneAttachesThroughAgentDeck() async throws {
        let fixture = DeckFixture(sessions: [deckSession("a")])
        await fixture.model.connect()
        fixture.deck.failures["new-session"] = SubprocessError.exited(command: "tmux new-session", status: 1, stderr: "sessions should be nested with care")
        let pane = try await fixture.selectAndAttach("a")
        #expect(pane.view == nil)
        #expect(pane.launch.command == "/fake/bin/agent-deck session attach a")
        #expect(!pane.yieldsSize)
        #expect(fixture.model.livePanes.count == 1)
        #expect(await eventually { fixture.deck.calls("kill-session").count == 1 }, "the view that failed is not left behind")
    }

    @Test func switchingBackShowsTheKeptTerminalAtOnce() async throws {
        let fixture = DeckFixture(sessions: [deckSession("a"), deckSession("b")])
        await fixture.model.connect()
        let paneA = try await fixture.selectAndAttach("a")
        let paneB = try await fixture.selectAndAttach("b")
        // The hidden terminal leaves its window's size to the others.
        #expect(await eventually { fixture.deck.calls("refresh-client").contains("refresh-client \(paneA.view!) ignore-size") })
        fixture.select("a")
        #expect(fixture.model.attachedPane?.id == paneA.id)
        #expect(!fixture.model.isAttaching)
        #expect(fixture.model.livePanes.map(\.id) == [paneB.id, paneA.id])
        #expect(fixture.deck.calls("new-session").count == 2)
    }

    @Test func fiveTerminalsStayAttached() async throws {
        let ids = (1...6).map { "s\($0)" }
        let fixture = DeckFixture(sessions: ids.map { deckSession($0) })
        await fixture.model.connect()
        var panes: [AttachedPane] = []
        for id in ids {
            panes.append(try await fixture.selectAndAttach(id))
        }
        #expect(fixture.model.livePanes.map(\.sessionID) == Array(ids.dropFirst()))
        #expect(await eventually { fixture.deck.calls("kill-session") == ["kill-session \(panes[0].view!)"] })
    }

    @Test func aWindowRowShowsThatWindowInTheView() async throws {
        let fixture = DeckFixture(sessions: [deckSession("a")], windows: windows)
        await fixture.model.connect()
        #expect(fixture.model.extraWindows(for: "a").map(\.windowID) == ["@2"])
        let pane = try await fixture.selectAndAttach("a")
        fixture.select("a", window: "@2")
        #expect(fixture.model.selectedWindow?.windowID == "@2")
        #expect(fixture.model.shownSessionID == "a")
        #expect(fixture.model.attachedPane?.id == pane.id)
        #expect(await eventually { fixture.deck.calls("select-window").contains("select-window =\(pane.view!):@2") })
    }

    /// tmux's own keys move the view's window behind Bosun's back; the
    /// 2 s poll brings the selection along.
    @Test func theSelectionFollowsTheWindowTmuxMovesTheViewTo() async throws {
        let fixture = DeckFixture(sessions: [deckSession("a")], windows: windows)
        await fixture.model.connect()
        let pane = try await fixture.selectAndAttach("a")
        let polled = fixture.deck.calls("list-windows").count
        #expect(await eventually(timeout: .seconds(4)) { fixture.deck.calls("list-windows").count > polled })
        fixture.deck.windows.currentWindows[pane.view!] = "@2"
        #expect(await eventually(timeout: .seconds(4)) { fixture.model.selection == .pane(PaneTarget(sessionID: "a", windowID: "@2")) })
        #expect(fixture.model.selectedWindow?.windowID == "@2")
        #expect(fixture.model.attachedPane?.id == pane.id)
    }

    @Test func aGroupRowLeavesThePaneAsItIs() async throws {
        let fixture = DeckFixture(sessions: [deckSession("a")])
        await fixture.model.connect()
        let pane = try await fixture.selectAndAttach("a")
        fixture.model.select(.group("g"))
        #expect(fixture.model.selection == .group("g"))
        #expect(fixture.model.selectedSession == nil)
        #expect(fixture.model.shownSessionID == "a")
        #expect(fixture.model.attachedPane?.id == pane.id)
    }

    @Test func deselectingHidesThePaneButKeepsItsTerminal() async throws {
        let fixture = DeckFixture(sessions: [deckSession("a")])
        await fixture.model.connect()
        let pane = try await fixture.selectAndAttach("a")
        fixture.model.select(nil)
        #expect(fixture.model.shownSessionID == nil)
        #expect(fixture.model.attachedPane == nil)
        #expect(fixture.model.livePanes.map(\.id) == [pane.id])
    }

    @Test func aPaneEndingByItselfClosesAndEndsItsView() async throws {
        let fixture = DeckFixture(sessions: [deckSession("a")])
        await fixture.model.connect()
        let pane = try await fixture.selectAndAttach("a")
        fixture.model.paneExited(paneID: pane.id, exit: .normal)
        #expect(fixture.model.shownSessionID == nil)
        #expect(fixture.model.selection == nil)
        #expect(fixture.model.livePanes.isEmpty)
        #expect(await eventually { fixture.deck.calls("kill-session") == ["kill-session \(pane.view!)"] })
    }

    /// An attach that ends at once found no tmux session, whatever the row
    /// said; the session you switched to restarts and attaches again.
    @Test func anAttachEndingAtOnceRestartsTheSessionYouSwitchedTo() async throws {
        let fixture = DeckFixture(sessions: [deckSession("a")])
        await fixture.model.connect()
        let pane = try await fixture.selectAndAttach("a")
        fixture.model.paneExited(paneID: pane.id, exit: .abnormal)
        #expect(fixture.model.busySessions["a"] == .restart)
        #expect(await eventually { fixture.deck.calls("session restart") == ["session restart a"] })
        #expect(await eventually { fixture.model.busySessions.isEmpty })
        #expect(await eventually { fixture.model.attachedPane != nil && fixture.model.attachedPane?.id != pane.id })
        #expect(fixture.deck.calls("new-session").last == "new-session agentdeck_a_restarted \(fixture.model.attachedPane!.view!)")
    }

    @Test func aSessionGoneFromTheListTakesItsPaneAndSelection() async throws {
        let fixture = DeckFixture(sessions: [deckSession("a"), deckSession("b")])
        await fixture.model.connect()
        let pane = try await fixture.selectAndAttach("a")
        fixture.deck.sessions.removeAll { $0.id == "a" }
        await fixture.model.refresh()
        #expect(fixture.model.shownSessionID == nil)
        #expect(fixture.model.selection == nil)
        #expect(fixture.model.livePanes.isEmpty)
        #expect(await eventually { fixture.deck.calls("kill-session") == ["kill-session \(pane.view!)"] })
    }

    /// A notification's click that launched Bosun arrives before the
    /// first list; the keyboard goes into the terminal once it is there.
    @Test func aRevealBeforeTheFirstListWaitsForIt() async {
        let fixture = DeckFixture(sessions: [deckSession("a")])
        fixture.model.reveal(sessionID: "a", windowID: nil)
        #expect(fixture.model.selection == nil)
        await fixture.model.connect()
        #expect(fixture.model.selection == .pane(PaneTarget(sessionID: "a")))
        #expect(fixture.model.shownSessionID == "a")
        #expect(await eventually { fixture.model.revealRequests == 1 })
    }

    @Test func aRevealUncoversTheSessionAndSwitchesToTheList() async {
        let fixture = DeckFixture(sessions: [deckSession("a")], windows: windows)
        await fixture.model.connect()
        fixture.model.sessionList.foldGroup("g")
        fixture.model.sessionList.filter.query = "nothing like it"
        fixture.model.tab = .inbox
        fixture.model.reveal(sessionID: "a", windowID: "@2")
        #expect(fixture.model.tab == .sessions)
        #expect(!fixture.model.sessionList.collapsedGroups.contains("g"))
        #expect(fixture.model.sessionList.filter.query == "")
        #expect(fixture.model.selection == .pane(PaneTarget(sessionID: "a", windowID: "@2")))
        #expect(fixture.defaults.string(forKey: "sidebarTab") == "sessions")
    }
}

/// Actions on sessions: how the rows read meanwhile, and what the list
/// after them settles.
@MainActor
@Suite struct DeckModelLifecycleTests {
    @Test func stopKeepsTheRowBusyUntilTheListAfterIt() async {
        let fixture = DeckFixture(sessions: [deckSession("a")])
        await fixture.model.connect()
        fixture.deck.holdsList = true
        fixture.model.stopSession(fixture.session("a"))
        #expect(fixture.model.busySessions["a"] == .stop)
        #expect(await eventually { fixture.deck.calls("session stop") == ["session stop a"] })
        #expect(await eventually { fixture.deck.calls("list").count == 2 })
        #expect(fixture.model.busySessions["a"] == .stop)
        #expect(fixture.session("a").status == .running, "the row changes with the list, not before")
        fixture.deck.releaseList()
        #expect(await eventually { fixture.model.busySessions.isEmpty })
        #expect(fixture.session("a").status == .stopped)
    }

    @Test func aRefusalStaysInTheFooterPastTheReload() async {
        let fixture = DeckFixture(sessions: [deckSession("a")])
        await fixture.model.connect()
        fixture.deck.failures["session restart"] = AgentDeckCLIError.reported("Restart skipped: started 10s ago")
        fixture.model.restartSession(fixture.session("a"))
        #expect(await eventually { fixture.model.busySessions.isEmpty })
        #expect(fixture.deck.calls("list").count == 2)
        #expect(fixture.model.lastError == "Restart skipped: started 10s ago")
        #expect(fixture.session("a").status == .running)
    }

    @Test func aBusySessionTakesNoSecondAction() async {
        let fixture = DeckFixture(sessions: [deckSession("a")])
        await fixture.model.connect()
        fixture.deck.holdsList = true
        fixture.model.stopSession(fixture.session("a"))
        fixture.model.renameSession(fixture.session("a"), to: "other")
        fixture.model.stopSession(fixture.session("a"))
        #expect(await eventually { fixture.deck.calls("session stop").count == 1 })
        await settled()
        #expect(fixture.deck.calls("rename").isEmpty)
        #expect(fixture.deck.calls("session stop").count == 1)
        fixture.deck.releaseList()
        #expect(await eventually { fixture.model.busySessions.isEmpty })
    }

    @Test func deletingAGroupDeletesItsSessionsArchivedAndNestedFirst() async throws {
        let fixture = DeckFixture(
            sessions: [deckSession("a"), deckSession("c", archived: true), deckSession("b", group: "g/sub"), deckSession("x", group: "other")],
            groups: ["g", "g/sub", "other"]
        )
        await fixture.model.connect()
        let group = try #require(fixture.model.groups.first { $0.name == "g" })
        fixture.model.sessionList.foldGroup("g")
        #expect(fixture.model.canDeleteGroup(group))
        fixture.model.deleteGroup(group)
        #expect(fixture.model.busySessions.keys.sorted() == ["a", "b", "c"])
        #expect(!fixture.model.canDeleteGroup(group))
        #expect(await eventually { fixture.model.busySessions.isEmpty })
        let commands = fixture.deck.commands
        let groupDelete = try #require(commands.firstIndex(of: "group delete g"))
        #expect(Set(fixture.deck.calls("session remove")) == ["session remove a", "session remove b", "session remove c"])
        #expect(fixture.deck.calls("session remove").allSatisfy { commands.firstIndex(of: $0)! < groupDelete })
        #expect(fixture.sessions.map(\.id) == ["x"])
        #expect(!fixture.model.sessionList.collapsedGroups.contains("g"))
    }

    @Test func creatingASessionStartsSelectsAndAttachesIt() async throws {
        let fixture = DeckFixture(sessions: [deckSession("a")])
        await fixture.model.connect()
        try await fixture.model.createSession(NewSessionRequest(title: "fresh", directory: "/p/fresh", groupPath: "g", command: "omp "))
        #expect(fixture.deck.calls("add") == ["add fresh /p/fresh"])
        #expect(fixture.deck.calls("session start") == ["session start new-1"])
        #expect(fixture.sessions.map(\.id) == ["a", "new-1"])
        #expect(fixture.model.selection == .pane(PaneTarget(sessionID: "new-1")))
        #expect(fixture.model.shownSessionID == "new-1")
        #expect(await eventually { fixture.model.attachedPane?.sessionID == "new-1" })
        #expect(fixture.model.lastError == nil)
        #expect(fixture.defaults.string(forKey: "newSessionCommand") == "omp")
    }

    @Test func aRefusedStartOffersRestartAndSaysWhy() async throws {
        let fixture = DeckFixture(sessions: [deckSession("a")])
        await fixture.model.connect()
        fixture.deck.failures["session start"] = AgentDeckCLIError.reported("tmux: server not running")
        try await fixture.model.createSession(NewSessionRequest(title: "fresh", directory: "/p/fresh", command: "omp"))
        #expect(fixture.model.shownSessionID == "new-1")
        #expect(fixture.model.lastError == "tmux: server not running")
        #expect(!fixture.model.isAttaching)
        #expect(fixture.model.attachedPane == nil)
    }

    @Test func aRefusedAddThrowsAndAddsNothing() async {
        let fixture = DeckFixture(sessions: [deckSession("a")])
        await fixture.model.connect()
        fixture.deck.failures["add"] = AgentDeckCLIError.reported("path does not exist: /p/gone")
        await #expect(throws: AgentDeckCLIError.reported("path does not exist: /p/gone")) {
            try await fixture.model.createSession(NewSessionRequest(title: "gone", directory: "/p/gone", command: "omp"))
        }
        #expect(fixture.sessions.map(\.id) == ["a"])
        #expect(fixture.deck.calls("session start").isEmpty)
    }

    @Test func aMoveShowsAtOnceAndTheListConfirmsIt() async {
        let fixture = DeckFixture(sessions: [deckSession("a"), deckSession("b")])
        await fixture.model.connect()
        fixture.model.move(.session(SessionMove(sessionID: "b", placement: .before("a"), order: ["b", "a"])))
        #expect(fixture.sessions.map(\.id) == ["b", "a"])
        #expect(await eventually { fixture.deck.calls("list").count == 2 })
        #expect(fixture.sessions.map(\.id) == ["b", "a"])
        #expect(fixture.deck.calls("session set") == ["session set b order"])
    }

    @Test func aRefusedMoveGoesBackAndSaysWhy() async {
        let fixture = DeckFixture(sessions: [deckSession("a"), deckSession("b")])
        await fixture.model.connect()
        fixture.deck.failures["session set"] = AgentDeckCLIError.reported("order out of range")
        fixture.model.move(.session(SessionMove(sessionID: "b", placement: .before("a"), order: ["b", "a"])))
        #expect(fixture.sessions.map(\.id) == ["b", "a"])
        #expect(await eventually { fixture.sessions.map(\.id) == ["a", "b"] })
        #expect(await eventually { fixture.model.lastError == "order out of range" })
    }

    @Test func askingTypesTheCommandIntoTheAgent() async {
        let fixture = DeckFixture(sessions: [deckSession("a"), deckSession("n", hasTmux: false)])
        await fixture.model.connect()
        fixture.model.ask(.mergeMain, of: fixture.session("a"))
        #expect(await eventually { fixture.deck.calls("send-keys") == ["send-keys agentdeck_a /merge-main"] })
        fixture.model.ask(.submitPullRequest, of: fixture.session("n"))
        #expect(await eventually { fixture.model.lastError == "“n” has no agent to ask" })
        #expect(fixture.deck.calls("send-keys").count == 1)
    }

    /// A new window opens in Bosun's view once the session has one, so it
    /// shows here while other clients stay on their window.
    @Test func openShellHereGoesThroughTheViewOnceThereIsOne() async throws {
        let fixture = DeckFixture(sessions: [deckSession("a")])
        await fixture.model.connect()
        fixture.model.newShellWindow(in: fixture.session("a"))
        #expect(await eventually { fixture.deck.calls("new-window") == ["new-window agentdeck_a /p/a"] })
        let pane = try await fixture.selectAndAttach("a")
        fixture.model.newShellWindow(in: fixture.session("a"))
        #expect(await eventually { fixture.deck.calls("new-window").count == 2 })
        #expect(fixture.deck.calls("new-window").last == "new-window \(pane.view!) /p/a")
    }
}
