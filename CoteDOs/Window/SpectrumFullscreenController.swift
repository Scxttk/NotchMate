import AppKit
import Combine
import IOKit.pwr_mgt
import SwiftUI

/// The spectrum taking over the whole screen — for a room with music in it, or
/// as something to have on while reading instead of a Mac to stare at.
///
/// `SpectrumStageView` was already resolution-independent (that is what the
/// spectrum page and the pill are both built on), so this is window plumbing
/// plus the same grow/shrink morph one step up: the run starts at the geometry
/// the island's page just had and expands to fill the screen, and two fingers
/// up plays that backwards before the window closes.
///
/// The gesture is the whole point of the vocabulary: one vertical axis carries
/// the spectrum through all three of its sizes. Down opens the pill into the
/// island and the island into the screen; up walks it back.
final class SpectrumFullscreenController {
    private var window: NSWindow?
    private var keyMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []
    /// Held for as long as the takeover is up, so the display doesn't go dark
    /// under it — and the Mac doesn't walk on into its lock screen. This is
    /// what lets the takeover *replace* the display sleeping (see
    /// `SpectrumGuard`) instead of being wiped out by it. Released the moment
    /// the window goes away; nothing else in the app keeps the screen alive.
    private var displaySleepAssertion: IOPMAssertionID = 0

    private let spectrum: SpectrumAnalyzer
    private let nowPlaying: NowPlayingManager
    private let state = SpectrumFullscreen.shared

    /// How long the shrink-back is given before the window closes. Matches
    /// `NotchLayout.islandMorphAnimation`'s response with a little slack, so the
    /// wave has actually landed by the time the black goes away.
    private static let dismissDuration: TimeInterval = 0.45

    init(spectrum: SpectrumAnalyzer, nowPlaying: NowPlayingManager) {
        self.spectrum = spectrum
        self.nowPlaying = nowPlaying

        state.$isPresented
            .removeDuplicates()
            .sink { [weak self] presented in
                if presented { self?.show() } else { self?.close() }
            }
            .store(in: &cancellables)

        state.$isCollapsing
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in self?.scheduleClose() }
            .store(in: &cancellables)
    }

    private func show() {
        guard window == nil, let screen = NSScreen.main else { return }

        let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        // Above the menu bar and the notch panel itself: the takeover should
        // cover the Mac, not sit in it.
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.ignoresMouseEvents = false
        window.hasShadow = false

        let root = SpectrumFullscreenView(
            levels: spectrum.bands,
            spectrum: spectrum,
            nowPlaying: nowPlaying,
            state: state,
            screenSize: screen.frame.size
        )
        window.contentView = NSHostingView(rootView: root)
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        self.window = window

        // A local event monitor only sees events while this app is active, and a
        // menu-bar app is not key by default — so take focus for the duration of
        // the takeover, or the swipe back out would never reach us. The hotkey
        // works either way (Carbon, system-wide).
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        installKeyMonitor()
        holdDisplayAwake()
    }

    private func holdDisplayAwake() {
        guard displaySleepAssertion == 0 else { return }
        var assertion: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Côte d'OS Spektrum" as CFString,
            &assertion
        )
        if result == kIOReturnSuccess { displaySleepAssertion = assertion }
    }

    private func releaseDisplayAwake() {
        guard displaySleepAssertion != 0 else { return }
        IOPMAssertionRelease(displaySleepAssertion)
        displaySleepAssertion = 0
    }

    /// Escape closes the takeover — the key everyone already tries first for
    /// anything filling the screen. A local monitor is enough because `show()`
    /// activates the app and makes this window key.
    ///
    /// An *armed* takeover swallows every key instead, and turns each of them
    /// into the same dismissal. Not for tidiness: ⌘Q reached the app's menu and
    /// quit it, which took the takeover down without ever locking — a way past
    /// the guard that needed no password and left no trace. Anything the
    /// monitor's half-second poll would have caught, this catches at once.
    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard !state.isArmed else {
                state.dismiss()
                return nil
            }
            guard event.keyCode == 53 else { return event }   // Esc
            state.dismiss()
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// The view is already animating the wave back down; give it that long
    /// before the window disappears.
    private func scheduleClose() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dismissDuration) { [weak self] in
            self?.state.finishDismissal()
        }
    }

    private func close() {
        removeKeyMonitor()
        releaseDisplayAwake()
        window?.orderOut(nil)
        window = nil
    }
}

/// The fullscreen content: black, and the wave.
private struct SpectrumFullscreenView: View {
    @ObservedObject var levels: SpectrumBands
    @ObservedObject var spectrum: SpectrumAnalyzer
    @ObservedObject var nowPlaying: NowPlayingManager
    @ObservedObject var state: SpectrumFullscreen
    /// Icon and accent of whichever app is making the sound — the same answer
    /// the island's wave uses, so the third leg of the morph doesn't change
    /// colour on the way out to the screen.
    @ObservedObject private var sourceApp = SourceAppAccent.shared
    /// The screen this is filling, for working out how far the wave has to grow.
    let screenSize: CGSize

    /// Fades the black in with the wave rather than slamming it on.
    @State private var shown = false
    /// Whether the run has finished travelling out of the island's page. Flipped
    /// a tick after appearing, for the same reason the island's own morph is
    /// driven from the view model: a state change during installation does not
    /// animate.
    @State private var landed = false

    var body: some View {
        let tints = WaveTints.resolve(
            nowPlaying: nowPlaying, sourceBundleID: spectrum.sourceBundleID, sourceAppTint: sourceApp.tint)
        return ZStack {
            Color.black
            SpectrumStageView(
                levels: levels,
                isLive: spectrum.isLive,
                isActive: nowPlaying.screensAwake,
                tint: tints.primary,
                coverBars: tints.coverBars,
                // Out of the island's page on the way in, home to the pill on
                // the way out. Not symmetric on purpose: Escape collapses the
                // island as it dismisses, so aiming the run back at the page
                // would land it on something that is itself disappearing —
                // which is exactly what the old swipe-out did, and why it read
                // as broken. The pill is where the wave actually ends up, so
                // that is what it should fly to.
                morphOrigin: state.isCollapsing
                    ? WaveMorphOrigin(
                        scale: NotchLayout.pillToFullscreenWaveScale(screenSize: screenSize),
                        offsetY: NotchLayout.pillToFullscreenWaveOffset(screenSize: screenSize)
                    )
                    : WaveMorphOrigin(
                        scale: NotchLayout.pageToFullscreenWaveScale(screenSize: screenSize),
                        offsetY: NotchLayout.pageToFullscreenWaveOffset(screenSize: screenSize)
                    ),
                // Same run the island is showing, so the third leg of the morph
                // is the same wave again rather than a differently-resolved one.
                // Only while there *is* such a run to continue: without the
                // spectrum-only pill the chain does not exist, and forcing its
                // bar count here would size the fullscreen wave from a setting
                // nothing on screen is using.
                fixedBarCount: UserSettings.shared.pillSpectrumOnly
                    ? NotchLayout.pillSpectrumGeometry(
                        forWidth: UserSettings.shared.pillSpectrumWidth).barCount
                    : nil,
                landed: landed && !state.isCollapsing,
                // Not the island's spring: this leg crosses the whole screen.
                morphAnimation: NotchLayout.spectrumFullscreenMorphAnimation
            )
            .padding(NotchLayout.stageInset * 2)
        }
        .opacity(shown && !state.isCollapsing ? 1 : 0)
        .animation(.easeInOut(duration: 0.28), value: shown)
        .animation(.easeInOut(duration: 0.28), value: state.isCollapsing)
        .ignoresSafeArea()
        .onAppear {
            shown = true
            DispatchQueue.main.async {
                withAnimation(NotchLayout.islandMorphAnimation) { landed = true }
            }
        }
    }
}
