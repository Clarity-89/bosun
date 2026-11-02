@preconcurrency import Foundation

/// omp's state, as its terminal title spells it (oh-my-pi
/// `utils/title-generator.ts`): `π > label` at its prompt, `π ! label` while
/// a question or a tool approval waits for you, and a spinner frame (or `:`
/// where titles cannot animate) while it works.
public enum OmpState: Equatable, Sendable {
    case atPrompt
    case working
    case asks
}

public struct OmpTitle: Equatable, Sendable {
    public let state: OmpState
    /// omp's name for the task; nil when the title has none.
    public let label: String?

    /// Nil for any other title, omp's with `tui.titleState` off (`π: label`)
    /// included.
    public init?(_ title: String) {
        guard title.hasPrefix("π ") else { return nil }
        let rest = title.dropFirst(2)
        let separator = rest.prefix { $0 != " " }
        guard !separator.isEmpty else { return nil }
        switch separator {
        case ">": state = .atPrompt
        case "!": state = .asks
        default:
            // One spinner frame of any style (braille, pulse, dots, line) or
            // the static `:`; a whole word is another program's title.
            guard separator.count == 1 else { return nil }
            state = .working
        }
        let label = rest.dropFirst(separator.count).drop { $0 == " " }
        self.label = label.isEmpty ? nil : String(label)
    }
}

/// The process table, to tell a pane where omp runs from one whose title it
/// left behind when it exited: tmux keeps a pane's last title.
public struct ProcessTree: Sendable {
    private var children: [Int32: [Int32]] = [:]
    private var arguments: [Int32: [Substring]] = [:]

    /// `ps -axo pid=,ppid=,args=` output.
    public init(psOutput: String) {
        for line in psOutput.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count >= 2, let pid = Int32(fields[0]), let ppid = Int32(fields[1]) else { continue }
            children[ppid, default: []].append(pid)
            arguments[pid] = fields.count == 3 ? fields[2].split(separator: " ") : []
        }
    }

    /// Whether omp runs in `pid` or anywhere below it: a pane's shell may
    /// start it, as `bash → omp`.
    public func runsOmp(under pid: Int32) -> Bool {
        var pending = [pid]
        var seen: Set<Int32> = []
        while let next = pending.popLast() {
            guard seen.insert(next).inserted else { continue }
            if Self.isOmp(arguments[next] ?? []) { return true }
            pending += children[next] ?? []
        }
        return false
    }

    /// `omp` itself, or a script runner starting it (`node …/omp`).
    private static func isOmp(_ arguments: [Substring]) -> Bool {
        func base(_ argument: Substring?) -> Substring? { argument?.split(separator: "/").last }
        guard let program = base(arguments.first) else { return false }
        if program == "omp" { return true }
        return ["node", "bun"].contains(program) && base(arguments.dropFirst().first) == "omp"
    }
}

/// A tmux pane whose title is omp's.
public struct AgentPane: Equatable, Sendable {
    public let tmuxSession: String
    public let windowID: String
    /// tmux's `%N` id, stable for the pane's life. One window can hold
    /// several omp instances, one per pane.
    public let paneID: String
    /// The pane's first process, the shell omp runs under.
    public let panePID: Int32
    public let title: OmpTitle

    static let listFormat = "#{session_name}\t#{window_id}\t#{pane_id}\t#{pane_pid}\t#{pane_title}"

    /// Panes from `listFormat` lines whose title is omp's.
    static func parse(listOutput: String) -> [AgentPane] {
        var seen: Set<String> = []
        return listOutput.split(whereSeparator: \.isNewline).compactMap { line in
            guard let fields = fields(of: line),
                  let title = OmpTitle(fields[4]), let pid = Int32(fields[3]), seen.insert(fields[2]).inserted
            else { return nil }
            return AgentPane(tmuxSession: fields[0], windowID: fields[1], paneID: fields[2], panePID: pid, title: title)
        }
    }

    /// A `listFormat` line's fields; nil for one of Bosun's own views, which
    /// list the same panes again.
    static func fields(of line: Substring) -> [String]? {
        let fields = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 5, !fields[0].hasPrefix(ViewSession.prefix) else { return nil }
        return fields
    }
}

/// One pass over tmux's panes.
public struct PanePoll: Equatable, Sendable {
    /// The panes omp runs in.
    public var omp: [AgentPane]
    /// The tmux sessions where some pane's title begins with a spinner
    /// frame, as codex's does while it works (`⠋ Review PR 1 | project`): a
    /// program at work in the session, whatever agent-deck says of the agent
    /// it started. From the title alone, so one killed mid-turn leaves its
    /// last frame behind until the next program sets the title.
    public var spinning: Set<String>

    public init(omp: [AgentPane] = [], spinning: Set<String> = []) {
        self.omp = omp
        self.spinning = spinning
    }

    /// The sessions of `AgentPane.listFormat` lines whose title spins.
    static func spinningSessions(listOutput: String) -> Set<String> {
        Set(listOutput.split(whereSeparator: \.isNewline).compactMap { line in
            guard let fields = AgentPane.fields(of: line), titleSpins(fields[4]) else { return nil }
            return fields[0]
        })
    }

    /// Whether `title` begins with a braille pattern, the block every
    /// dot spinner's frames come from.
    static func titleSpins(_ title: String) -> Bool {
        guard let first = title.unicodeScalars.first else { return false }
        return (0x2800...0x28FF).contains(first.value)
    }
}

extension AgentDeckCLI {
    /// Every pane omp runs in, and the sessions where a pane spins, on
    /// tmux's default server; nil when tmux or ps did not answer, so a failed
    /// poll does not read as every omp gone. The process table, which tells
    /// a live omp from a title it left behind, is read only when some title
    /// is omp's.
    public func pollPanes() async -> PanePoll? {
        guard let panes = try? await tmux(["list-panes", "-a", "-F", AgentPane.listFormat]), panes.succeeded else { return nil }
        let spinning = PanePoll.spinningSessions(listOutput: panes.stdout)
        let titled = AgentPane.parse(listOutput: panes.stdout)
        guard !titled.isEmpty else { return PanePoll(spinning: spinning) }
        guard let ps = try? await Subprocess.run(
            executable: "/bin/ps", arguments: ["-axo", "pid=,ppid=,args="],
            environment: childEnvironment(binaryDirectory: nil), timeout: .seconds(5)
        ), ps.succeeded else { return nil }
        let tree = ProcessTree(psOutput: ps.stdout)
        return PanePoll(omp: titled.filter { tree.runsOmp(under: $0.panePID) }, spinning: spinning)
    }
}
