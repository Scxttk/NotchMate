import Combine
import SwiftUI

final class NotchViewModel: ObservableObject {
    /// Raw values are the case names and are persisted (see `selectedTab`), so
    /// renaming a case silently forgets which tab the user was on — add a new
    /// case rather than renaming one.
    enum Tab: String, CaseIterable {
        case music
        case spectrum
        case files
        case capture
        case timer

        var title: String {
            switch self {
            case .music:   return String(localized: "tab.music", defaultValue: "Musik")
            case .spectrum: return String(localized: "tab.spectrum", defaultValue: "Spectrum")
            case .files:   return String(localized: "tab.files", defaultValue: "Ablage")
            case .capture: return String(localized: "tab.capture", defaultValue: "Capture")
            case .timer:   return String(localized: "tab.timer", defaultValue: "Timer")
            }
        }

        var icon: String {
            switch self {
            // The waveform belongs to the spectrum — it is a picture of what
            // that tab actually draws. It sat on Musik back when the wave was
            // the app's whole identity and there was no spectrum tab to own it;
            // with one, Musik reads better as a plain note.
            case .music:   return "radio.fill"
            case .spectrum: return "waveform"
            case .files:   return "tray.full"
            case .capture: return "square.and.pencil"
            case .timer:   return "timer"
            }
        }
    }

    /// The island's visual state. Collapsing is staged (iPhone-style):
    /// - `.band`  — capsule holding every tab group (icon + label).
    /// - `.solo`  — only the selected tab group remains (icon + label), the
    ///   others having faded out as the capsule narrows onto it.
    /// - `.condensing` — the label drops too; just the selected icon is left,
    ///   the capsule now exactly pill-width and -positioned.
    /// - `.collapsed` — the real pill content swaps in, pixel-identical to the
    ///   condensed icon, so the handover is invisible.
    /// The controller orchestrates the steps; only `.expanded` and `.collapsed`
    /// are resting states, the rest are transient stops on the way down.
    enum IslandState {
        case expanded
        case band
        case solo
        case condensing
        case collapsed
    }

    @Published var islandState: IslandState = .collapsed {
        didSet {
            // Any step away from rest invalidates the mounted pages — the
            // collapse-side removal fade keys off this flipping false at the
            // very first collapse hop, and a later expand must re-earn it
            // via the controller's settle timer (see `pagesSettleDelay`).
            if islandState != .expanded { pagesSettled = false }
            // Only a *closed* island resets the tab bar's entrance. On the way
            // down it has to stay visible: the selected icon is what the pill's
            // glyph is handed over from, and that handover is pixel-tuned.
            if islandState == .collapsed { chromeRevealed = false }
        }
    }

    /// True once the island has rested in `.expanded` long enough to afford
    /// mounting the page carousel (the heaviest view-building moment).
    /// Set by the controller; cleared automatically whenever the island
    /// leaves `.expanded`.
    @Published var pagesSettled = false {
        didSet {
            guard pagesSettled != oldValue else { return }
            guard pagesSettled else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + NotchLayout.chromeRevealDelay) { [weak self] in
                guard let self, self.pagesSettled else { return }
                self.chromeRevealed = true
            }
        }
    }

    /// True once the island is not just open but settled — pages mounted, a
    /// beat past the last spring. The travelling spectrum reads it to tell a
    /// carousel move from the island merely opening, which look identical in
    /// state and want opposite exits (see `NotchRootView.waveExitTransition`).
    @Published private(set) var chromeRevealed = false

    /// The logical open/closed state — `.band` counts as closed (it's a
    /// transient stop on the way down; hover/gesture logic treats it like the
    /// pill so a re-hover immediately re-expands).
    var isExpanded: Bool { islandState == .expanded }

    /// True whenever the island is *not* fully collapsed — i.e. at `.expanded`
    /// or anywhere along the staged collapse/expand walk (`.band`/`.solo`/
    /// `.condensing`). The click hit-test rect keys off this so it stays at the
    /// large footprint while the silhouette is still visibly springing down,
    /// instead of snapping to the tiny pill the instant the logical state
    /// flips. Without it the collapsing island can't be caught and clicks fall
    /// through mid-walk. Hover uses the stricter `isExpanded` instead (see
    /// `NotchWindowController.evaluateHover`) — a cursor sitting in the
    /// leftover space of a collapsing/expanding notch shouldn't reopen it,
    /// only actually hovering the pill should.
    var occupiesExpandedFootprint: Bool { islandState != .collapsed }

    /// The tab the island is on, remembered across launches. Which tab you are on
    /// is your choice, not playback's — see the `isPlaying` handler in
    /// `NotchRootView`, which deliberately does not touch this.
    @Published var selectedTab: Tab = NotchViewModel.restoredTab {
        didSet {
            guard selectedTab != oldValue else { return }
            UserDefaults.standard.set(selectedTab.rawValue, forKey: Self.selectedTabKey)
        }
    }

    private static let selectedTabKey = "selectedTab"

    /// Which screen border the island is parked on, remembered across launches.
    ///
    /// State rather than pure geometry, so it lives here: the view reads the
    /// edge to know which way the island grows when it opens, and the
    /// controller reads it for every rect that reacts to the cursor.
    /// `NotchWindowController` owns all the writes — it is the one that knows
    /// which screen the placement has to fit on.
    @Published var placement: NotchPlacement = NotchViewModel.restoredPlacement {
        didSet {
            guard placement != oldValue else { return }
            UserDefaults.standard.set(placement.dock.rawValue, forKey: Self.dockKey)
            UserDefaults.standard.set(placement.anchor.rawValue, forKey: Self.dockAnchorKey)
            UserDefaults.standard.set(Double(placement.along), forKey: Self.dockAlongKey)
        }
    }

    private static let dockKey = "notchDock"
    private static let dockAnchorKey = "notchDockAnchor"
    private static let dockAlongKey = "notchDockOffset"

    private static var restoredPlacement: NotchPlacement {
        guard let raw = UserDefaults.standard.string(forKey: dockKey),
              let dock = NotchDock(rawValue: raw) else { return .home }
        // An install from before corners existed has no anchor stored; it was
        // positioned by `along` alone, which is exactly `.centre`.
        let anchor = UserDefaults.standard.string(forKey: dockAnchorKey)
            .flatMap(NotchPlacement.Anchor.init(rawValue:)) ?? .centre
        return NotchPlacement(dock: dock, anchor: anchor,
                              along: CGFloat(UserDefaults.standard.double(forKey: dockAlongKey)))
    }

    /// The last tab, if it is still one the user offers. Falls back to the
    /// first enabled tab rather than to `.music`, which may itself be switched
    /// off in Settings.
    private static var restoredTab: Tab {
        let fallback = enabledTabs.first ?? .music
        guard let raw = UserDefaults.standard.string(forKey: selectedTabKey),
              let tab = Tab(rawValue: raw),
              UserSettings.shared.isTabEnabled(tab) else { return fallback }
        return tab
    }

    /// The tabs actually offered — each tab can be switched off in Settings.
    /// Used by the tab bar and the swipe pager; the carousel itself keeps all
    /// pages mounted (indices stay stable, the page is just unreachable while
    /// disabled). The Settings UI guarantees at least one tab stays enabled.
    static var enabledTabs: [Tab] {
        Tab.allCases.filter { UserSettings.shared.isTabEnabled($0) }
    }

    private var cancellables: Set<AnyCancellable> = []

    init() {
        // If the currently selected tab gets disabled in Settings, fall back to
        // the first enabled tab — otherwise the island would sit on a page the
        // tab bar no longer offers. Receive on main so `enabledTabs` is read
        // *after* the setting actually changed (`objectWillChange` fires before).
        UserSettings.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let enabled = Self.enabledTabs
                if !enabled.contains(self.selectedTab), let fallback = enabled.first {
                    self.selectedTab = fallback
                }
            }
            .store(in: &cancellables)
    }

    /// While true (e.g. the capture field is focused) the island won't auto-
    /// collapse when the cursor leaves it — otherwise typing would dismiss it.
    /// Granted only a short grace period, because nothing un-focuses that field
    /// on its own; see `NotchWindowController.evaluateHover`.
    @Published var isInteractionLocked: Bool = false

    /// Whether the open island should stay open regardless of the cursor, with
    /// no grace period at all.
    ///
    /// True on the spectrum page, which is the one tab that exists to be *left
    /// running and looked at* — a visualiser that closes two seconds after you
    /// move the mouse away is not a visualiser. Unlike `isInteractionLocked`
    /// this needs no timer to release it: it falls false on its own the moment
    /// you switch tabs or close the island, so it cannot get stuck open the way
    /// a focused text field could.
    var holdsIslandOpen: Bool {
        islandState == .expanded && selectedTab == .spectrum
    }

    /// Bumped to ask the capture field to take focus (e.g. via the global hotkey).
    @Published var captureFocusToken: Int = 0

    func requestCaptureFocus() {
        guard Self.enabledTabs.contains(.capture) else { return }
        selectedTab = .capture
        captureFocusToken += 1
    }

    // Visible island dimensions (sourced from NotchLayout).
    /// Taller while the spectrum-only pill is on — that mode is for watching,
    /// and the extra height is the bars' travel. Single source for the
    /// silhouette, the hit/hover rects and the content rows' pinning, so the
    /// pill can't end up taller than the area that reacts to it.
    /// The pill's thickness — its extent *away* from the border it is on, so
    /// the height of a pill at the top and the width of one at the side. Named
    /// for the old top-only world; every axis-aware caller goes through
    /// `collapsedIslandSize` instead.
    var collapsedHeight: CGFloat { NotchLayout.currentCollapsedHeight }
    var expandedWidth: CGFloat { NotchLayout.expandedSize(on: placement.dock).width }
    var expandedHeight: CGFloat { NotchLayout.expandedSize(on: placement.dock).height }

    /// The open island's size on the border it is currently parked on.
    var expandedIslandSize: CGSize { NotchLayout.expandedSize(on: placement.dock) }

    /// The collapsed pill's size on the border it is currently parked on: the
    /// content-driven length runs along the border, the fixed thickness across
    /// it. On a side border that is a capsule standing on end.
    func collapsedIslandSize(isPlaying: Bool, hasItems: Bool, timerText: String?) -> CGSize {
        placement.dock.size(
            length: collapsedWidth(isPlaying: isPlaying, hasItems: hasItems, timerText: timerText),
            thickness: collapsedHeight
        )
    }

    /// Collapsed pill width, computed to hug whatever the pill actually shows.
    /// Depends on playback (artwork + visualizer are wider than the idle
    /// glyph), the focus-timer readout (replaces the glyph when idle, joins to
    /// the right of the visualizer when playing) and the shelf badge, plus the
    /// end padding that keeps content clear of the capsule's corner curve —
    /// otherwise the clip swallows edges.
    func collapsedWidth(isPlaying: Bool, hasItems: Bool, timerText: String?) -> CGFloat {
        var core: CGFloat
        if isPlaying {
            // Spectrum-only mode drops the artwork thumbnail and lets the wave
            // span the freed space; by construction the two variants are the
            // same width, but both read their own constant so neither silently
            // drifts if one is retuned.
            core = UserSettings.shared.pillSpectrumOnly
                ? NotchLayout.pillSpectrumSnappedWidth(UserSettings.shared.pillSpectrumWidth)
                : NotchLayout.collapsedArtworkWidth + NotchLayout.collapsedItemSpacing + NotchLayout.collapsedWavesWidth
            if let timerText {
                core += NotchLayout.collapsedItemSpacing + Self.timerSegmentWidth(timerText)
            }
        } else if let timerText {
            core = Self.timerSegmentWidth(timerText)
        } else {
            core = NotchLayout.collapsedGlyphWidth
        }
        if hasItems {
            core += NotchLayout.collapsedItemSpacing + NotchLayout.collapsedBadgeWidth
        }
        return core + 2 * (NotchLayout.collapsedContentPadding + NotchLayout.collapsedEndPadding)
    }

    /// How far the collapsed capsule's *frame* shifts right of screen centre so
    /// the audio hero core stays exactly centred while the trailing segments
    /// (timer readout, shelf badge) grow to the right of it. Zero without the
    /// hero: a timer-only or idle pill stays symmetric as before. The trailing
    /// segments' centre sits `trailing/2` right of the frame centre, so
    /// shifting the frame by that amount puts the hero core back on
    /// `screen.midX`. Must stay in lock-step with `collapsedWidth` — both read
    /// the very same `NotchLayout` constants, or the visible pill and the
    /// hit/hover rects drift apart.
    func collapsedTrailingShift(isPlaying: Bool, hasItems: Bool, timerText: String?) -> CGFloat {
        guard isPlaying else { return 0 }
        var trailing: CGFloat = 0
        if let timerText {
            trailing += NotchLayout.collapsedItemSpacing + Self.timerSegmentWidth(timerText)
        }
        if hasItems {
            trailing += NotchLayout.collapsedItemSpacing + NotchLayout.collapsedBadgeWidth
        }
        return trailing / 2
    }

    /// Estimated width of the pill's timer segment (icon + readout). Must stay
    /// in lock-step with the segment layout in `CollapsedView`.
    static func timerSegmentWidth(_ text: String) -> CGFloat {
        NotchLayout.collapsedTimerIconWidth + NotchLayout.collapsedTimerInnerSpacing
            + CGFloat(text.count) * NotchLayout.collapsedTimerCharWidth
    }

    /// Width of the intermediate `.solo` capsule — the same for every tab now
    /// that the row is icon-only. It used to be the base plus *twice* the
    /// title's width (twice, because an invisible mirror of the label sat left
    /// of the icon to keep it centred), which is why it used to be asked per
    /// tab. No label, no mirror, no per-tab width, and the capsule lands much
    /// closer to the pill it is handing over to.
    var soloWidth: CGFloat { NotchLayout.soloBaseWidth }

    // The panel keeps a constant size *per border*; only the SwiftUI island
    // animates inside it. Extra margin leaves room for the island's shadow —
    // the generous one along the border, the tight one across it, since the
    // edge itself clips that side's shadow anyway.
    var panelSize: CGSize {
        let (length, thickness) = placement.dock.lengthAndThickness(of: expandedIslandSize)
        return placement.dock.size(length: length + NotchLayout.panelHorizontalMargin,
                                   thickness: thickness + NotchLayout.panelVerticalMargin)
    }
    var panelWidth: CGFloat { panelSize.width }
    var panelHeight: CGFloat { panelSize.height }
}
