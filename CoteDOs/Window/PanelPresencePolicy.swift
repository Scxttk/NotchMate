import Foundation

/// Single source of truth for the panel's visibility and interactivity.
///
/// `panel.alphaValue` and `panel.ignoresMouseEvents` are derived here and
/// assigned nowhere else. Writing them ad hoc from each feature that has a reason
/// to hide or mute the panel — menu-bar overlap, click-through gating, the
/// capture hotkey — means every new reason multiplies the ways those writes stomp
/// each other, and one feature's restore path blindly undoes another's hide.
/// Reasons live here as sets instead.
///
/// - A *hide* reason makes the panel fully invisible **and** click-through;
///   whenever any hide reason is present, `ignoresMouseEvents` is
///   unconditionally true — there is no cursor-rect exception, which is what
///   makes an invisible panel unable to steal clicks or focus.
/// - A *passive* reason keeps the panel visible but click-through (the pill
///   shows content yet never intercepts the app beneath it).
/// - With neither, interactivity follows the cursor: the panel accepts events
///   only while the cursor is inside the interactive island rect.
struct PanelPresencePolicy: Equatable {
    /// Reasons the panel must be invisible (alpha 0) and click-through.
    enum HideReason: Hashable {
        /// The frontmost app's menu bar reaches into the pill's area.
        case menuBarOverlap
        /// Nothing to show: no audio hero, no timer, no activity, no drag —
        /// and the cursor isn't near the notch.
        case idle
        /// The user paused the notch (⌥⌘N or the status menu) to reach
        /// whatever sits underneath it — previously that took quitting the app.
        /// Session-only by design: a fresh launch always starts enabled.
        case userDisabled
    }

    /// Reasons the panel stays visible but must not intercept mouse events.
    enum PassiveReason: Hashable {
        /// Safari is fullscreen on this screen; the pill is dodged beside the
        /// URL bar and must never fight the toolbar for clicks.
        case safariFullscreen
    }

    var hideReasons: Set<HideReason> = []
    var passiveReasons: Set<PassiveReason> = []

    var isHidden: Bool { !hideReasons.isEmpty }

    /// Resolve `panel.ignoresMouseEvents`.
    ///
    /// - `cursorInsideInteractiveRect`: whether the cursor is currently within
    ///   the interactive island footprint (the normal click-through gate).
    /// - `hotkeyOverride`: the capture hotkey opened the island without the
    ///   cursor being anywhere near it — the field must be interactive
    ///   regardless of the cursor, and a passive (dodged) pill temporarily
    ///   becomes interactive for it. A *hidden* panel stays click-through even
    ///   then; callers clear their hide reason before presenting.
    func ignoresMouseEvents(cursorInsideInteractiveRect: Bool, hotkeyOverride: Bool) -> Bool {
        if isHidden { return true }
        if hotkeyOverride { return false }
        if !passiveReasons.isEmpty { return true }
        return !cursorInsideInteractiveRect
    }
}
