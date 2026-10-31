import AppKit
import SwiftUI

/// What Bosun tells you, and where, about sessions that want you. Stored in
/// UserDefaults; every switch is on until you turn it off.
enum AttentionSettings {
    static let notify = "notify"
    static let notifyFinished = "notify.finished"
    static let notifyAsks = "notify.asks"
    static let notifyFailed = "notify.failed"
    static let sound = "notify.sound"
    /// A sound's name, `Glass`; empty for macOS's own notification sound.
    static let soundName = "notify.soundName"
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

    /// What a notification sounds like, as set.
    static var notificationSound: NotificationSound {
        guard isOn(sound) else { return .none }
        let name = UserDefaults.standard.string(forKey: soundName) ?? ""
        return name.isEmpty ? .system : .named(name)
    }
}

/// What a notification sounds like.
enum NotificationSound: Equatable {
    case none
    /// macOS's notification sound, which Notification Center plays and
    /// Focus silences.
    case system
    /// A sound from the Sound settings' set or `~/Library/Sounds`, by name.
    /// Bosun plays it itself as the notification shows: Notification
    /// Center finds a file of its own only in the app's bundle or its
    /// container, and remembers a name it failed to find.
    case named(String)

    /// The sounds to choose from: macOS's, then any you added, by name.
    static var available: [String] {
        let directories = ["/System/Library/Sounds", NSHomeDirectory() + "/Library/Sounds"]
        var seen: Set<String> = []
        return directories.flatMap { directory in
            ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
                .filter { !$0.hasPrefix(".") }
                .map { ($0 as NSString).deletingPathExtension }
                .sorted()
                .filter { seen.insert($0).inserted }
        }
    }

    static func play(_ name: String) {
        NSSound(named: name)?.play()
    }
}

/// The Settings window (⌘,).
struct AttentionSettingsView: View {
    @AppStorage(AttentionSettings.notify) private var notify = true
    @AppStorage(AttentionSettings.notifyFinished) private var finished = true
    @AppStorage(AttentionSettings.notifyAsks) private var asks = true
    @AppStorage(AttentionSettings.notifyFailed) private var failed = true
    @AppStorage(AttentionSettings.sound) private var sound = true
    @AppStorage(AttentionSettings.soundName) private var soundName = ""
    @AppStorage(AttentionSettings.menuBarCount) private var menuBarCount = true
    @State private var systemDenies = false
    /// Read once as the window opens; the set changes with a macOS update.
    private let sounds = NotificationSound.available

    var body: some View {
        Form {
            Section {
                Toggle("Notify when a session wants you", isOn: $notify)
                Group {
                    Toggle("A turn finished", isOn: $finished)
                    Toggle("It asks for input", isOn: $asks)
                    Toggle("It failed", isOn: $failed)
                    Toggle("Play a sound", isOn: $sound)
                    Picker("Sound", selection: $soundName) {
                        Text("Default").tag("")
                        Divider()
                        ForEach(sounds, id: \.self) { Text($0).tag($0) }
                    }
                    .disabled(!sound)
                    // Heard as picked, as the Sound settings do it.
                    .onChange(of: soundName) { _, name in
                        if !name.isEmpty { NotificationSound.play(name) }
                    }
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
