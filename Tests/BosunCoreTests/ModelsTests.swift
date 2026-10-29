import Foundation
import Testing
@testable import BosunCore

/// Fixtures are real agent-deck v1.16.34 output with identifiers changed;
/// the shapes are what Bosun must keep decoding when agent-deck adds fields.
@Suite struct ListDecodingTests {
    static let row = """
    {
      "id": "8b232f9f-1776403870",
      "title": "omp",
      "path": "/Users/me/dev/oh-my-pi",
      "group": "omp",
      "tool": "shell",
      "account": "",
      "command": "omp update && omp",
      "status": "error",
      "status_source": "live",
      "tmux_session": "agentdeck_omp_a288e826",
      "profile": "default",
      "created_at": "2026-04-17T08:31:10+03:00",
      "archived": false,
      "archived_at": "0001-01-01T00:00:00Z",
      "codex_session_id": "019d4e05-1301-70a1-ba01-4e622ced7b9c",
      "last_activity_at": "2026-09-25T12:21:24+03:00",
      "viewers": []
    }
    """

    @Test func decodesTheFieldsBosunUsesAndIgnoresTheRest() throws {
        let session = try AgentDeckCLI.jsonDecoder().decode(DeckSession.self, from: Data(Self.row.utf8))
        #expect(session.id == "8b232f9f-1776403870")
        #expect(session.title == "omp")
        #expect(session.tool == "shell")
        #expect(session.status == .error)
        #expect(session.tmuxSession == "agentdeck_omp_a288e826")
        #expect(session.substate == nil)
        #expect(session.archived == false)
        #expect(session.lastActivityAt == Date(timeIntervalSince1970: 1_790_328_084))
    }

    /// Go writes RFC3339Nano: no fraction, or up to nine digits of one.
    @Test(arguments: [
        ("2026-09-25T12:21:24+03:00", 1_790_328_084.0),
        ("2026-10-26T07:25:43.08408Z", 1_792_999_543.084),
        ("2026-10-26T07:25:43.123456789Z", 1_792_999_543.123),
        ("2026-10-26T07:25:43.5Z", 1_792_999_543.5),
    ])
    func readsGoTimestamps(text: String, seconds: Double) throws {
        let date = try #require(Date(rfc3339: text))
        #expect(abs(date.timeIntervalSince1970 - seconds) < 0.001)
    }

    @Test func unknownStatusDoesNotFailTheWholeList() throws {
        let json = """
        [{"id":"a","title":"a","path":"/p","group":"","tool":"claude","status":"hibernating","archived":false}]
        """
        let sessions = try JSONDecoder().decode([DeckSession].self, from: Data(json.utf8))
        #expect(sessions.first?.status == .unknown)
    }

    @Test func statusIsCaseInsensitive() throws {
        let json = """
        {"id":"a","title":"a","path":"/p","group":"","tool":"claude","status":"Waiting","archived":false}
        """
        let session = try JSONDecoder().decode(DeckSession.self, from: Data(json.utf8))
        #expect(session.status == .waiting)
    }

    @Test func missingTmuxSessionIsAbsentNotAnError() throws {
        let json = """
        {"id":"a","title":"a","path":"/p","group":"g","tool":"codex","status":"stopped","archived":true}
        """
        let session = try JSONDecoder().decode(DeckSession.self, from: Data(json.utf8))
        #expect(session.tmuxSession == nil)
        #expect(session.archived)
    }
}

/// One line of `events follow --json`: canonical JSON, keys sorted.
@Suite struct BusFrameDecodingTests {
    @Test func decodesStatusFrame() throws {
        let line = """
        {"cursor":3302519,"data":{"changed_at":"2026-10-26T07:25:43.08408Z","from":"starting","substate":"","tmux_session":"agentdeck_bosun-step0_87030110","to":"idle","tool":"shell"},"event_id":"d3c0a9f1","kind":"session.status","session_id":"9c51b648-1792999266","ts":1792999543084}
        """
        let frame = try JSONDecoder().decode(BusFrame.self, from: Data(line.utf8))
        #expect(frame.cursor == 3_302_519)
        #expect(frame.kind == "session.status")
        #expect(frame.sessionID == "9c51b648-1792999266")
        #expect(frame.data?.to == .idle)
        #expect(frame.data?.from == .starting)
    }

    @Test func frameWithoutDataDecodes() throws {
        let line = """
        {"cursor":7,"event_id":"x","kind":"session.turn","session_id":"s","ts":1}
        """
        let frame = try JSONDecoder().decode(BusFrame.self, from: Data(line.utf8))
        #expect(frame.data == nil)
    }

    @Test func statsExposeCursorAndEnabled() throws {
        let json = """
        {"enabled":true,"dir":"/Users/me/.local/share/agent-deck/bus/default","cursor":3302517,"published":0,"written":0,"synced":0,"dropped":0,"queue_len":0,"queue_cap":1024,"kinds":{"tmux.output":1650223}}
        """
        let stats = try JSONDecoder().decode(EventsStats.self, from: Data(json.utf8))
        #expect(stats.enabled)
        #expect(stats.cursor == 3_302_517)
    }
}

/// `events stats --json` from agent-deck with `status_owner` (v1.16.34 dev
/// build). An older build leaves the owner nil and an owner newer than Bosun
/// decodes as `other`, both with the stats intact: Bosun neither warns nor
/// offers an install.
@Suite struct StatusOwnerDecodingTests {
    static let stats = """
        {"enabled":true,"dir":"/Users/me/.local/share/agent-deck/bus/default","cursor":3302834,"published":0,"written":0,"synced":0,"dropped":0,"queue_len":0,"queue_cap":0,"status_owner":"tui","kinds":{"session.status":165,"tmux.output":1650223}}
        """

    static func decode(_ json: String) throws -> EventsStats {
        try JSONDecoder().decode(EventsStats.self, from: Data(json.utf8))
    }

    @Test(arguments: zip(["tui", "notify-daemon", "none"], [StatusOwner.tui, .notifyDaemon, .nobody]))
    func decodesEachOwner(raw: String, owner: StatusOwner) throws {
        let stats = try Self.decode(Self.stats.replacingOccurrences(of: #""status_owner":"tui""#, with: #""status_owner":"\#(raw)""#))
        #expect(stats.statusOwner == owner)
    }

    @Test func olderAgentDeckHasNoOwner() throws {
        let stats = try Self.decode(Self.stats.replacingOccurrences(of: #""status_owner":"tui","#, with: ""))
        #expect(stats.statusOwner == nil)
        #expect(stats.enabled)
    }

    @Test func newerOwnerIsOtherNotAFailure() throws {
        let stats = try Self.decode(Self.stats.replacingOccurrences(of: #""status_owner":"tui""#, with: #""status_owner":"web""#))
        #expect(stats.statusOwner == .other)
        #expect(stats.cursor == 3_302_834)
    }
}
