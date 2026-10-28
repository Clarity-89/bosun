import AppKit
import BosunCore
import SwiftUI

@main
struct BosunApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let model = DeckModel.shared

    var body: some Scene {
        // One window, as the model has one selection and one pane: opening
        // it from the menu bar brings it forward, or back after a close,
        // where a WindowGroup would add a second window on the same session.
        Window("Bosun", id: "main") {
            MainWindowView(model: model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
            FocusCommands()
            SessionCommands(model: model)
            HelpCommands()
        }

        // A panel, which floats while the main window takes the keys and
        // which reopening the app from the Dock leaves closed.
        UtilityWindow("Keyboard Shortcuts", id: ShortcutsView.windowID) {
            ShortcutsView()
        }
        .windowResizability(.contentSize)
        // The Help menu opens it; the View menu item it would add is a second way.
        .commandsRemoved()

        MenuBarExtra {
            MenuView(model: model)
        } label: {
            // Icon only: a crowded, notched menu bar hides items that do not
            // fit, so every point of width costs visibility.
            if model.waitingCount > 0 {
                Label("\(model.waitingCount)", systemImage: "rectangle.stack.badge.person.crop")
            } else {
                Image(systemName: "rectangle.stack")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

/// Keyboard focus moves between the list and the terminal only on request,
/// so each direction gets a View menu item.
struct FocusCommands: Commands {
    @FocusedBinding(\.sidebarFocused) private var sidebarFocused
    @FocusedBinding(\.terminalFocusRequest) private var terminalFocusRequest

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button("Focus Sidebar") { sidebarFocused = true }
                .shortcut(.focusSidebar)
                .disabled(sidebarFocused == nil)
            Button("Focus Terminal") { terminalFocusRequest? += 1 }
                .shortcut(.focusTerminal)
                .disabled(terminalFocusRequest == nil)
        }
    }
}

/// The cheat sheet, in place of the Help menu's default item: with no help
/// book, that one only says help is not available.
struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { openWindow(id: ShortcutsView.windowID) }
                .shortcut(.cheatSheet)
        }
    }
}

extension FocusedValues {
    /// Whether the key window's session list has keyboard focus.
    @Entry var sidebarFocused: Binding<Bool>?
    /// The key window's terminal focus request counter; each increment
    /// moves keyboard focus into its pane. Nil while it has no pane.
    @Entry var terminalFocusRequest: Binding<Int>?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()
        DeckModel.shared.start()
    }

    /// Closing the window must not quit: the menu bar item keeps running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in NSApp.windows where window.canBecomeKey && !(window is NSPanel) {
                window.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        DeckModel.shared.stop()
    }

    /// `kill`/`pkill` deliver SIGTERM, which bypasses applicationWillTerminate
    /// and would orphan the `events follow` child; route it through terminate.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }
}
