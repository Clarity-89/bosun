import AppKit
import SwiftUI

/// The footer notices both windows share: why status frames are not
/// flowing, if they are not, and the last error.
@MainActor
struct StatusNotices: View {
    let model: DeckModel

    var body: some View {
        switch model.statusFeedGap {
        case .eventsOff:
            Label("Live status events are off", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case .noPublisher:
            NotifyDaemonOffer(model: model)
        case nil:
            EmptyView()
        }
        if let error = model.lastError {
            // Two lines fit the footer; the hover shows one that does not.
            Text(error).foregroundStyle(.red).lineLimit(2).help(error)
        }
    }
}

/// Shown while nothing publishes session statuses: no agent-deck TUI is open
/// and no notify daemon runs, so rows change only on the 60 s list.
@MainActor
private struct NotifyDaemonOffer: View {
    let model: DeckModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Nothing publishes live status", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Button(model.isInstallingNotifyDaemon ? "Installing Notify Daemon…" : "Install Notify Daemon…", action: confirm)
                .buttonStyle(.link)
                .pointerStyle(.link)
                .disabled(model.isInstallingNotifyDaemon)
        }
    }

    /// NSAlert rather than a SwiftUI dialog: it presents the same from the
    /// menu bar panel as from the main window.
    private func confirm() {
        let alert = NSAlert()
        alert.messageText = "Install agent-deck's notify daemon?"
        alert.informativeText = """
            It runs in the background and publishes session statuses while no \
            agent-deck TUI is open. It is the same launch agent that \
            "agent-deck conductor setup" installs.

            It also repairs agent-deck's Claude hooks, keeps agent-deck updated when \
            [updates] in config.toml allows it, and sends desktop notifications if \
            [notifications] desktop is on.
            """
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            model.installNotifyDaemon()
        }
    }
}
