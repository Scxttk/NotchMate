import Combine
import Foundation

/// Whether the spectrum is currently taking over the whole screen.
///
/// A tiny shared object rather than a closure threaded down through
/// `NotchRootView` → `ExpandedView` → the carousel page: the request comes from
/// a tap deep inside the SwiftUI tree and is served by an AppKit window the
/// controller owns, so a published flag is the shortest honest path between the
/// two. `AppDelegate` observes it.
final class SpectrumFullscreen: ObservableObject {
    static let shared = SpectrumFullscreen()

    /// True from the moment the takeover is requested until the window has
    /// finished animating away.
    @Published private(set) var isPresented = false
    /// True while the run is shrinking back toward the panel: the window is
    /// still on screen, the wave is animating out. Kept separate from
    /// `isPresented` so the closing animation has somewhere to live.
    @Published private(set) var isCollapsing = false
    /// Whether this takeover is *guarding* the Mac rather than just being
    /// looked at: armed, anything that ends it locks the machine behind it
    /// (see `SpectrumGuard`). Set by the one way of leaving a Mac deliberately
    /// — the ⌥⌘S hotkey — and never by the tap on the spectrum page, which
    /// happens while you sit in front of it.
    ///
    /// Not `@Published`: it is read alongside `isPresented`, whose change is
    /// what anyone acting on this waits for anyway.
    private(set) var isArmed = false

    private init() {}

    func present(armed: Bool = false) {
        guard !isPresented else { return }
        isArmed = armed
        isCollapsing = false
        isPresented = true
    }

    /// Starts the reverse animation. The controller closes the window once it
    /// has played out.
    func dismiss() {
        guard isPresented, !isCollapsing else { return }
        isCollapsing = true
    }

    /// Called by the controller once the window is gone.
    func finishDismissal() {
        isPresented = false
        isCollapsing = false
        isArmed = false
    }

    func toggle(armed: Bool = false) {
        isPresented ? dismiss() : present(armed: armed)
    }
}
