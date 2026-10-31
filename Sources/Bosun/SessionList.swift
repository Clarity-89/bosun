import BosunCore
import Foundation
import Observation

/// Bosun's own state of the session list: which groups are folded, and the
/// search, Open filter and sort over the rows. The TUI keeps its own in
/// agent-deck's database, with no CLI to read or set them. The folds, the
/// Open filter and the sort are kept in `UserDefaults`; the search starts
/// empty each launch, as the TUI's does.
@MainActor
@Observable
final class SessionList {
    private(set) var collapsedGroups = Set(UserDefaults.standard.stringArray(forKey: "collapsedGroups") ?? []) {
        didSet { UserDefaults.standard.set(collapsedGroups.sorted(), forKey: "collapsedGroups") }
    }
    var filter = SidebarFilter(
        openOnly: UserDefaults.standard.bool(forKey: "sidebarOpenOnly"),
        sort: SidebarSort(rawValue: UserDefaults.standard.string(forKey: "sidebarSort") ?? "") ?? .deck
    ) {
        didSet {
            guard filter.openOnly != oldValue.openOnly || filter.sort != oldValue.sort else { return }
            UserDefaults.standard.set(filter.openOnly, forKey: "sidebarOpenOnly")
            UserDefaults.standard.set(filter.sort.rawValue, forKey: "sidebarSort")
        }
    }

    /// The rows from agent-deck's `groups`: what the filter leaves, in its
    /// order, folded as `collapsedGroups` says, with each session's extra
    /// windows under it. The session at `selected` keeps its row under the
    /// Open filter.
    func rows(groups: [SessionGroup], selected: String?, extraWindows: (String) -> ArraySlice<SessionWindow>) -> [SidebarRow] {
        filter.rows(groups: groups, collapsed: collapsedGroups, selected: selected, extraWindows: extraWindows)
    }

    func toggleGroup(_ name: String) {
        fold { $0.formSymmetricDifference([name]) }
    }

    func foldGroup(_ name: String) {
        fold { $0.insert(name) }
    }

    func unfoldGroup(_ name: String) {
        fold { $0.remove(name) }
    }

    /// A fold asked for in the list; refused while the filter would not
    /// show it, so none lands out of sight.
    private func fold(_ change: (inout Set<String>) -> Void) {
        guard filter.allowsFolding else { return }
        change(&collapsedGroups)
    }

    /// Gives `session` a row before it is selected from outside the list,
    /// by a notification or as a new session: its group unfolds, past the
    /// fold gate, and a search that leaves it out ends. The Open filter
    /// spares the selected session itself.
    func uncover(_ session: DeckSession) {
        if filter.hasQuery, !session.matches(filter.trimmedQuery) {
            filter.query = ""
        }
        collapsedGroups.remove(session.groupName)
    }

    /// A deleted group's fold would otherwise hold for a group of that
    /// name made later.
    func forget(group name: String) {
        collapsedGroups.remove(name)
    }
}
