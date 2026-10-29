import SwiftUI

/// What Bosun tells you, and where, about sessions that want you. Stored in
/// UserDefaults; every switch is on until you turn it off.
enum AttentionSettings {
    static let notify = "notify"
    static let notifyFinished = "notify.finished"
    static let notifyAsks = "notify.asks"
    static let notifyFailed = "notify.failed"
    static let sound = "notify.sound"
    static let menuBarCount = "badge.menuBar"

    /// Before anything reads them, so a key never set reads as on.
    static func register() {
        UserDefaults.standard.register(defaults: Dictionary(
            uniqueKeysWithValues: [notify, notifyFinished, notifyAsks, notifyFailed, sound, menuBarCount].map { ($0, true) }
        ))
    }

    static func isOn(_ key: String) -> Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    /// Whether this kind gets a notification at all.
    static func notifies(_ kind: AttentionKind) -> Bool {
        guard isOn(notify) else { return false }
        return switch kind {
        case .finished: isOn(notifyFinished)
        case .asks: isOn(notifyAsks)
        case .failed: isOn(notifyFailed)
        }
    }
}

/// The Settings window (⌘,).
struct AttentionSettingsView: View {
    @AppStorage(AttentionSettings.notify) private var notify = true
    @AppStorage(AttentionSettings.notifyFinished) private var finished = true
    @AppStorage(AttentionSettings.notifyAsks) private var asks = true
    @AppStorage(AttentionSettings.notifyFailed) private var failed = true
    @AppStorage(AttentionSettings.sound) private var sound = true
    @AppStorage(AttentionSettings.menuBarCount) private var menuBarCount = true
    @State private var systemDenies = false

    var body: some View {
        Form {
            Section {
                Toggle("Notify when a session wants you", isOn: $notify)
                Group {
                    Toggle("A turn finished", isOn: $finished)
                    Toggle("It asks for input", isOn: $asks)
                    Toggle("It failed", isOn: $failed)
                    Toggle("Play a sound", isOn: $sound)
                }
                .disabled(!notify)
                .padding(.leading, 16)
            } header: {
                Text("Notifications")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if systemDenies {
                        Text("macOS has Bosun's notifications turned off.")
                        Button("Open Notification Settings") { Notifier.shared.openSystemSettings() }
                    }
                    Text("Never for the session on screen while Bosun is in front.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Unread count") {
                Toggle("In the menu bar", isOn: $menuBarCount)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        // Read again on coming back, from System Settings say.
        .task { systemDenies = await Notifier.shared.isDenied() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { systemDenies = await Notifier.shared.isDenied() }
        }
    }
}
