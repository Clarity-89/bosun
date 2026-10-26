// Adapted from Calyx (https://github.com/yuuichieguchi/Calyx), commit 2dfb7a4,
// MIT License, Copyright (c) 2025 Yuuichi Eguchi. See Vendored/CALYX-LICENSE.

import AppKit
import GhosttyKit

enum GhosttyColorScheme {
    static func scheme(for appearance: NSAppearance) -> ghostty_color_scheme_e {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? GHOSTTY_COLOR_SCHEME_DARK
            : GHOSTTY_COLOR_SCHEME_LIGHT
    }
}

@MainActor
protocol GhosttyColorSchemeReceiving: AnyObject {
    func setColorScheme(_ scheme: ghostty_color_scheme_e)
}

enum GhosttyColorSchemeBroadcaster {
    @MainActor
    static func broadcast(
        _ scheme: ghostty_color_scheme_e,
        setAppScheme: (ghostty_color_scheme_e) -> Void,
        receivers: [any GhosttyColorSchemeReceiving]
    ) {
        setAppScheme(scheme)
        for receiver in receivers {
            receiver.setColorScheme(scheme)
        }
    }
}
