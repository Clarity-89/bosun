import Testing
@testable import BosunCore

/// omp's terminal title, as `tmux list-panes` reports it; titles are live
/// ones from tmux with the labels kept.
@Suite struct OmpTitleTests {
    @Test(arguments: [
        ("π > 🔬 BOSUN: Review Bosun pull request 26", OmpState.atPrompt, "🔬 BOSUN: Review Bosun pull request 26"),
        ("π ⠦ ⚓ BOSUN: Implement Bosun issue 12", .working, "⚓ BOSUN: Implement Bosun issue 12"),
        ("π ! wf-tracker", .asks, "wf-tracker"),
        ("π ◔ pulse style", .working, "pulse style"),
        ("π \\ line style", .working, "line style"),
        ("π : static title host", .working, "static title host"),
    ])
    func readsStateAndLabel(title: String, state: OmpState, label: String) throws {
        let parsed = try #require(OmpTitle(title))
        #expect(parsed.state == state)
        #expect(parsed.label == label)
    }

    @Test func titleWithoutALabelStillHasAState() throws {
        let parsed = try #require(OmpTitle("π !"))
        #expect(parsed.state == .asks)
        #expect(parsed.label == nil)
    }

    /// omp with `tui.titleState` off, a shell's title, and a word where the
    /// separator goes are not omp's state.
    @Test(arguments: ["π: wf-tracker", "zsh", "Alexs-MacBook-Pro.local", "π working on it"])
    func otherTitlesAreNotOmps(title: String) {
        #expect(OmpTitle(title) == nil)
    }
}

/// `ps -axo pid=,ppid=,args=` lines.
@Suite struct ProcessTreeTests {
    static let table = """
          1     0 /sbin/launchd
      16650     1 -bash
      17074 16650 bash
      17080 17074 omp
      53611     1 -bash
      54030 53611 /Users/me/.bun/bin/omp --resume
      60000     1 -zsh
      60001 60000 node /Users/me/.nvm/versions/node/v24.11.0/bin/omp
      70000     1 -zsh
      70001 70000 vim compass.txt
    """

    /// omp may run under the pane's shell, or under a shell that shell started.
    @Test(arguments: [Int32(16650), 53611, 60000])
    func findsOmpBelowThePanesProcess(pid: Int32) {
        #expect(ProcessTree(psOutput: Self.table).runsOmp(under: pid))
    }

    @Test func aPaneWithoutOmpHasNone() {
        #expect(!ProcessTree(psOutput: Self.table).runsOmp(under: 70000))
    }
}

/// `list-panes -a` lines in `AgentPane.listFormat`.
@Suite struct AgentPaneTests {
    static let panes = [
        "agentdeck_native-app_132a98c8\t@12\t%41\t53611\tπ > 🔬 BOSUN: Review Bosun pull request 26",
        "agentdeck_native-app_132a98c8\t@12\t%31\t16650\tπ ⠦ ⚓ BOSUN: Implement Bosun issue 12",
        "bosun-view-606-1\t@12\t%41\t53611\tπ > 🔬 BOSUN: Review Bosun pull request 26",
        "agentdeck_clarityv2_b01f8fb7\t@3\t%7\t70000\tπ > Orient in repository",
        "agentdeck_api_1a2b\t@9\t%9\t60000\tzsh",
    ].joined(separator: "\n")

    /// Two omp instances in one window are two panes; Bosun's view lists the
    /// first again, and a pane whose omp has exited keeps only its title,
    /// which the process table rules out.
    @Test func everyLiveOmpPaneOnce() {
        let titled = AgentPane.parse(listOutput: Self.panes)
        #expect(titled.map(\.paneID) == ["%41", "%31", "%7"])
        let tree = ProcessTree(psOutput: ProcessTreeTests.table)
        let panes = titled.filter { tree.runsOmp(under: $0.panePID) }
        #expect(panes.map(\.paneID) == ["%41", "%31"])
        #expect(panes.map(\.title.state) == [.atPrompt, .working])
        #expect(Set(panes.map(\.windowID)) == ["@12"])
    }
}
