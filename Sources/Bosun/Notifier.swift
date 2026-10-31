import AppKit
import os
import UserNotifications

private let notifierLog = Logger(subsystem: "com.bosun.Bosun", category: "Notifier")

/// macOS notifications for what wants you. Clicking one shows its session.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Shows a session, in the window of the pane that wants you.
    private var onOpen: ((_ sessionID: String, _ windowID: String?) -> Void)?

    /// Nil outside an app bundle, the bare `swift run` binary say, where the center traps.
    private lazy var center: UNUserNotificationCenter? = {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        return center
    }()

    /// Before launch ends, so a click that launched Bosun still arrives.
    func start(onOpen: @escaping (_ sessionID: String, _ windowID: String?) -> Void) {
        self.onOpen = onOpen
        _ = center
    }

    /// One per thing that wants you: a new one for the same thing replaces
    /// it. The first asks for permission; the answer is read each time, as
    /// it can change in System Settings while Bosun runs.
    func post(id: String, title: String, subtitle: String?, body: String, sessionID: String, windowID: String?, sound: NotificationSound) {
        guard let center else { return }
        Task {
            switch await center.notificationSettings().authorizationStatus {
            case .authorized, .provisional:
                break
            case .notDetermined:
                do {
                    guard try await center.requestAuthorization(options: [.alert, .sound]) else { return }
                } catch {
                    // What a refusal throws, too.
                    notifierLog.info("notifications not allowed: \(error.localizedDescription, privacy: .public)")
                    return
                }
            default:
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            if let subtitle { content.subtitle = subtitle }
            content.body = body
            content.threadIdentifier = sessionID
            content.userInfo = ["session": sessionID, "window": windowID ?? ""]
            switch sound {
            case .none: break
            case .system: content.sound = .default
            case .named(let name): NotificationSound.play(name)
            }
            do {
                try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            } catch {
                notifierLog.error("notification failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// What you have seen leaves Notification Center too.
    func remove(ids: [String]) {
        guard let center, !ids.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    /// macOS has Bosun's notifications turned off, in System Settings or
    /// by a refusal of the first request.
    func isDenied() async -> Bool {
        await center?.notificationSettings().authorizationStatus == .denied
    }

    func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let sessionID = info["session"] as? String else { return }
        let windowID = (info["window"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        await MainActor.run { onOpen?(sessionID, windowID) }
    }

    /// Shown with Bosun in front too: Bosun leaves out the session on screen
    /// before posting.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
