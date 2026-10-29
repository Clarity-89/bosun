// Action handling follows Calyx's GhosttyActionRouter (MIT, see
// Vendored/CALYX-LICENSE), reduced to what a single embedded pane needs.

@preconcurrency import AppKit
import GhosttyKit

/// Routes libghostty actions to the surface they target. The return value
/// is a contract: `false` means "not performed", which lets a `performable:`
/// keybind fall through to the shell, so only actions Bosun truly ignores
/// on purpose return `true`.
@MainActor
enum GhosttyActionRouter {
    static func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            guard let view = surfaceView(from: target), let ptr = action.action.set_title.title else { return false }
            view.applyTitle(String(cString: ptr))
            return true

        case GHOSTTY_ACTION_PWD:
            guard let view = surfaceView(from: target), let ptr = action.action.pwd.pwd else { return false }
            view.applyPwd(String(cString: ptr))
            return true

        case GHOSTTY_ACTION_CELL_SIZE:
            guard let view = surfaceView(from: target) else { return false }
            let value = action.action.cell_size
            let size = NSSize(width: CGFloat(value.width), height: CGFloat(value.height))
            // Fires synchronously inside ghostty_surface_new, when the
            // controller does not exist yet; the view keeps the value.
            view.cachedCellSize = size
            view.surfaceController?.cellSize = size
            return true

        case GHOSTTY_ACTION_INITIAL_SIZE:
            guard let view = surfaceView(from: target) else { return false }
            let value = action.action.initial_size
            view.initialSize = NSSize(width: CGFloat(value.width), height: CGFloat(value.height))
            return true

        case GHOSTTY_ACTION_SCROLLBAR:
            guard let view = surfaceView(from: target) else { return false }
            let value = action.action.scrollbar
            let state = GhosttySurfaceController.ScrollbarState(total: value.total, offset: value.offset, len: value.len)
            view.surfaceController?.scrollbar = state
            view.scrollbarUpdateHandler?(state)
            return true

        case GHOSTTY_ACTION_RENDER:
            guard let view = surfaceView(from: target) else { return false }
            view.needsDisplay = true
            return true

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            guard let view = surfaceView(from: target) else { return false }
            view.updateCursorShape(action.action.mouse_shape)
            return true

        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            NSCursor.setHiddenUntilMouseMoves(action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN)
            return true

        case GHOSTTY_ACTION_RENDERER_HEALTH:
            guard let view = surfaceView(from: target) else { return false }
            view.isRendererHealthy = action.action.renderer_health == GHOSTTY_RENDERER_HEALTH_HEALTHY
            return true

        case GHOSTTY_ACTION_SECURE_INPUT:
            return handleSecureInput(target: target, mode: action.action.secure_input)

        case GHOSTTY_ACTION_OPEN_URL:
            return handleOpenURL(action.action.open_url)

        case GHOSTTY_ACTION_RING_BELL:
            NSSound.beep()
            return true

        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            // A surface created with a command has `wait-after-command` forced
            // on (apprt/embedded.zig), so the engine would sit on "Process
            // exited", or on its abnormal-exit notice, until a keypress. Bosun
            // ends the pane itself either way; the host hears which exit it was.
            guard let view = surfaceView(from: target) else { return false }
            let exited = action.action.child_exited
            let abnormal = UInt64(exited.timetime_ms) <= GhosttyAppController.shared.abnormalExitRuntimeMs
            view.onProcessExit?(abnormal ? .abnormal : .normal)
            return true

        case GHOSTTY_ACTION_CLOSE_TAB, GHOSTTY_ACTION_CLOSE_WINDOW:
            // Keybind-driven closes; the pane is a tmux client, which ends
            // with a tmux detach or with its session. Not performed.
            return false

        case GHOSTTY_ACTION_QUIT:
            // libghostty asking to quit must never quit Bosun; consumed on purpose.
            return true

        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            // agent-deck owns notifications through its status bus.
            return true

        case GHOSTTY_ACTION_CONFIG_CHANGE, GHOSTTY_ACTION_COLOR_CHANGE, GHOSTTY_ACTION_SIZE_LIMIT,
             GHOSTTY_ACTION_MOUSE_OVER_LINK, GHOSTTY_ACTION_PROGRESS_REPORT, GHOSTTY_ACTION_COMMAND_FINISHED:
            // Informational; nothing to perform yet.
            return true

        default:
            return false
        }
    }

    private static func handleSecureInput(target: ghostty_target_s, mode: ghostty_action_secure_input_e) -> Bool {
        switch target.tag {
        case GHOSTTY_TARGET_APP:
            switch mode {
            case GHOSTTY_SECURE_INPUT_ON: SecureInput.shared.global = true
            case GHOSTTY_SECURE_INPUT_OFF: SecureInput.shared.global = false
            case GHOSTTY_SECURE_INPUT_TOGGLE: SecureInput.shared.global.toggle()
            default: return false
            }
            return true
        case GHOSTTY_TARGET_SURFACE:
            guard let view = surfaceView(from: target) else { return false }
            switch mode {
            case GHOSTTY_SECURE_INPUT_ON: view.passwordInput = true
            case GHOSTTY_SECURE_INPUT_OFF: view.passwordInput = false
            case GHOSTTY_SECURE_INPUT_TOGGLE: view.passwordInput.toggle()
            default: return false
            }
            return true
        default:
            return false
        }
    }

    private static func handleOpenURL(_ value: ghostty_action_open_url_s) -> Bool {
        guard let urlCStr = value.url else { return false }
        let data = Data(bytes: urlCStr, count: Int(value.len))
        guard let urlString = String(data: data, encoding: .utf8) else { return false }
        let url: URL
        if let candidate = URL(string: urlString), candidate.scheme != nil {
            url = candidate
        } else {
            url = URL(fileURLWithPath: urlString)
        }
        NSWorkspace.shared.open(url)
        return true
    }

    private static func surfaceView(from target: ghostty_target_s) -> SurfaceView? {
        guard target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface else { return nil }
        return GhosttyAppController.surfaceView(from: surface)
    }
}
