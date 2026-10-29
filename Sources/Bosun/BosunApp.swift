import AppKit
import BosunCore
import SwiftUI

@main
struct BosunApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let model = DeckModel.shared

    init() {
        AttentionSettings.register()
    }

    var body: some Scene {
        // One window, as the model has one selection and one pane: opening
        // it from the menu bar brings it forward, or back after a close,
        // where a WindowGroup would add a second window on the same session.
        Window("Bosun", id: MainWindowView.windowID) {
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

        Settings {
            AttentionSettingsView()
        }

        MenuBarExtra {
            MenuView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Keyboard focus moves between the list and the terminal only on request,
/// so each direction gets a View menu item, beside hiding the list.
struct FocusCommands: Commands {
    @FocusedBinding(\.sidebarFocused) private var sidebarFocused
    @FocusedBinding(\.terminalFocusRequest) private var terminalFocusRequest
    @FocusedBinding(\.sessionListVisibility) private var sessionListVisibility

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button(sessionListVisibility == .detailOnly ? "Show Session List" : "Hide Session List") {
                sessionListVisibility = sessionListVisibility == .detailOnly ? .all : .detailOnly
            }
            .shortcut(.toggleSessionList)
            .disabled(sessionListVisibility == nil)
            // A hidden list comes back to take the focus.
            Button("Focus Sidebar") {
                if sessionListVisibility == .detailOnly {
                    sessionListVisibility = .all
                } else {
                    sidebarFocused = true
                }
            }
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
    /// The key window's session list: shown, or hidden behind the terminal.
    @Entry var sessionListVisibility: Binding<NavigationSplitViewVisibility>?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()
        observeWhatIsInFront()
        Notifier.shared.start { [weak self] sessionID, windowID in
            NSApp.activate()
            self?.showMainWindow()
            DeckModel.shared.reveal(sessionID: sessionID, windowID: windowID)
        }
        DeckModel.shared.start()
    }

    /// Closing the window must not quit: the menu bar item keeps running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    /// SwiftUI names the Window scene's NSWindow after its id, and keeps it
    /// around once closed.
    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == MainWindowView.windowID }
    }

    /// The main window, back from the Dock, a notification or the menu bar;
    /// the Settings window and the cheat sheet stay as they are.
    func showMainWindow() {
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    /// The pane is in front of you while Bosun is active and some of the
    /// main window is on screen, a Settings window over it or not.
    private func observeWhatIsInFront() {
        let names = [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
            NSWindow.didChangeOcclusionStateNotification,
        ]
        for name in names {
            _ = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    let window = self?.mainWindow
                    DeckModel.shared.attention.inFront(
                        NSApp.isActive && window?.isVisible == true && window?.occlusionState.contains(.visible) == true
                    )
                }
            }
        }
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
