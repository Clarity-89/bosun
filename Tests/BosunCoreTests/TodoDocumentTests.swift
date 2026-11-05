import Testing
@testable import BosunCore

/// The to-do list as markdown: GitHub's task items under headings, and
/// everything else left alone.
@Suite struct TodoDocumentTests {
    static let text = """
        # Today
        - [ ] Review the checks
        - [x] Reply to Sarah
          * [ ] with the rollout dates
        Notes, not an item.
        - plain bullet
        ## grafana
        + [X] profile `DashboardListPanel`
        -[ ] no space after the bullet
        - [ ]no space after the mark

        """

    @Test func readsHeadingsItemsAndTheRest() {
        let document = TodoDocument(text: Self.text)
        #expect(document.lines == [
            .heading(level: 1, title: "Today"),
            .item(done: false, text: "Review the checks", indent: 0),
            .item(done: true, text: "Reply to Sarah", indent: 0),
            .item(done: false, text: "with the rollout dates", indent: 2),
            .other("Notes, not an item."),
            .other("- plain bullet"),
            .heading(level: 2, title: "grafana"),
            .item(done: true, text: "profile `DashboardListPanel`", indent: 0),
            .other("-[ ] no space after the bullet"),
            .other("- [ ]no space after the mark"),
            .other(""),
        ])
        #expect(document.openCount == 2)
    }

    /// A toggle changes the mark alone, whatever the bullet and spacing.
    @Test func togglingChangesOnlyTheMark() {
        let document = TodoDocument(text: "# T\n*   [ ]   spaced out  \n- [X] done\ntext\n")
        #expect(document.toggling(lineAt: 1) == "# T\n*   [x]   spaced out  \n- [X] done\ntext\n")
        #expect(document.toggling(lineAt: 2) == "# T\n*   [ ]   spaced out  \n- [ ] done\ntext\n")
        #expect(document.toggling(lineAt: 0) == nil)
        #expect(document.toggling(lineAt: 3) == nil)
        #expect(document.toggling(lineAt: 9) == nil)
    }

    @Test func emptinessIsWhitespaceOnly() {
        #expect(TodoDocument(text: "").isEmpty)
        #expect(TodoDocument(text: " \n\t\n").isEmpty)
        #expect(!TodoDocument(text: "- [ ]").isEmpty)
        #expect(TodoDocument(text: "- [ ]").lines == [.item(done: false, text: "", indent: 0)])
    }
}
