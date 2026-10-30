import AppKit
import SwiftUI

/// Every keyboard shortcut Bosun has, in one table: the menus bind from it,
/// the session list handles from it and the cheat sheet lists it, so none
/// of the three can drift from the others. The table holds the keys; what
/// an action does lives with its menu item and in the list's `perform`.
///
/// `listKey` is the TUI's key for the action and works while the session
/// list has focus, so a letter never reaches the terminal. `menu` works
/// anywhere in the window, the terminal included: the pane hands these keys
/// to the menu bar before Ghostty's keybinds see them (`menuAction(for:)`).
/// So a menu shortcut may take a Ghostty keybind only for an action the
/// embedded pane never performs, as ⌘N takes `new_window`; ShortcutTests
/// checks that against Ghostty's defaults.
enum Shortcut: CaseIterable {
    case moveDown, moveUp
    case activate, toggleGroup, foldGroup, unfoldGroup
    case reorderUp, reorderDown
    case newSession, quickSession
    case rename, restart, stop, delete
    case splitSideBySide, openInGhostty
    case toggleSessionList, focusTerminal, focusSidebar, cheatSheet, settings

    enum Section: String, CaseIterable {
        case sessionList = "Session list"
        case sessions = "Sessions"
        case window = "Window"
    }

    var section: Section {
        switch self {
        case .moveDown, .moveUp, .activate, .toggleGroup, .foldGroup, .unfoldGroup, .reorderUp, .reorderDown: .sessionList
        case .newSession, .quickSession, .rename, .restart, .stop, .delete, .splitSideBySide, .openInGhostty: .sessions
        case .toggleSessionList, .focusTerminal, .focusSidebar, .cheatSheet, .settings: .window
        }
    }

    /// What the action does, as the cheat sheet puts it.
    var title: String {
        switch self {
        case .moveDown: "Select the next row"
        case .moveUp: "Select the previous row"
        case .activate: "Focus the terminal; on a group, fold or unfold it"
        case .toggleGroup: "Fold or unfold the group"
        case .foldGroup: "Fold the group; from a session, select its group"
        case .unfoldGroup: "Unfold the group"
        case .reorderUp: "Move the session or group up"
        case .reorderDown: "Move the session or group down"
        case .newSession: "New session in the selected group…"
        case .quickSession: "Quick session, with the dialog's defaults"
        case .rename: "Rename the session…"
        case .restart: "Restart the session, or start a stopped one"
        case .stop: "Stop the session…"
        case .delete: "Delete the session or group, or close the selected window…"
        case .splitSideBySide: "Open a shell beside the session's agent"
        case .openInGhostty: "Open the session in a Ghostty window"
        case .toggleSessionList: "Hide or show the session list"
        case .focusTerminal: "Focus the terminal"
        case .focusSidebar: "Focus the session list"
        case .cheatSheet: "Show these shortcuts"
        case .settings: "Settings: notifications and the unread count"
        }
    }

    /// The TUI's key; nil where the list has none.
    var listKey: KeyEquivalent? {
        switch self {
        case .moveDown: "j"
        case .moveUp: "k"
        case .activate, .openInGhostty: .return
        case .toggleGroup: .tab
        case .foldGroup: "h"
        case .unfoldGroup: "l"
        case .reorderUp: "K"
        case .reorderDown: "J"
        case .newSession: "n"
        case .quickSession: "N"
        case .rename: "r"
        case .restart: "R"
        case .stop: "D"
        case .delete: "d"
        case .splitSideBySide: "H"
        case .cheatSheet: "?"
        case .toggleSessionList, .focusTerminal, .focusSidebar, .settings: nil
        }
    }

    /// Shift on a key whose character Shift leaves alone. N and ? say it
    /// themselves.
    var listKeyShifted: Bool { self == .openInGhostty }

    /// Navigation keeps going while the key is held; an action runs once.
    var repeats: Bool {
        switch self {
        case .moveDown, .moveUp, .reorderUp, .reorderDown: true
        default: false
        }
    }

    /// The list key as the cheat sheet shows it, with the arrow key the
    /// list takes for the same move; empty where the list has no key.
    var listKeyLabel: String {
        switch self {
        case .moveDown: "j / ↓"
        case .moveUp: "k / ↑"
        default: listKey.map { (listKeyShifted ? "⇧" : "") + $0.symbol } ?? ""
        }
    }

    /// The menu bar's shortcut; nil for an action only the list has a key for.
    var menu: KeyboardShortcut? {
        switch self {
        case .moveDown, .moveUp, .activate, .toggleGroup, .foldGroup, .unfoldGroup, .reorderUp, .reorderDown: nil
        case .newSession: KeyboardShortcut("n")
        case .quickSession: KeyboardShortcut("n", modifiers: [.command, .shift])
        case .rename: KeyboardShortcut("r")
        case .restart: KeyboardShortcut("r", modifiers: [.command, .shift])
        case .stop: KeyboardShortcut(".")
        case .delete: KeyboardShortcut(.delete, modifiers: [.command, .option])
        case .splitSideBySide: KeyboardShortcut("h", modifiers: [.command, .shift])
        case .openInGhostty: KeyboardShortcut("o", modifiers: [.command, .shift])
        // The TUI's key for its list. No ⌘: agent-deck's tmux binding
        // already swallows ⌃Q outside its own sessions, so in Bosun's views
        // the terminal never had it.
        case .toggleSessionList: KeyboardShortcut("q", modifiers: .control)
        case .focusTerminal: KeyboardShortcut("e", modifiers: [.command, .shift])
        case .focusSidebar: KeyboardShortcut("l", modifiers: [.command, .shift])
        case .cheatSheet: KeyboardShortcut("/")
        // SwiftUI's own Settings item holds it; the entry lets the terminal
        // hand ⌘, over, where Ghostty would take it for `open_config`.
        case .settings: KeyboardShortcut(",")
        }
    }

    /// The menu shortcut as a menu prints it; empty where there is none.
    var menuLabel: String { menu?.label ?? "" }

    static let listKeys = Set(allCases.compactMap(\.listKey))

    /// The action a key pressed in the session list asks for; nil for ⌘, ⌥
    /// and ⌃ combinations, which are the menu bar's.
    static func listAction(key: KeyEquivalent, modifiers: EventModifiers) -> Shortcut? {
        guard modifiers.isDisjoint(with: [.command, .option, .control]) else { return nil }
        let shifted = modifiers.contains(.shift) && !key.typesCharacter
        return allCases.first { $0.listKey == key && $0.listKeyShifted == shifted }
    }

    /// The menu bar action a key event asks for, from the characters AppKit
    /// reports with Shift only (`charactersIgnoringModifiers`); nil for any
    /// other key, which stays the terminal's.
    static func menuAction(key: String, modifiers: EventModifiers) -> Shortcut? {
        // The ⌫ key reports DEL; KeyEquivalent.delete is backspace.
        let key = key == "\u{7F}" ? String(KeyEquivalent.delete.character) : key.lowercased()
        let modifiers = modifiers.intersection([.command, .shift, .option, .control])
        return allCases.first { action in
            guard let menu = action.menu else { return false }
            return menu.modifiers == modifiers && String(menu.key.character).lowercased() == key
        }
    }

    static func menuAction(for event: NSEvent) -> Shortcut? {
        let flags = event.modifierFlags
        let modifiers: EventModifiers = [
            flags.contains(.command) ? .command : [],
            flags.contains(.shift) ? .shift : [],
            flags.contains(.option) ? .option : [],
            flags.contains(.control) ? .control : [],
        ]
        return menuAction(key: event.charactersIgnoringModifiers ?? "", modifiers: modifiers)
    }
}

extension View {
    /// The action's menu bar shortcut, which a context menu only displays.
    func shortcut(_ action: Shortcut) -> some View {
        keyboardShortcut(action.menu)
    }
}

extension KeyboardShortcut {
    /// As a menu prints it: ⌃⌥⇧⌘, then the key.
    var label: String {
        let symbols: [(EventModifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return symbols.filter { modifiers.contains($0.0) }.map(\.1).joined() + key.symbol.uppercased()
    }
}

extension KeyEquivalent {
    var symbol: String {
        switch self {
        case .return: "↩"
        case .tab: "⇥"
        case .delete: "⌫"
        default: String(character)
        }
    }

    /// Whether the key types a character, which then carries Shift: N, ?.
    /// Return, Tab, ⌫ and Escape are ASCII controls; AppKit puts the other
    /// function keys (arrows, Home, F1…) in the Private Use Area, U+F700 up.
    var typesCharacter: Bool {
        character.unicodeScalars.allSatisfy { ![.control, .privateUse].contains($0.properties.generalCategory) }
    }
}
