import Carbon.HIToolbox
import Foundation

/// Mirrors the API the vendored SurfaceView expects. Secure event input is
/// enabled while any focused surface is on a password prompt, or globally.
@MainActor
final class SecureInput {
    static let shared = SecureInput()

    var global = false { didSet { apply() } }

    private var scoped: [ObjectIdentifier: Bool] = [:]
    private var enabled = false

    func setScoped(_ object: ObjectIdentifier, focused: Bool) {
        scoped[object] = focused
        apply()
    }

    func removeScoped(_ object: ObjectIdentifier) {
        scoped.removeValue(forKey: object)
        apply()
    }

    private func apply() {
        let wanted = global || scoped.values.contains(true)
        guard wanted != enabled else { return }
        enabled = wanted
        if wanted { EnableSecureEventInput() } else { DisableSecureEventInput() }
    }
}

extension Notification.Name {
    /// Observed by the vendored SurfaceView; Bosun has no setting yet, so it never fires.
    static let smoothScrollSettingChanged = Notification.Name("com.bosun.smoothScrollSettingChanged")
}
