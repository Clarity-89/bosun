import SwiftUI
import Testing
@testable import Bosun

/// A key with its modifiers, in Ghostty's terms: `super+shift+n`.
private struct Trigger: Hashable, CustomStringConvertible {
    let modifiers: Set<String>
    let key: String

    /// The modifiers off the front, then the key, which may itself be `+`.
    init(ghostty: Substring) {
        var rest = ghostty
        var modifiers: Set<String> = []
        while let modifier = ["super", "ctrl", "alt", "shift"].first(where: { rest.hasPrefix("\($0)+") }) {
            modifiers.insert(modifier)
            rest = rest.dropFirst(modifier.count + 1)
        }
        self.modifiers = modifiers
        key = String(rest)
    }

    /// A `+list-keybinds` line, `super+n=new_window`: its trigger and its
    /// action's name, arguments dropped. The key may itself be `=`; no
    /// action carries one, so the last `=` separates them.
    static func keybind(_ line: Substring) -> (Trigger, String) {
        let separator = line.lastIndex(of: "=")!
        let action = line[line.index(after: separator)...].prefix { $0 != ":" }
        return (Trigger(ghostty: line[..<separator]), String(action))
    }

    init(_ shortcut: KeyboardShortcut) {
        let names: [(EventModifiers, String)] = [(.command, "super"), (.control, "ctrl"), (.option, "alt"), (.shift, "shift")]
        modifiers = Set(names.filter { shortcut.modifiers.contains($0.0) }.map(\.1))
        key = switch shortcut.key {
        case .delete: "backspace"
        case .return: "enter"
        case .tab: "tab"
        case .escape: "escape"
        case .space: "space"
        case .upArrow: "arrow_up"
        case .downArrow: "arrow_down"
        case .leftArrow: "arrow_left"
        case .rightArrow: "arrow_right"
        default: String(shortcut.key.character).lowercased()
        }
    }

    var description: String {
        (["super", "ctrl", "alt", "shift"].filter(modifiers.contains) + [key]).joined(separator: "+")
    }
}

/// Ghostty 1.3.1's default ⌘ keybinds, the version scripts/fetch-ghosttykit.sh
/// pins; refresh them with the pin:
/// `ghostty +list-keybinds --default | grep super | sed 's/keybind = //'`.
/// Key to action name, arguments dropped.
private let ghosttyDefaults: [Trigger: String] = Dictionary(uniqueKeysWithValues: """
    super+shift+,=reload_config
    super+,=open_config
    super+c=copy_to_clipboard:mixed
    super+v=paste_from_clipboard
    super+==increase_font_size:1
    super++=increase_font_size:1
    super+-=decrease_font_size:1
    super+0=reset_font_size
    super+ctrl+shift+j=write_screen_file:copy,plain
    super+shift+j=write_screen_file:paste,plain
    super+alt+shift+j=write_screen_file:open,plain
    super+digit_1=goto_tab:1
    super+1=goto_tab:1
    super+digit_2=goto_tab:2
    super+2=goto_tab:2
    super+digit_3=goto_tab:3
    super+3=goto_tab:3
    super+digit_4=goto_tab:4
    super+4=goto_tab:4
    super+digit_5=goto_tab:5
    super+5=goto_tab:5
    super+digit_6=goto_tab:6
    super+6=goto_tab:6
    super+digit_7=goto_tab:7
    super+7=goto_tab:7
    super+digit_8=goto_tab:8
    super+8=goto_tab:8
    super+9=last_tab
    super+enter=toggle_fullscreen
    super+shift+enter=toggle_split_zoom
    super+shift+p=toggle_command_palette
    super+q=quit
    super+k=clear_screen
    super+a=select_all
    super+shift+t=undo
    super+z=undo
    super+shift+z=redo
    super+home=scroll_to_top
    super+end=scroll_to_bottom
    super+page_up=scroll_page_up
    super+page_down=scroll_page_down
    super+j=scroll_to_selection
    super+shift+arrow_up=jump_to_prompt:-1
    super+shift+arrow_down=jump_to_prompt:1
    super+n=new_window
    super+w=close_surface
    super+alt+w=close_tab:this
    super+shift+w=close_window
    super+alt+shift+w=close_all_windows
    super+t=new_tab
    super+shift+[=previous_tab
    super+shift+]=next_tab
    super+d=new_split:right
    super+shift+d=new_split:down
    super+[=goto_split:previous
    super+]=goto_split:next
    super+alt+arrow_up=goto_split:up
    super+alt+arrow_down=goto_split:down
    super+alt+arrow_left=goto_split:left
    super+alt+arrow_right=goto_split:right
    super+ctrl+arrow_up=resize_split:up,10
    super+ctrl+arrow_down=resize_split:down,10
    super+ctrl+arrow_left=resize_split:left,10
    super+ctrl+arrow_right=resize_split:right,10
    super+ctrl+==equalize_splits
    super+arrow_up=jump_to_prompt:-1
    super+arrow_down=jump_to_prompt:1
    super+f=start_search
    super+e=search_selection
    super+shift+f=end_search
    super+g=navigate_search:next
    super+shift+g=navigate_search:previous
    super+alt+i=inspector:toggle
    super+ctrl+f=toggle_fullscreen
    super+shift+v=paste_from_selection
    super+arrow_right=text:\\x05
    super+arrow_left=text:\\x01
    super+backspace=text:\\x15
    """.split(separator: "\n").map(Trigger.keybind))

/// What a single embedded pane has no use for: Ghostty's windows, tabs and
/// splits, and opening Ghostty's own config. GhosttyActionRouter performs
/// none of these, so a menu shortcut may take their keys.
private let paneIgnoredActions: Set<String> = [
    "new_window", "new_tab", "new_split", "goto_tab", "last_tab", "previous_tab", "next_tab",
    "close_tab", "close_window", "close_all_windows", "goto_split", "resize_split", "equalize_splits",
    "toggle_split_zoom", "open_config",
]

/// The items macOS adds to Bosun's own menus that Ghostty does not bind:
/// Hide, Hide Others, Minimize, Cut, Show Sidebar and Show Toolbar.
private let appMenuItems = "super+h super+alt+h super+m super+x super+ctrl+s super+alt+t"
    .split(separator: " ").map(Trigger.init(ghostty:))

@Suite struct ShortcutTests {
    /// The pane hands Bosun's shortcuts to the menu bar ahead of Ghostty, so
    /// one on a Ghostty keybind the pane performs would take that action
    /// away; one the app menus hold already would do two things.
    @Test(arguments: Shortcut.allCases.filter { $0.menu != nil })
    func menuShortcutTakesNoKeybindInUse(_ action: Shortcut) throws {
        let trigger = Trigger(try #require(action.menu))
        if let bound = ghosttyDefaults[trigger] {
            #expect(paneIgnoredActions.contains(bound), "Ghostty binds \(trigger) to \(bound)")
        }
        #expect(!appMenuItems.contains(trigger), "a standard menu item holds \(trigger)")
    }

    /// A menu key equivalent without ⌘ takes that key from the terminal. ⌃Q
    /// alone may: agent-deck's tmux binding swallows it in every session but
    /// its own, Bosun's views included.
    @Test(arguments: Shortcut.allCases.filter { $0.menu != nil })
    func menuShortcutHoldsCommand(_ action: Shortcut) throws {
        let menu = try #require(action.menu)
        if !menu.modifiers.contains(.command) {
            #expect(Trigger(menu) == Trigger(ghostty: "ctrl+q"))
        }
    }

    @Test func noTwoActionsShareAKey() {
        let menus = Shortcut.allCases.compactMap { $0.menu.map(Trigger.init) }
        #expect(Set(menus).count == menus.count)
        let listKeys = Shortcut.allCases.compactMap { action in action.listKey.map { [String($0.character), "\(action.listKeyShifted)"] } }
        #expect(Set(listKeys).count == listKeys.count)
    }

    /// SwiftUI reports Shift+n as `N` with Shift held, and Caps Lock+n as `n`.
    @Test(arguments: [
        (KeyEquivalent("n"), EventModifiers(), Shortcut.newSession),
        ("N", .shift, .quickSession),
        ("n", .capsLock, .newSession),
        ("?", .shift, .cheatSheet),
        (.return, [], .activate),
        (.return, .shift, .openInGhostty),
        ("j", [], .moveDown),
    ] as [(KeyEquivalent, EventModifiers, Shortcut)])
    func listKeyPicksItsAction(key: KeyEquivalent, modifiers: EventModifiers, action: Shortcut) {
        #expect(Shortcut.listAction(key: key, modifiers: modifiers) == action)
    }

    /// ⌘, ⌥ and ⌃ combinations are the menu bar's; Shift+Tab moves focus.
    @Test(arguments: [
        (KeyEquivalent("n"), EventModifiers.command),
        ("r", .option),
        ("d", .control),
        (.tab, .shift),
    ] as [(KeyEquivalent, EventModifiers)])
    func modifiedKeyIsNotAListKey(key: KeyEquivalent, modifiers: EventModifiers) {
        #expect(Shortcut.listAction(key: key, modifiers: modifiers) == nil)
    }

    /// Shift stays a modifier on a key that types nothing, AppKit's
    /// function keys included: a shifted arrow must never match an
    /// unshifted list key. A typed character carries its own Shift.
    @Test(arguments: [
        (KeyEquivalent.return, false), (.tab, false), (.upArrow, false), (.home, false),
        ("N", true), ("?", true), (.space, true),
    ] as [(KeyEquivalent, Bool)])
    func shiftRidesOnTypedCharactersOnly(key: KeyEquivalent, typesCharacter: Bool) {
        #expect(key.typesCharacter == typesCharacter)
    }

    /// The pane hands these to the menu bar; AppKit reports Shift in the
    /// characters (`N`) and ⌫ as DEL.
    @Test(arguments: [
        ("n", EventModifiers.command, Shortcut.newSession),
        ("N", [.command, .shift], .quickSession),
        ("\u{7F}", [.command, .option], .delete),
        ("/", .command, .cheatSheet),
        ("q", .control, .toggleSessionList),
        (",", .command, .settings),
        ("n", [.command, .capsLock], .newSession),
    ] as [(String, EventModifiers, Shortcut)])
    func menuKeyReachesTheMenuBar(key: String, modifiers: EventModifiers, action: Shortcut) {
        #expect(Shortcut.menuAction(key: key, modifiers: modifiers) == action)
    }

    /// Every other ⌘ key stays Ghostty's: copy, its own ⌘⌫, a near miss.
    @Test(arguments: [
        ("c", EventModifiers.command),
        ("\u{7F}", .command),
        ("n", [.command, .control]),
        ("n", []),
    ] as [(String, EventModifiers)])
    func otherKeyStaysTheTerminals(key: String, modifiers: EventModifiers) {
        #expect(Shortcut.menuAction(key: key, modifiers: modifiers) == nil)
    }
}
