extension DeckSession {
    /// agent-deck's order, as the TUI shows it with its default `group_sort`:
    /// groups as `group list` reports them, a group's sessions as `list`
    /// reports them (creation order, or the TUI's manual one). A group
    /// `groups` lacks follows the reported ones, by path. Each group's
    /// sessions end up together. Pins are not applied: `list` does not
    /// report them.
    public static func inDeckOrder(_ sessions: [DeckSession], groups: [DeckGroup]) -> [DeckSession] {
        let rank = Dictionary(groups.enumerated().map { ($1.path, $0) }, uniquingKeysWith: { first, _ in first })
        return sessions.enumerated()
            .sorted { a, b in
                let rankA = rank[a.element.group] ?? groups.count
                let rankB = rank[b.element.group] ?? groups.count
                if rankA != rankB { return rankA < rankB }
                if a.element.group != b.element.group { return a.element.group < b.element.group }
                return a.offset < b.offset
            }
            .map(\.element)
    }
}
