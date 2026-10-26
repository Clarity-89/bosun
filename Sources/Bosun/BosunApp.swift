import AppKit
import BosunCore
import SwiftUI

@main
struct BosunApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = DeckModel.shared

    var body: some Scene {
        // The first WindowGroup opens at launch, so the session list is
        // visible even when the menu bar hides the status item.
        WindowGroup("Bosun", id: "sessions") {
            MenuView(model: model)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
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
        NSApp.setActivationPolicy(.accessory)
        installSignalHandlers()
        DeckModel.shared.start()
        // LaunchServices does not activate LSUIElement apps, and macOS 14+
        // activation is cooperative: this brings the window forward when no
        // other app is in use and is refused otherwise. Reopening the app
        // (`open -a Bosun`, or clicking it in Finder) always works.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            NSApp.activate()
            for window in NSApp.windows where window.canBecomeKey {
                window.makeKeyAndOrderFront(nil)
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
