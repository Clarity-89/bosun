import AppKit
import BosunCore
import SwiftUI

@main
struct BosunApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let model = DeckModel.shared

    var body: some Scene {
        WindowGroup("Bosun", id: "main") {
            MainWindowView(model: model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
            // ⌘⇧L / ⌘⇧E are unbound in Ghostty's defaults (⌘⇧T is `undo`),
            // so the surface lets them through to the menu bar.
            CommandMenu("View") {
                Button("Focus Sidebar") { model.focusSidebar() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Focus Terminal") { model.focusTerminal() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.pane == nil)
            }
        }

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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()
        installExitTrace()
        DeckModel.shared.start()
    }

    /// Bosun never calls exit itself, so any exit is a library deciding to
    /// end the process; the backtrace of the exiting thread names it.
    /// Written synchronously: os_log is asynchronous and loses messages
    /// sent this late.
    private func installExitTrace() {
        atexit {
            let symbols = Thread.callStackSymbols.joined(separator: "\n")
            let path = NSString("~/Library/Logs/Bosun-exit.log").expandingTildeInPath
            let line = "\(Date()) process exiting; caller:\n\(symbols)\n\n"
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.synchronize()
            } else {
                try? line.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
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
