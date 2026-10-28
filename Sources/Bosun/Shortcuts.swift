import AppKit
import SwiftUI

/// Every keyboard shortcut Bosun has, in one table: the menus bind from it,
/// the session list handles from it and the cheat sheet lists it, so none
/// of the three can drift from the others.
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
    case toggleGroup, foldGroup, unfoldGroup
    case reorderUp, reorderDown
    case newSession, quickSession
    case rename, restart, stop, delete
    case splitSideBySide, openInGhostty
    case focusTerminal, focusSidebar, cheatSheet

    enum Section: String, CaseIterable {
        case sessionList = "Session list"
        case sessions = "Sessions"
        case window = "Window"
    }

    var section: Section {
        switch self {
        case .moveDown, .moveUp, .toggleGroup, .foldGroup, .unfoldGroup, .reorderUp, .reorderDown: .sessionList
        case .newSession, .quickSession, .rename, .restart, .stop, .delete, .splitSideBySide, .openInGhostty: .sessions
        case .focusTerminal, .focusSidebar, .cheatSheet: .window
        }
    }

    var title: String {
        switch self {
        case .moveDown: "Select the next row"
        case .moveUp: "Select the previous row"
        case .toggleGroup: "Fold or unfold the group"
        case .foldGroup: "Fold the group; from a session, select its group"
        case .unfoldGroup: "Unfold the group"
        case .reorderUp: "Move the session or group up"
        case .reorderDown: "Move the session or group down"
        case .newSession: "New session in the selected group…"
        case .quickSession: "Quick session, with the dialog's defaults"
        case .rename: "Rename the session…"
        case .restart: "Restart the session, or start a stopped one"
        case .stop: "Stop the session"
        case .delete: "Delete the session, or close the selected window…"
        case .splitSideBySide: "Open a shell beside the session's agent"
        case .openInGhostty: "Open the session in a Ghostty window"
        case .focusTerminal: "Focus the terminal"
        case .focusSidebar: "Focus the session list"
        case .cheatSheet: "Show these shortcuts"
        }
    }

    /// The TUI's key; nil where the list has none.
    var listKey: KeyEquivalent? {
        switch self {
        case .moveDown: "j"
        case .moveUp: "k"
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
        case .openInGhostty, .focusTerminal: .return
        case .focusSidebar: nil
        case .cheatSheet: "?"
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

    /// The list key as the cheat sheet shows it, with the other key that
    /// does the same.
    var listKeyLabel: String? {
        switch self {
        case .moveDown: "j / ↓"
        case .moveUp: "k / ↑"
        case .toggleGroup: "⇥ / ↩"
        case .openInGhostty: "⇧↩"
        default: listKey.map(\.symbol)
        }
    }

    /// The menu bar's shortcut; nil for an action only the list has a key for.
    var menu: KeyboardShortcut? {
        switch self {
        case .moveDown, .moveUp, .toggleGroup, .foldGroup, .unfoldGroup, .reorderUp, .reorderDown: nil
        case .newSession: KeyboardShortcut("n")
        case .quickSession: KeyboardShortcut("n", modifiers: [.command, .shift])
        case .rename: KeyboardShortcut("r")
        case .restart: KeyboardShortcut("r", modifiers: [.command, .shift])
        case .stop: KeyboardShortcut(".")
        case .delete: KeyboardShortcut(.delete, modifiers: [.command, .option])
        case .splitSideBySide: KeyboardShortcut("h", modifiers: [.command, .shift])
        case .openInGhostty: KeyboardShortcut("o", modifiers: [.command, .shift])
        case .focusTerminal: KeyboardShortcut("e", modifiers: [.command, .shift])
        case .focusSidebar: KeyboardShortcut("l", modifiers: [.command, .shift])
        case .cheatSheet: KeyboardShortcut("/")
        }
    }

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
    /// Return and Tab do not.
    var typesCharacter: Bool {
        character.unicodeScalars.allSatisfy { $0.properties.generalCategory != .control }
    }
}

/// The cheat sheet, from the same table the keys use.
struct ShortcutsView: View {
    static let windowID = "shortcuts"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Text("In the list")
                    Text("Anywhere")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ForEach(Shortcut.Section.allCases, id: \.self) { section in
                    Text(section.rawValue)
                        .font(.headline)
                        .padding(.top, 8)
                    ForEach(Shortcut.allCases.filter { $0.section == section }, id: \.self) { action in
                        GridRow {
                            Text(action.title)
                            Text(action.listKeyLabel ?? "")
                            Text(action.menu?.label ?? "")
                        }
                    }
                }
            }
            Text("List keys work while the session list has focus; \(Shortcut.focusSidebar.menu?.label ?? "") puts it there. The others work anywhere in the window, the terminal included.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 420, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .fixedSize()
    }
}
