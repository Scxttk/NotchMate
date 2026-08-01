import AppKit
import Combine
import SwiftUI

final class NotchWindowController {
    private let panel: NotchPanel
    private let viewModel: NotchViewModel
    private let nowPlaying: NowPlayingManager
    private let shelf: FileShelfModel
    private let activities: ActivityManager
    private let pomodoro: PomodoroManager
    private let spectrum: SpectrumAnalyzer
    private let container: NotchContainerView

    private var collapseWorkItem: DispatchWorkItem?
    /// Pending "advance to the next stage" step of the staged expand/collapse
    /// walk, so a direction change mid-walk can cancel it and reverse.
    private var stageWorkItem: DispatchWorkItem?
    /// Pending "the island has rested, mount the pages" step after the final
    /// expand hop (see `NotchLayout.pagesSettleDelay`). Cancelled whenever a
    /// new walk starts; the view model clears the flag itself on any step
    /// away from `.expanded`.
    private var pagesWorkItem: DispatchWorkItem?
    /// Where the staged walk is currently heading (`.expanded` or `.collapsed`),
    /// or nil when the island is at rest. Guards against hover events restarting
    /// a walk that's already going the right way.
    private var stagingTarget: NotchViewModel.IslandState?
    private var scrollMonitor: Any?
    private var scrollMonitorGlobal: Any?
    private var hoverMonitorGlobal: Any?
    private var hoverMonitorLocal: Any?
    private let menuBarOverlapMonitor = MenuBarOverlapMonitor()
    private let safariFullscreenMonitor = SafariFullscreenMonitor()
    /// Last reported Safari-fullscreen state; applied (or ignored, when it
    /// concerns another display) by `applySafariDodge`.
    private var safariDodge: SafariFullscreenMonitor.DodgeState?
    /// Horizontal offset of the whole *panel* off screen centre while dodging
    /// Safari's URL bar. Additive to and independent of the SwiftUI island's
    /// own hero-centring shift; every screen-rect helper must include it.
    private var panelXOffset: CGFloat = 0
    /// Downward offset of the panel while dodged: the pill drops from the top
    /// edge to sit vertically centred on Safari's URL field, nestling beside
    /// the toolbar rather than floating above it. Zero when not dodging.
    private var panelYOffset: CGFloat = 0
    /// All reasons the panel is currently hidden or passive. `panel.alphaValue`
    /// and `panel.ignoresMouseEvents` are derived from this via
    /// `applyPresence`/`updateClickThrough` — never written directly, so no
    /// feature's restore path can stomp another's hide.
    private var policy = PanelPresencePolicy()
    /// True while the frontmost app's menu bar overlaps the notch pill — the
    /// panel is hidden and non-interactive for the duration (see
    /// `setMenuBarOverlap`).
    private var menuBarOverlapActive: Bool { policy.hideReasons.contains(.menuBarOverlap) }
    /// True while the user has paused the notch (⌥⌘N / status menu) — hidden,
    /// click-through, and every wake path (hover, gesture, drag, capture
    /// hotkey) is inert until it is lifted again. See `setUserDisabled`.
    var isUserDisabled: Bool { policy.hideReasons.contains(.userDisabled) }
    /// True while the capture hotkey holds the island open: the panel must be
    /// interactive regardless of where the cursor is (see
    /// `PanelPresencePolicy.ignoresMouseEvents`). Cleared on any collapse.
    private var captureHotkeyActive = false
    /// Subscriptions that drive `refreshIdlePresence`: the pill's contents are
    /// published state the controller otherwise only reads lazily inside event
    /// handlers, but hiding on idle needs a push the moment music stops or a
    /// timer ends — the cursor may not move for minutes.
    private var cancellables: Set<AnyCancellable> = []

    /// When the user closes the notch with a swipe-up, suppress hover-expand
    /// until the cursor has left the island once.
    private var suppressHover = false

    /// The screen the panel is currently positioned on, so we only move it when
    /// the cursor actually crosses to a different display.
    private weak var currentScreen: NSScreen?

    /// Last cursor position we actually evaluated hover for. `mouseMoved` fires
    /// far more often than the cursor meaningfully moves; skipping sub-pixel
    /// deltas keeps the monitor cheap.
    private var lastEvaluatedCursor: NSPoint?

    /// Timestamp of the last horizontal scroll event, so one swipe pages one tab
    /// (trackpad momentum keeps firing events; we only act on a fresh gesture).
    private var lastHorizontalScroll = Date.distantPast

    init(viewModel: NotchViewModel, nowPlaying: NowPlayingManager, shelf: FileShelfModel, activities: ActivityManager, pomodoro: PomodoroManager, capture: ObsidianCapture, spectrum: SpectrumAnalyzer) {
        self.viewModel = viewModel
        self.nowPlaying = nowPlaying
        self.shelf = shelf
        self.activities = activities
        self.pomodoro = pomodoro
        self.spectrum = spectrum

        let frame = NSRect(x: 0, y: 0, width: viewModel.panelWidth, height: viewModel.panelHeight)
        panel = NotchPanel(contentRect: frame)

        let root = NotchRootView(viewModel: viewModel, nowPlaying: nowPlaying, shelf: shelf, activities: activities, pomodoro: pomodoro, capture: capture, spectrum: spectrum)
        let hostingView = NSHostingView(rootView: root)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        container = NotchContainerView(frame: frame)
        container.islandRect = { [weak self, weak container] in
            guard let self, let container else { return .zero }
            let (width, height) = self.currentIslandSize()
            let bounds = container.bounds
            // The island floats `islandTopGap` below the container's top edge.
            return NSRect(
                x: (bounds.width - width) / 2 + self.currentIslandXShift(),
                y: bounds.height - NotchLayout.islandTopGap - height,
                width: width,
                height: height
            )
        }
        container.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        panel.contentView = container

        container.onDragEntered = { [weak self] in self?.handleDragEntered() }
        container.onDragExited = { [weak self] in self?.handleDragExited() }
        container.onDrop = { [weak self] urls in self?.handleDrop(urls) }

        installScrollMonitor()
        installHoverMonitor()

        menuBarOverlapMonitor.notchLeftEdgeProvider = { [weak self] in self?.islandScreenRect(expanded: false)?.minX }
        menuBarOverlapMonitor.onChange = { [weak self] overlapping in self?.setMenuBarOverlap(overlapping) }
        menuBarOverlapMonitor.start()

        // No explicit precedence between the two monitors is needed: a dodged
        // pill sits far right of the menu-bar items, and the overlap monitor
        // reads the pill's real (shifted) left edge via the provider above, so
        // it reports no overlap while the dodge is active.
        safariFullscreenMonitor.onChange = { [weak self] state in
            self?.safariDodge = state
            self?.applySafariDodge()
        }
        safariFullscreenMonitor.start()

        #if DEBUG
        // Remote control for looking at the real thing: drives the *staged* hover
        // walk without a cursor, which the capture hotkey can't stand in for
        // because it skips the stages on purpose. `offset:<pt>` drops the island
        // below the top edge so a shot has headroom above it; `offset:0` restores
        // reality (the next Safari-dodge change overwrites it either way).
        //
        //   osascript -l JavaScript -e 'ObjC.import("Foundation");
        //     $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately(
        //       "com.scott.ledge.debug.island", "expand", $(), true)'
        //
        // DEBUG-only, and it has to stay that way: a DistributedNotificationCenter
        // observer is reachable by *any* process on the machine, so in a shipping
        // build this is an unauthenticated control surface over the UI. It only
        // opens a notch and nudges a panel, which is why it went unnoticed while
        // it was in Release.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.scott.ledge.debug.island"), object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            if let command = note.object as? String, command.hasPrefix("offset:"),
               let value = Double(command.dropFirst("offset:".count)) {
                self.panelYOffset = CGFloat(value)
                if let screen = self.currentScreen {
                    self.panel.setFrame(self.panelFrame(on: screen), display: true)
                }
                return
            }
            self.suppressHover = false
            self.collapseWorkItem?.cancel()
            if note.object as? String == "expand" {
                // Driving the walk without a cursor: an idle-hidden panel has to
                // un-hide first or it animates at alpha 0.
                self.policy.hideReasons.remove(.idle)
                self.applyPresence(animated: false)
            }
            self.setExpanded(note.object as? String == "expand")
        }
        #endif

        // Idle-hide reactivity: whatever can change the pill's contents (or
        // land the island back at rest) re-evaluates the idle presence. The
        // async main hop matters — @Published emits on willSet, so evaluating
        // synchronously would read the *old* property values.
        let contentChanged: [AnyPublisher<Void, Never>] = [
            nowPlaying.$isPlaying.map { _ in }.eraseToAnyPublisher(),
            spectrum.$hasSignal.map { _ in }.eraseToAnyPublisher(),
            pomodoro.$pillText.map { _ in }.eraseToAnyPublisher(),
            activities.$current.map { _ in }.eraseToAnyPublisher(),
            shelf.$isDropTargeted.map { _ in }.eraseToAnyPublisher(),
            viewModel.$islandState.map { _ in }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(contentChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refreshIdlePresence() }
            .store(in: &cancellables)

        // Settings changes can move the pill width (spectrum-only mode,
        // wave width), which shifts the dodge anchor — re-derive it live
        // (a no-op while not dodging).
        UserSettings.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.applySafariDodge() }
            .store(in: &cancellables)

        // Escape out of the fullscreen takeover goes all the way home to the
        // pill, not back to the island page it was opened from. The wave is
        // already flying to the pill's pose (see
        // `SpectrumFullscreenController`), so the island has to be collapsing
        // underneath it or the run would land on a page still standing open.
        // Via `collapseViaGesture`, so the cursor sitting over the island
        // doesn't immediately hover it back open.
        SpectrumFullscreen.shared.$isCollapsing
            .removeDuplicates()
            .filter { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.collapseViaGesture() }
            .store(in: &cancellables)
    }

    // MARK: - Idle presence

    /// Whether the collapsed pill has anything to show. Deliberately *not*
    /// including a non-empty shelf: files alone don't keep the pill on screen
    /// (they stay reachable via the proximity reveal); the badge shows
    /// whenever audio or a timer makes the pill visible anyway. Live
    /// activities count — an AirPods route pill can fire while otherwise idle.
    private var hasCollapsedContent: Bool {
        hasAudioHero || pomodoro.pillText != nil || activities.current != nil
    }

    /// Idle = fully invisible: with nothing to show and the cursor away, the
    /// pill hides entirely. Proximity (the *expanded* island footprint) is the
    /// first of two stages: entering it merely reveals the collapsed pill;
    /// expanding still requires hovering the pill itself or the swipe gesture,
    /// exactly as with a content-bearing pill.
    private func refreshIdlePresence(animated: Bool = true) {
        let cursorNearby = islandScreenRect(expanded: true)?.contains(NSEvent.mouseLocation) ?? false
        let idle = viewModel.islandState == .collapsed
            && stagingTarget == nil
            && !hasCollapsedContent
            && !shelf.isDropTargeted
            && !cursorNearby
        if idle {
            policy.hideReasons.insert(.idle)
        } else {
            policy.hideReasons.remove(.idle)
        }
        applyPresence(animated: animated)
    }

    deinit {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
        }
        if let scrollMonitorGlobal {
            NSEvent.removeMonitor(scrollMonitorGlobal)
        }
        if let hoverMonitorGlobal {
            NSEvent.removeMonitor(hoverMonitorGlobal)
        }
        if let hoverMonitorLocal {
            NSEvent.removeMonitor(hoverMonitorLocal)
        }
        menuBarOverlapMonitor.stop()
        safariFullscreenMonitor.stop()
    }

    func show() {
        reposition()
        panel.orderFrontRegardless()
        // Idle at launch means hidden from the very first frame.
        refreshIdlePresence(animated: false)
    }

    /// Push the policy's verdict onto the panel: alpha (fading when animated)
    /// plus the click-through gate. The only place `panel.alphaValue` is set.
    private func applyPresence(animated: Bool) {
        let targetAlpha: CGFloat = policy.isHidden ? 0 : 1
        if panel.alphaValue != targetAlpha {
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = NotchLayout.idleHideFadeDuration
                    panel.animator().alphaValue = targetAlpha
                }
            } else {
                panel.alphaValue = targetAlpha
            }
        }
        updateClickThrough()
    }

    // MARK: - Sleep/Wake lifecycle

    /// Tear down the live event monitors before the system sleeps so no stale
    /// global monitors fire during/after sleep. Paired with `resumeMonitors()`.
    func suspendMonitors() {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
        if let scrollMonitorGlobal {
            NSEvent.removeMonitor(scrollMonitorGlobal)
            self.scrollMonitorGlobal = nil
        }
        if let hoverMonitorGlobal {
            NSEvent.removeMonitor(hoverMonitorGlobal)
            self.hoverMonitorGlobal = nil
        }
        if let hoverMonitorLocal {
            NSEvent.removeMonitor(hoverMonitorLocal)
            self.hoverMonitorLocal = nil
        }
        menuBarOverlapMonitor.stop()
        safariFullscreenMonitor.stop()
        collapseWorkItem?.cancel()
        // Don't strand the island mid-walk over a sleep: finish the remaining
        // stages immediately (no animation — the screen is going dark anyway).
        stageWorkItem?.cancel()
        stageWorkItem = nil
        stagingTarget = nil
        switch viewModel.islandState {
        case .band, .solo, .condensing:
            viewModel.islandState = .collapsed
            captureHotkeyActive = false
        case .expanded, .collapsed:
            break
        }
    }

    /// Re-install the monitors on wake and snap the panel back to the correct
    /// screen (display topology can change while asleep).
    func resumeMonitors() {
        guard scrollMonitor == nil, scrollMonitorGlobal == nil, hoverMonitorGlobal == nil, hoverMonitorLocal == nil else { return }
        installScrollMonitor()
        installHoverMonitor()
        menuBarOverlapMonitor.start()
        safariFullscreenMonitor.start()
        reposition()
        // Waking with the music long stopped: hide right away, don't wait for
        // the first mouse move.
        refreshIdlePresence(animated: false)
    }

    // MARK: - Quick Capture

    /// Open the island on the capture tab and focus its text field. Driven by
    /// the global hotkey. The panel is non-activating, so we make it key
    /// explicitly so keystrokes reach the field.
    func presentCapture() {
        // Paused means paused: the capture hotkey must not reopen an island
        // the user explicitly put away (and a hidden panel could not take
        // keystrokes anyway — `ignoresMouseEvents` stays true while hidden).
        guard !isUserDisabled else { return }
        suppressHover = false
        collapseWorkItem?.cancel()
        // Hotkey from anywhere, including the idle-hidden state: un-hide first
        // or the island would open at alpha 0.
        policy.hideReasons.remove(.idle)
        // Dodged beside Safari's URL bar: snap back to centre for typing; the
        // collapse landing re-applies the dodge (see `advanceStaging`).
        if panelXOffset != 0 || panelYOffset != 0, let screen = currentScreen {
            panelXOffset = 0
            panelYOffset = 0
            panel.setFrame(panelFrame(on: screen), display: true)
        }
        viewModel.selectedTab = .capture
        // Open directly (not through the staged reveal) so the field is ready
        // to type into immediately.
        setExpanded(true, staged: false)
        // Hotkey-driven, not cursor-driven: force interactive regardless of
        // where the cursor happens to be, or the field could be unclickable
        // until the mouse moves over it.
        captureHotkeyActive = true
        applyPresence(animated: false)
        panel.makeKeyAndOrderFront(nil)
        viewModel.requestCaptureFocus()
    }

    func reposition() {
        guard let screen = ScreenManager.targetScreen() else { return }
        currentScreen = screen
        panel.setFrame(panelFrame(on: screen), display: true)
        // The screen may have changed under a dodge (cursor crossed displays,
        // topology changed) — re-derive whether the dodge still applies here.
        applySafariDodge()
    }

    private func panelFrame(on screen: NSScreen) -> NSRect {
        let width = viewModel.panelWidth
        let height = viewModel.panelHeight
        return NSRect(
            x: screen.frame.midX - width / 2 + panelXOffset,
            y: screen.frame.maxY - height - panelYOffset,
            width: width,
            height: height
        )
    }

    // MARK: - Safari fullscreen dodge

    /// True while the pill is dodged beside Safari's URL bar (visible but
    /// click-through; hover and gestures suppressed).
    private var isSafariDodged: Bool { policy.passiveReasons.contains(.safariFullscreen) }

    /// Apply (or lift) the Safari-fullscreen dodge for the panel's current
    /// screen. Entering force-closes an open island (same pattern as the
    /// menu-bar overlap) and slides the panel right of the URL field; leaving
    /// slides it back to centre. While the capture hotkey holds the island
    /// open, application is deferred to the collapse landing — the island must
    /// not jump mid-typing.
    private func applySafariDodge() {
        guard !captureHotkeyActive else { return }
        let targetOffset: CGFloat
        let targetYOffset: CGFloat
        let active: Bool
        if let dodge = safariDodge, let screen = currentScreen, dodge.screen !== screen {
            // NSScreen identity is the suspect to rule out if the dodge ever
            // fails silently on a single display.
            NSLog("CoteDOs: dodge reported for other screen (dodge \(dodge.screen.frame) vs current \(screen.frame))")
        }
        if let dodge = safariDodge, let screen = currentScreen, dodge.screen === screen {
            let pillWidth = viewModel.collapsedWidth(isPlaying: hasAudioHero, hasItems: !shelf.items.isEmpty, timerText: pomodoro.pillText)
            let centerX = SafariFullscreenMonitor.dodgePillCenterX(
                urlFieldMaxX: dodge.urlFieldFrame.maxX, screenFrame: screen.frame,
                pillWidth: pillWidth)
            targetOffset = centerX - screen.frame.midX
            // Vertically centre the pill on the URL field (nudged up by the
            // raise — the AX frame hugs the text, the visible container reads
            // higher) so it nestles beside the toolbar instead of hugging the
            // screen's top edge.
            let restingCenterY = screen.frame.maxY - NotchLayout.islandTopGap - viewModel.collapsedHeight / 2
            targetYOffset = max(0, (restingCenterY - dodge.urlFieldFrame.midY - NotchLayout.safariDodgeRaise).rounded())
            active = true
        } else {
            targetOffset = 0
            targetYOffset = 0
            active = false
        }

        if active, !isSafariDodged {
            stageWorkItem?.cancel(); stageWorkItem = nil
            stagingTarget = nil
            collapseWorkItem?.cancel()
            viewModel.islandState = .collapsed
            policy.passiveReasons.insert(.safariFullscreen)
        } else if !active, isSafariDodged {
            policy.passiveReasons.remove(.safariFullscreen)
        }

        if panelXOffset != targetOffset || panelYOffset != targetYOffset, let screen = currentScreen {
            panelXOffset = targetOffset
            panelYOffset = targetYOffset
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NotchLayout.idleHideFadeDuration
                panel.animator().setFrame(panelFrame(on: screen), display: true)
            }
        }
        applyPresence(animated: false)
    }

    /// Move the panel to the screen the cursor is on if it has changed. Only
    /// acts while collapsed so an open island doesn't jump mid-interaction.
    private func followCursorScreenIfNeeded() {
        guard !viewModel.isExpanded else { return }
        guard let screen = ScreenManager.targetScreen(), screen !== currentScreen else { return }
        reposition()
    }

    // MARK: - Hover

    /// Hover detection is driven by the *real* cursor position
    /// (`NSEvent.mouseLocation`) checked against the actually-rendered island
    /// rect in screen coordinates — not by an `NSTrackingArea`. Tracking areas
    /// fire unreliably for a borderless, non-activating panel pinned to the top
    /// screen edge (it overlaps the menu bar), which caused the notch to expand
    /// while the cursor was merely inside the *expanded* footprint rather than
    /// over the small visible pill. A global + local mouse-moved monitor is
    /// deterministic: we only expand when the cursor is genuinely over the pill.
    /// `.leftMouseDragged` is monitored alongside `.mouseMoved` because a
    /// file drag emits *only* dragged events — without it, the click-through
    /// gate (`panel.ignoresMouseEvents`) keeps whatever value it had before
    /// the drag started, and an ignoring panel is skipped by AppKit's drag-
    /// destination routing entirely, so the shelf never sees the drag. During
    /// a drag we only refresh the gate; expanding stays with
    /// `handleDragEntered`, which fires solely for registered file drags.
    private func installHoverMonitor() {
        hoverMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.evaluateHover(isDrag: event.type == .leftMouseDragged)
        }
        hoverMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.evaluateHover(isDrag: event.type == .leftMouseDragged)
            return event
        }
    }

    /// The current interactive footprint's size — matches what
    /// `NotchContainerView.hitTest` actually accepts clicks within. Shared by
    /// `container.islandRect` (view-local) and `interactiveScreenRect` (screen
    /// coordinates) so the two never drift apart.
    /// Mirrors `NotchRootView.hasAudioHero`: the pill widens for the audio hero
    /// not only while a scriptable player reports `isPlaying`, but also while
    /// any other system audio keeps the spectrum alive. The hit/hover rects
    /// must use the same condition, or the visible pill grows wider than the
    /// area that reacts to the cursor.
    private var hasAudioHero: Bool {
        nowPlaying.isPlaying || spectrum.hasSignal
    }

    private func currentIslandSize() -> (width: CGFloat, height: CGFloat) {
        // Stay at the expanded footprint through the whole staged walk, not
        // only at the terminal `.expanded` state — otherwise clicks fall
        // through the still-visible large island while it collapses.
        if viewModel.occupiesExpandedFootprint {
            return (viewModel.expandedWidth, viewModel.expandedHeight)
        }
        // Hug the visible pill (which sizes to its content) plus a small
        // tolerance, so it only expands when hovering the notch itself.
        let width = viewModel.collapsedWidth(isPlaying: hasAudioHero, hasItems: !shelf.items.isEmpty, timerText: pomodoro.pillText) + NotchLayout.hitTestWidthPadding
        let height = viewModel.collapsedHeight + NotchLayout.hitTestHeightPadding
        return (width, height)
    }

    /// Horizontal shift of the collapsed pill off screen centre — the
    /// controller-side mirror of `NotchRootView.islandXOffset`, so the hit and
    /// hover rects track the asymmetric (hero-centred) pill. Zero whenever the
    /// interactive footprint is the big expanded rect anyway (which contains
    /// the shifted pill), and zero while an activity pill shows (it renders
    /// centred).
    private func currentIslandXShift() -> CGFloat {
        guard !viewModel.occupiesExpandedFootprint, activities.current == nil else { return 0 }
        return viewModel.collapsedTrailingShift(isPlaying: hasAudioHero, hasItems: !shelf.items.isEmpty, timerText: pomodoro.pillText)
    }

    /// The actual clickable footprint in global screen coordinates — the same
    /// rect `NotchContainerView.hitTest` honors, without the extra hover
    /// tolerance `islandScreenRect` adds for open/close hysteresis. Used to
    /// gate `panel.ignoresMouseEvents` so the panel only ever claims clicks
    /// within the area that's actually interactive.
    private func interactiveScreenRect() -> NSRect? {
        guard let screen = ScreenManager.targetScreen() else { return nil }
        let (width, height) = currentIslandSize()
        return NSRect(
            x: screen.frame.midX - width / 2 + currentIslandXShift() + panelXOffset,
            y: screen.frame.maxY - NotchLayout.islandTopGap - height - panelYOffset,
            width: width,
            height: height
        )
    }

    /// Keep the panel click-through outside its visible footprint: the real
    /// `NSPanel` frame is always sized for the expanded island plus shadow
    /// margin (see `reposition`), so without this, clicks in the leftover
    /// space around a collapsed pill would still make the panel (and app) key
    /// — `NotchContainerView.hitTest` only stops the *content* from reacting,
    /// it doesn't stop AppKit's window-level activation on mouse-down.
    private func updateClickThrough(isDrag: Bool = false) {
        let cursor = NSEvent.mouseLocation
        // A file drag approaching the *idle-hidden* notch: the pill is
        // invisible and pill-sized — an impossible drop target. Open the gate
        // across the whole expanded footprint instead, so AppKit's drag-
        // destination routing can find the container view at all;
        // `handleDragEntered` then un-hides and expands. Only the lone `.idle`
        // reason gets this — a menu-bar-overlap hide stays inert, and a
        // visible pill keeps its exact rect-gated behaviour.
        if isDrag, policy.hideReasons == [.idle],
           let zone = islandScreenRect(expanded: true), zone.contains(cursor) {
            panel.ignoresMouseEvents = false
            return
        }
        let inside = interactiveScreenRect()?.contains(cursor) ?? false
        panel.ignoresMouseEvents = policy.ignoresMouseEvents(
            cursorInsideInteractiveRect: inside,
            hotkeyOverride: captureHotkeyActive
        )
    }

    /// The visible island rect in global screen coordinates (origin bottom-left),
    /// matching what the SwiftUI island actually draws: centered horizontally,
    /// floating `islandTopGap` below the top screen edge.
    private func islandScreenRect(expanded: Bool) -> NSRect? {
        guard let screen = ScreenManager.targetScreen() else { return nil }
        let width: CGFloat
        let height: CGFloat
        if expanded {
            width = viewModel.expandedWidth + NotchLayout.expandedHoverInset * 2
            height = viewModel.expandedHeight + NotchLayout.expandedHoverInset
        } else {
            width = viewModel.collapsedWidth(isPlaying: hasAudioHero, hasItems: !shelf.items.isEmpty, timerText: pomodoro.pillText) + NotchLayout.collapsedHoverInset * 2
            height = viewModel.collapsedHeight + NotchLayout.collapsedHoverInset
        }
        // The island floats `islandTopGap` below the edge, but the hover zone
        // still spans all the way to (and past) the top: pushing the cursor
        // against the screen edge above the island must keep opening it. The
        // extra bleed exists because the cursor's y at the very top equals
        // screen.frame.maxY, and NSRect.contains treats the top edge as
        // exclusive (y < maxY) — without it the notch would refuse to open at
        // the screen edge and collapse the instant the cursor reaches it.
        let topBleed = NotchLayout.hoverTopBleed
        return NSRect(
            x: screen.frame.midX - width / 2 + (expanded ? 0 : currentIslandXShift()) + panelXOffset,
            y: screen.frame.maxY - NotchLayout.islandTopGap - height - panelYOffset,
            width: width,
            height: height + NotchLayout.islandTopGap + topBleed
        )
    }

    /// Pause or resume the whole notch on the user's say-so. Pausing
    /// force-closes an open island and hides the panel; a hidden panel is
    /// unconditionally click-through (`PanelPresencePolicy`), so the exact
    /// spot the notch occupied becomes hoverable and clickable for whatever
    /// sits underneath — the reason this exists. Resuming only lifts this one
    /// reason; an idle or overlap hide stays in force.
    func setUserDisabled(_ disabled: Bool) {
        guard isUserDisabled != disabled else { return }
        if disabled {
            stageWorkItem?.cancel(); stageWorkItem = nil
            stagingTarget = nil
            collapseWorkItem?.cancel()
            captureHotkeyActive = false
            viewModel.islandState = .collapsed
            policy.hideReasons.insert(.userDisabled)
        } else {
            policy.hideReasons.remove(.userDisabled)
            // Coming back with nothing to show should land hidden-idle, not
            // flash the empty pill under a cursor that isn't near it.
            refreshIdlePresence(animated: false)
        }
        applyPresence(animated: false)
    }

    /// Hide (and stop hit-testing) the panel while the frontmost app's menu
    /// bar overlaps the notch pill, and restore it once the overlap clears.
    /// An already-open island is forced closed first so it doesn't obscure
    /// the menu bar it just started overlapping.
    private func setMenuBarOverlap(_ active: Bool) {
        guard menuBarOverlapActive != active else { return }
        if active {
            stageWorkItem?.cancel(); stageWorkItem = nil
            stagingTarget = nil
            collapseWorkItem?.cancel()
            captureHotkeyActive = false
            viewModel.islandState = .collapsed
            policy.hideReasons.insert(.menuBarOverlap)
        } else {
            // Only this reason is lifted — any other hide reason (e.g. idle)
            // stays in force instead of being blanket-restored away.
            policy.hideReasons.remove(.menuBarOverlap)
        }
        applyPresence(animated: false)
    }

    private func evaluateHover(isDrag: Bool = false) {
        guard !menuBarOverlapActive, !isUserDisabled else { return }
        let cursor = NSEvent.mouseLocation
        if let last = lastEvaluatedCursor, abs(last.x - cursor.x) < 1, abs(last.y - cursor.y) < 1 {
            return
        }
        lastEvaluatedCursor = cursor
        followCursorScreenIfNeeded()
        updateClickThrough(isDrag: isDrag)

        // While dodged beside Safari's fullscreen URL bar the pill is
        // deliberately passive: an expanded island there would sit on top of
        // the toolbar and re-introduce exactly the interference the dodge
        // removes. The capture hotkey remains the deliberate escape hatch.
        if isSafariDodged { return }

        // Mid-drag, only the click-through gate matters (so the panel becomes
        // a valid drag destination). Hover expand/collapse must not run: a
        // text-selection drag over the pill shouldn't open the notch, and the
        // "cursor outside → collapse" branch would fight the drag-entered
        // expansion while a file hovers over the open shelf.
        if isDrag { return }

        // Only the resting `.expanded` state gets the big hover rect. Every
        // other state — including `.band`/`.solo`, which still render fairly
        // wide — is treated as the small pill for hover purposes, on request:
        // a cursor sitting in the leftover space of a collapsing notch should
        // not reopen it; only actually hovering the (shrinking) pill itself
        // should. The staged collapse/expand walk itself is untouched — it
        // still runs its own animation regardless of this hit-test rect.
        if viewModel.isExpanded {
            guard let rect = islandScreenRect(expanded: true) else { return }
            let inside = rect.contains(cursor)
            if inside {
                collapseWorkItem?.cancel()
                // Reverse an in-progress collapse walk (no-op once fully open).
                // Respect the post-swipe suppression so a swipe-up close isn't
                // instantly undone by a stationary cursor.
                if !suppressHover { setExpanded(true) }
            } else if !shelf.isDropTargeted && viewModel.holdsIslandOpen {
                // The spectrum page is up: something to leave running and watch,
                // so the cursor leaving means nothing. No grace timer either —
                // this releases itself on a tab change or a close, so it can't
                // get stuck the way the capture lock could. Swipe up (or ⌥⌘S to
                // take it fullscreen) remains the way out.
                collapseWorkItem?.cancel()
            } else if !shelf.isDropTargeted && !viewModel.isInteractionLocked {
                // Cursor left the fully-expanded footprint: collapse
                // immediately. The hover monitor is deterministic, so no
                // debounce delay is needed.
                collapseWorkItem?.cancel()
                setExpanded(false)
            } else if !shelf.isDropTargeted && viewModel.isInteractionLocked {
                // The capture field is focused (e.g. right after submitting a
                // note, which re-focuses it for the next thought) and normally
                // that keeps the island open so typing isn't dismissed. But
                // nothing ever un-focuses it on its own, so without this the
                // island stayed open forever once you'd used Capture — the
                // cursor being gone is itself a signal you're done. Grant a
                // short grace period instead of blocking collapse indefinitely.
                if collapseWorkItem == nil {
                    let work = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        // Clear the slot first: the `== nil` guard above is what
                        // re-arms this grace timer, so a fired item must release
                        // it or the grace never schedules again after the first.
                        self.collapseWorkItem = nil
                        self.viewModel.isInteractionLocked = false
                        self.setExpanded(false)
                    }
                    collapseWorkItem = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + NotchLayout.interactionLockGraceDelay, execute: work)
                }
            }
        } else {
            // Stage one of the idle reveal: with nothing to show, the pill's
            // *presence* follows proximity to the expanded footprint — enter
            // and the collapsed pill fades in, leave and it fades back out.
            // Expanding (stage two) still needs the pill-rect hover below or
            // the swipe gesture, same as a content-bearing pill.
            guard let rect = islandScreenRect(expanded: false) else { return }
            if !hasCollapsedContent && !shelf.isDropTargeted {
                // A cursor that has already reached the pill is about to open
                // it, and the expand walk glides the selected glyph 88 pt
                // across the island. Played over a panel that is still fading
                // up, that reads as an icon flying in from nowhere rather than
                // as the pill's own glyph travelling — which is why coming in
                // fast looked so different from arriving slowly, when the fade
                // was long finished. Snap it visible instead, the same way a
                // drag reaching the hidden notch does.
                refreshIdlePresence(animated: !rect.contains(cursor))
            }
            guard !policy.isHidden else { return }
            let inside = rect.contains(cursor)
            if inside {
                guard !suppressHover else { return }
                collapseWorkItem?.cancel()
                setExpanded(true)
            } else {
                // Cursor left the pill: clear the post-swipe suppression so the
                // next genuine hover can expand again.
                suppressHover = false
            }
        }
    }

    // MARK: - File drag

    private func handleDragEntered() {
        guard !menuBarOverlapActive, !isSafariDodged, !isUserDisabled else { return }
        collapseWorkItem?.cancel()
        suppressHover = false
        // A drag reaching the hidden notch un-hides it — snap, the expand walk
        // is about to move anyway.
        policy.hideReasons.remove(.idle)
        applyPresence(animated: false)
        viewModel.selectedTab = .files
        shelf.isDropTargeted = true
        if !viewModel.isExpanded {
            setExpanded(true)
        }
    }

    private func handleDragExited() {
        shelf.isDropTargeted = false
        scheduleCollapse()
    }

    private func handleDrop(_ urls: [URL]) {
        shelf.isDropTargeted = false
        viewModel.selectedTab = .files
        for url in urls {
            shelf.add(url)
        }
        Haptics.perform(.generic)
        if !urls.isEmpty {
            activities.fileReceived(count: urls.count)
        }
    }

    private func scheduleCollapse() {
        collapseWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.collapseWorkItem = nil
            self?.setExpanded(false)
        }
        collapseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchLayout.collapseDelay, execute: work)
    }

    // MARK: - Trackpad gestures

    private func installScrollMonitor() {
        // Local monitor: fires when the scroll lands on the panel (cursor over the
        // interactive island rect). Handles open *and* close and consumes the event.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handleIslandScroll(event) ? nil : event
        }
        // Global monitor: while collapsed, a two-finger swipe-down should also open
        // the notch anywhere within the *expanded* notch footprint — not just over
        // the small pill. Outside the pill `NotchContainerView.hitTest` returns nil
        // (so clicks fall through), which means the local monitor never sees those
        // scrolls; the global monitor catches them. Global monitors are observe-only
        // (they can't consume the event), which is fine for a mere open.
        scrollMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleBigNotchRegionScroll(event)
        }
    }

    /// Handle a deliberate swipe on the island itself. Returns whether it was
    /// consumed. Natural scrolling: two fingers down -> dy > 0 -> open; while
    /// expanded, a horizontal swipe pages between tabs.
    private func handleIslandScroll(_ event: NSEvent) -> Bool {
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        let threshold = NotchLayout.gestureScrollThreshold

        // Horizontal swipe while expanded -> page between tabs. Fire only on the
        // first event of a gesture so momentum doesn't skip through several tabs.
        if viewModel.isExpanded, abs(dx) > threshold, abs(dx) > abs(dy) {
            let now = Date()
            let isNewGesture = now.timeIntervalSince(lastHorizontalScroll) > NotchLayout.tabSwipeGestureGap
            lastHorizontalScroll = now
            if isNewGesture { pageTab(next: dx < 0) }
            return true
        }

        // Vertical swipe -> expand / collapse.
        guard abs(dy) > threshold, abs(dy) > abs(dx) else { return false }
        if dy > 0 {
            // Swiping only ever opens the island — it no longer carries on into
            // the fullscreen takeover. That third step is a click on the
            // spectrum page, and Escape brings it home; a scroll gesture landing
            // you in a full-screen visual you didn't ask for was too easy to
            // trigger by accident. ⌥⌘S remains the keyboard route.
            expandViaGesture()
        } else {
            collapseViaGesture()
        }
        return true
    }

    /// Move the tab selection one step, clamped to the ends (no wrap-around).
    /// `next` advances toward the last enabled tab; `!next` toward the first.
    private func pageTab(next: Bool) {
        let tabs = NotchViewModel.enabledTabs
        guard let index = tabs.firstIndex(of: viewModel.selectedTab) else { return }
        let target = index + (next ? 1 : -1)
        guard tabs.indices.contains(target) else { return }
        Haptics.perform(.alignment)
        withAnimation(NotchLayout.tabChangeAnimation) { viewModel.selectedTab = tabs[target] }
    }

    /// Open the collapsed notch from a swipe-down that lands anywhere within the
    /// expanded-notch footprint (the "big notch" boundary), where the local monitor
    /// can't see the event because hit-testing lets it fall through.
    private func handleBigNotchRegionScroll(_ event: NSEvent) {
        guard !menuBarOverlapActive, !isSafariDodged, !isUserDisabled, !viewModel.isExpanded else { return }
        let dy = event.scrollingDeltaY
        guard dy > 0, abs(dy) > NotchLayout.gestureScrollThreshold, abs(dy) > abs(event.scrollingDeltaX) else { return }
        guard let rect = islandScreenRect(expanded: true), rect.contains(NSEvent.mouseLocation) else { return }
        expandViaGesture()
    }

    private func expandViaGesture() {
        suppressHover = false
        collapseWorkItem?.cancel()
        guard !viewModel.isExpanded else { return }
        // A swipe can arrive while the pill is still idle-hidden (the reveal
        // and the gesture race on the same mouse position) — un-hide first.
        policy.hideReasons.remove(.idle)
        applyPresence(animated: false)
        setExpanded(true)
    }

    private func collapseViaGesture() {
        collapseWorkItem?.cancel()
        guard viewModel.isExpanded else { return }
        suppressHover = true
        setExpanded(false)
    }

    // MARK: - State

    /// The expand/collapse stage sequence, most-collapsed first. Both
    /// directions walk this list one step at a time (`advanceStaging`), so the
    /// collapse — panel → tab band → solo tab → lone icon → pill — plays in
    /// exact reverse when opening.
    private static let stageOrder: [NotchViewModel.IslandState] =
        [.collapsed, .condensing, .solo, .band, .expanded]

    /// Walk the island one stage at a time toward the given end state. Called
    /// repeatedly by hover/gesture; re-targeting mid-walk just reverses from
    /// wherever we are. `staged: false` jumps straight there (the capture
    /// hotkey wants the field open now, not after the staged reveal).
    private func setExpanded(_ expanded: Bool, staged: Bool = true) {
        let target: NotchViewModel.IslandState = expanded ? .expanded : .collapsed
        // Any collapse ends the hotkey's "interactive regardless of cursor"
        // override; the next updateClickThrough re-derives the gate normally.
        if !expanded { captureHotkeyActive = false }

        guard viewModel.islandState != target else {
            // Already there — make sure no stale walk keeps running.
            stageWorkItem?.cancel(); stageWorkItem = nil
            stagingTarget = nil
            return
        }
        guard staged else {
            stageWorkItem?.cancel(); stageWorkItem = nil
            pagesWorkItem?.cancel(); pagesWorkItem = nil
            stagingTarget = nil
            withAnimation(NotchLayout.islandExpandAnimation) { viewModel.islandState = target }
            // The hotkey jump wants its content now (the capture field is the
            // whole point); the mount hitch is acceptable without a walk.
            if expanded { viewModel.pagesSettled = true }
            Haptics.perform(.levelChange)
            updateClickThrough()
            return
        }
        guard stagingTarget != target else { return }  // already walking there
        stageWorkItem?.cancel(); stageWorkItem = nil
        pagesWorkItem?.cancel(); pagesWorkItem = nil
        stagingTarget = target
        // One tap the moment the morph is triggered — not per stage, which felt
        // like too much.
        Haptics.perform(.levelChange)
        advanceStaging()
    }

    /// Move the island one stage toward `stagingTarget`, then schedule the next
    /// step after that stage's rest delay. The final step lands on the target
    /// and ends the walk.
    private func advanceStaging() {
        guard let target = stagingTarget,
              let current = Self.stageOrder.firstIndex(of: viewModel.islandState),
              let goal = Self.stageOrder.firstIndex(of: target)
        else { return }
        guard current != goal else {
            stagingTarget = nil; stageWorkItem = nil
            return
        }

        let expanding = goal > current
        let next = Self.stageOrder[current + (expanding ? 1 : -1)]

        if next == .collapsed {
            // Handover to the pill: no withAnimation — the condensed icon and
            // the pill are visually identical; the content transition fades on
            // its own explicit clock (no crossfade dip).
            viewModel.islandState = .collapsed
        } else {
            // The final expand hop is the only stage that rests, so it alone
            // gets the overshoot-and-settle spring; intermediate hops are
            // re-animated right away and would turn overshoot into wobble.
            let animation: Animation = if expanding {
                next == .expanded ? NotchLayout.islandExpandFinalAnimation : NotchLayout.islandExpandAnimation
            } else {
                NotchLayout.islandCollapseAnimation
            }
            withAnimation(animation) {
                viewModel.islandState = next
            }
        }
        updateClickThrough()

        guard next != target else {
            stagingTarget = nil; stageWorkItem = nil
            if next == .collapsed {
                // The collapse has landed: re-apply a deferred Safari dodge
                // (a capture recentred the panel), then — with nothing to show
                // and the cursor away — fade the pill out entirely.
                applySafariDodge()
                refreshIdlePresence()
            }
            if next == .expanded {
                // The walk has landed: let the final spring's fast phase play
                // out on the empty island, then mount the page carousel into
                // a nearly still frame (see `pagesSettleDelay`).
                let work = DispatchWorkItem { [weak self] in
                    self?.pagesWorkItem = nil
                    self?.viewModel.pagesSettled = true
                }
                pagesWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + NotchLayout.pagesSettleDelay, execute: work)
            }
            return
        }
        let delay = stageRestDelay(entering: next, expanding: expanding)
        guard delay > 0 else {
            // A skipped (no-op) stage: advance synchronously so the state
            // writes coalesce into the same SwiftUI transaction — the first
            // *visible* hop then animates in the very frame the walk started,
            // instead of one runloop turn per skipped stage. Recursion is
            // bounded by the stage list, and nothing is scheduled that could
            // need cancelling.
            advanceStaging()
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.advanceStaging() }
        stageWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// How long to rest in an intermediate stage before advancing. Expand rests
    /// are shorter than collapse rests so opening stays responsive on hover.
    ///
    /// Stages that are pure no-ops for the current content skip their rest:
    /// with the pill hero active (music, other system audio, or the focus
    /// timer), `.condensing` and `.solo` have the pill's own geometry *and*
    /// show the very same persistent hero view — resting there is dead time
    /// the eye reads as hover lag on expand (200 ms of nothing before the
    /// island moved) and as a stale oversized hit rect after collapse.
    private func stageRestDelay(entering state: NotchViewModel.IslandState, expanding: Bool) -> TimeInterval {
        let heroContent = hasAudioHero || pomodoro.pillText != nil
        switch (state, expanding) {
        case (.band, false):       return NotchLayout.bandCollapseDelay
        case (.solo, false):       return NotchLayout.soloCollapseDelay
        case (.condensing, false): return heroContent ? 0 : NotchLayout.condenseSwapDelay
        case (.condensing, true):  return heroContent ? 0 : NotchLayout.condenseExpandDelay
        case (.solo, true):        return heroContent ? 0 : NotchLayout.soloExpandDelay
        case (.band, true):        return NotchLayout.bandExpandDelay
        default:                   return 0
        }
    }
}
