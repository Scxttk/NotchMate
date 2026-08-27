import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted when the user resets all data; live models clear themselves.
    static let notchMateResetData = Notification.Name("com.scott.notchmate.resetData")
    /// Posted by Settings to put a dragged-away island back at the top centre.
    /// A notification rather than a reference because the Settings scene is
    /// built by SwiftUI and has no path to the window controller.
    static let notchResetPlacement = Notification.Name("com.scott.notchmate.resetPlacement")
}

/// User-facing preferences, persisted in `UserDefaults`. Injected as an
/// `@EnvironmentObject` / `@ObservedObject` so SwiftUI views and controllers
/// react to changes live. Keep keys stable — they are the on-disk contract.
final class UserSettings: ObservableObject {
    static let shared = UserSettings()

    enum MediaSource: String, CaseIterable, Identifiable {
        case auto
        case spotify
        case appleMusic

        var id: String { rawValue }

        var localizedName: String {
            switch self {
            case .auto: return String(localized: "source.auto", defaultValue: "Automatisch")
            case .spotify: return String(localized: "source.spotify", defaultValue: "Spotify")
            case .appleMusic: return String(localized: "source.appleMusic", defaultValue: "Apple Music")
            }
        }

        /// Bundle ID of the player app, to match against the bundle ID
        /// `SpectrumAnalyzer` reports for whatever is actually feeding audio.
        /// nil for `.auto`, which is a selection mode, not an app.
        var bundleID: String? {
            switch self {
            case .auto: return nil
            case .spotify: return "com.spotify.client"
            case .appleMusic: return "com.apple.Music"
            }
        }
    }

    enum Appearance: String, CaseIterable, Identifiable {
        case system
        case dark
        case light

        var id: String { rawValue }

        var localizedName: String {
            switch self {
            case .system: return String(localized: "appearance.system", defaultValue: "Systemstandard")
            case .dark: return String(localized: "appearance.dark", defaultValue: "Dunkel")
            case .light: return String(localized: "appearance.light", defaultValue: "Hell")
            }
        }
    }

    /// How Quick Capture writes into the vault. `.silentAppend` is the default —
    /// it appends directly to the daily note's file without stealing focus.
    /// `.openInObsidian` does the same silent append, then reveals the note in
    /// Obsidian so the user sees it.
    enum CaptureMode: String, CaseIterable, Identifiable {
        case silentAppend
        case openInObsidian

        var id: String { rawValue }

        var localizedName: String {
            switch self {
            case .silentAppend: return String(localized: "capture.mode.silent", defaultValue: "Lautlos anhängen")
            case .openInObsidian: return String(localized: "capture.mode.open", defaultValue: "Anhängen & in Obsidian öffnen")
            }
        }
    }

    private enum Key {
        static let mediaSource = "mediaSource"
        static let appearance = "appearance"
        static let liveActivitiesEnabled = "liveActivitiesEnabled"
        static let audioRouteActivityEnabled = "audioRouteActivityEnabled"
        static let hudEnabled = "hudEnabled"
        static let suppressSystemOSD = "suppressSystemOSD"
        static let pillSpectrumOnly = "pillSpectrumOnly"
        /// Removed: the bar count is derived from `pillSpectrumWidth` now. Kept
        /// as a name only so the migration below can find and clear it.
        static let legacyPillSpectrumBarCount = "pillSpectrumBarCount"
        static let pillSpectrumWidth = "pillSpectrumWidth"
        // Obsidian Quick Capture
        static let vaultBookmark = "obsidianVaultBookmark"
        static let vaultName = "obsidianVaultName"
        static let dailyFolder = "obsidianDailyFolder"
        static let dailyFormat = "obsidianDailyFormat"
        static let captureHeading = "obsidianCaptureHeading"
        static let captureMode = "obsidianCaptureMode"
        static let captureTimestamp = "obsidianCaptureTimestamp"
        static let captureHotkeyEnabled = "obsidianCaptureHotkeyEnabled"
        static let focusTrackingEnabled = "obsidianFocusTrackingEnabled"
        static let focusHeading = "obsidianFocusHeading"
        // Focus timers (pomodoro)
        static let timerPresets = "timerPresets"
        static let timerCountsUp = "timerCountsUp"
        static let timerAutoChain = "timerAutoChain"
        static let timerSoundEnabled = "timerSoundEnabled"
        // Tab visibility
        static let musicTabEnabled = "musicTabEnabled"
        static let spectrumTabEnabled = "spectrumTabEnabled"
        static let filesTabEnabled = "filesTabEnabled"
        static let captureTabEnabled = "captureTabEnabled"
        static let timerTabEnabled = "timerTabEnabled"
    }

    private let defaults: UserDefaults

    @Published var mediaSource: MediaSource {
        didSet { defaults.set(mediaSource.rawValue, forKey: Key.mediaSource) }
    }
    @Published var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }
    @Published var liveActivitiesEnabled: Bool {
        didSet { defaults.set(liveActivitiesEnabled, forKey: Key.liveActivitiesEnabled) }
    }
    /// The pill that names the new output device when the audio route changes.
    /// macOS shows its own connect banner for AirPods, so this one lands on top
    /// of Apple's — hence its own switch, separate from the other activities.
    @Published var audioRouteActivityEnabled: Bool {
        didSet { defaults.set(audioRouteActivityEnabled, forKey: Key.audioRouteActivityEnabled) }
    }
    @Published var hudEnabled: Bool {
        didSet { defaults.set(hudEnabled, forKey: Key.hudEnabled) }
    }
    /// Show volume (and brightness) changes *only* in the notch: Côte d'OS captures
    /// the hardware volume/brightness keys and adjusts the level itself so Apple's
    /// own OSD never appears. Brightness uses a private API and is only intercepted
    /// when available. Requires Accessibility; without it the notch HUD is additive.
    @Published var suppressSystemOSD: Bool {
        didSet { defaults.set(suppressSystemOSD, forKey: Key.suppressSystemOSD) }
    }
    /// Replace the collapsed pill's mini cover with a wider spectrum (more,
    /// longer bars) spanning the space the cover freed up. Pill only — the
    /// expanded music tab keeps its cover.
    @Published var pillSpectrumOnly: Bool {
        didSet { defaults.set(pillSpectrumOnly, forKey: Key.pillSpectrumOnly) }
    }
    /// How wide the spectrum-only pill's wave is, in points — the only knob.
    /// Bar width and gap are fixed (see `NotchLayout`), so widening this adds
    /// bars rather than re-spacing the ones already there, and the pill grows
    /// with the run. Replaced a width slider *and* a bar-count stepper, whose
    /// combinations mostly produced spacings nobody had looked at.
    @Published var pillSpectrumWidth: Double {
        didSet { defaults.set(pillSpectrumWidth, forKey: Key.pillSpectrumWidth) }
    }

    // MARK: Obsidian Quick Capture

    /// Bookmark to the vault root folder (plain bookmark; the app isn't sandboxed).
    @Published var vaultBookmark: Data? {
        didSet { defaults.set(vaultBookmark, forKey: Key.vaultBookmark) }
    }
    /// Vault name for `obsidian://` URLs (defaults to the folder name when empty).
    @Published var vaultName: String {
        didSet { defaults.set(vaultName, forKey: Key.vaultName) }
    }
    /// Daily-note folder relative to the vault root (Obsidian "Daily notes" setting).
    @Published var dailyFolder: String {
        didSet { defaults.set(dailyFolder, forKey: Key.dailyFolder) }
    }
    /// Daily-note filename date format (accepts Obsidian/moment `YYYY-MM-DD`).
    @Published var dailyFormat: String {
        didSet { defaults.set(dailyFormat, forKey: Key.dailyFormat) }
    }
    /// Markdown heading the capture bullet is inserted under.
    @Published var captureHeading: String {
        didSet { defaults.set(captureHeading, forKey: Key.captureHeading) }
    }
    @Published var captureMode: CaptureMode {
        didSet { defaults.set(captureMode.rawValue, forKey: Key.captureMode) }
    }
    /// Prefix each captured bullet with the current `HH:mm`.
    @Published var captureTimestamp: Bool {
        didSet { defaults.set(captureTimestamp, forKey: Key.captureTimestamp) }
    }
    /// Register the global capture hotkey (⌥⌘Space). No Accessibility permission needed.
    @Published var captureHotkeyEnabled: Bool {
        didSet { defaults.set(captureHotkeyEnabled, forKey: Key.captureHotkeyEnabled) }
    }
    /// Log completed/aborted focus-preset sessions to the daily note.
    @Published var focusTrackingEnabled: Bool {
        didSet { defaults.set(focusTrackingEnabled, forKey: Key.focusTrackingEnabled) }
    }
    /// Markdown heading the focus-session bullet is inserted under.
    @Published var focusHeading: String {
        didSet { defaults.set(focusHeading, forKey: Key.focusHeading) }
    }

    // MARK: Focus timers (pomodoro)

    /// Ordered list of named timers; the list order is also the auto-chain
    /// order (a completed timer starts the next one, wrapping around).
    @Published var timerPresets: [TimerPreset] {
        didSet { defaults.set(Self.encodePresets(timerPresets), forKey: Key.timerPresets) }
    }
    /// Count up (elapsed time) instead of down (remaining time). Display only —
    /// the session still ends when the preset duration is reached.
    @Published var timerCountsUp: Bool {
        didSet { defaults.set(timerCountsUp, forKey: Key.timerCountsUp) }
    }
    /// Auto-start the next preset in list order when a timer completes.
    @Published var timerAutoChain: Bool {
        didSet { defaults.set(timerAutoChain, forKey: Key.timerAutoChain) }
    }
    /// Play a completion sound when a timer runs out.
    @Published var timerSoundEnabled: Bool {
        didSet { defaults.set(timerSoundEnabled, forKey: Key.timerSoundEnabled) }
    }

    // MARK: Tab visibility

    /// Per-tab visibility switches. `NotchViewModel.enabledTabs` filters on
    /// these; the Settings UI keeps at least one of them on.
    @Published var musicTabEnabled: Bool {
        didSet { defaults.set(musicTabEnabled, forKey: Key.musicTabEnabled) }
    }
    @Published var spectrumTabEnabled: Bool {
        didSet { defaults.set(spectrumTabEnabled, forKey: Key.spectrumTabEnabled) }
    }
    @Published var filesTabEnabled: Bool {
        didSet { defaults.set(filesTabEnabled, forKey: Key.filesTabEnabled) }
    }
    @Published var captureTabEnabled: Bool {
        didSet { defaults.set(captureTabEnabled, forKey: Key.captureTabEnabled) }
    }
    @Published var timerTabEnabled: Bool {
        didSet { defaults.set(timerTabEnabled, forKey: Key.timerTabEnabled) }
    }

    func isTabEnabled(_ tab: NotchViewModel.Tab) -> Bool {
        switch tab {
        case .music: return musicTabEnabled
        case .spectrum: return spectrumTabEnabled
        case .files: return filesTabEnabled
        case .capture: return captureTabEnabled
        case .timer: return timerTabEnabled
        }
    }

    func setTab(_ tab: NotchViewModel.Tab, enabled: Bool) {
        switch tab {
        case .music: musicTabEnabled = enabled
        case .spectrum: spectrumTabEnabled = enabled
        case .files: filesTabEnabled = enabled
        case .capture: captureTabEnabled = enabled
        case .timer: timerTabEnabled = enabled
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.liveActivitiesEnabled: true,
            Key.audioRouteActivityEnabled: true,
            Key.hudEnabled: true,
            Key.suppressSystemOSD: true,
            Key.dailyFolder: "01-daily",
            Key.dailyFormat: "yyyy-MM-dd",
            Key.captureHeading: "## 📥 Capture",
            Key.captureTimestamp: true,
            Key.captureHotkeyEnabled: false,
            Key.focusTrackingEnabled: true,
            Key.focusHeading: "## ⏱️ Fokuszeit",
            Key.timerCountsUp: false,
            Key.timerAutoChain: false,
            Key.timerSoundEnabled: true,
            Key.musicTabEnabled: true,
            Key.spectrumTabEnabled: true,
            Key.filesTabEnabled: true,
            Key.captureTabEnabled: true,
            Key.timerTabEnabled: true,
            Key.pillSpectrumOnly: false,
            Key.pillSpectrumWidth: NotchLayout.pillSpectrumDefaultWidth,
        ])
        self.mediaSource = MediaSource(rawValue: defaults.string(forKey: Key.mediaSource) ?? "") ?? .auto
        self.appearance = Appearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
        self.liveActivitiesEnabled = defaults.bool(forKey: Key.liveActivitiesEnabled)
        self.audioRouteActivityEnabled = defaults.bool(forKey: Key.audioRouteActivityEnabled)
        self.hudEnabled = defaults.bool(forKey: Key.hudEnabled)
        self.suppressSystemOSD = defaults.bool(forKey: Key.suppressSystemOSD)
        self.pillSpectrumOnly = defaults.bool(forKey: Key.pillSpectrumOnly)
        // The width used to mean "spread N bars across this much room", with N
        // set separately. It now means "this much room, filled with bars at a
        // fixed pitch" — a stored value from the old scheme would land on an
        // arbitrary bar count, so an install carrying the retired key starts
        // over at the default instead.
        if defaults.object(forKey: Key.legacyPillSpectrumBarCount) != nil {
            defaults.removeObject(forKey: Key.legacyPillSpectrumBarCount)
            defaults.set(NotchLayout.pillSpectrumDefaultWidth, forKey: Key.pillSpectrumWidth)
        }
        self.pillSpectrumWidth = max(NotchLayout.pillSpectrumMinWidth,
                                     min(NotchLayout.pillSpectrumMaxWidth,
                                         defaults.double(forKey: Key.pillSpectrumWidth)))
        self.vaultBookmark = defaults.data(forKey: Key.vaultBookmark)
        self.vaultName = defaults.string(forKey: Key.vaultName) ?? ""
        self.dailyFolder = defaults.string(forKey: Key.dailyFolder) ?? "01-daily"
        self.dailyFormat = defaults.string(forKey: Key.dailyFormat) ?? "yyyy-MM-dd"
        self.captureHeading = defaults.string(forKey: Key.captureHeading) ?? "## 📥 Capture"
        self.captureMode = CaptureMode(rawValue: defaults.string(forKey: Key.captureMode) ?? "") ?? .silentAppend
        self.captureTimestamp = defaults.bool(forKey: Key.captureTimestamp)
        self.captureHotkeyEnabled = defaults.bool(forKey: Key.captureHotkeyEnabled)
        self.focusTrackingEnabled = defaults.bool(forKey: Key.focusTrackingEnabled)
        self.focusHeading = defaults.string(forKey: Key.focusHeading) ?? "## ⏱️ Fokuszeit"
        self.timerPresets = Self.decodePresets(defaults.data(forKey: Key.timerPresets)) ?? TimerPreset.defaults
        self.timerCountsUp = defaults.bool(forKey: Key.timerCountsUp)
        self.timerAutoChain = defaults.bool(forKey: Key.timerAutoChain)
        self.timerSoundEnabled = defaults.bool(forKey: Key.timerSoundEnabled)
        self.musicTabEnabled = defaults.bool(forKey: Key.musicTabEnabled)
        self.spectrumTabEnabled = defaults.bool(forKey: Key.spectrumTabEnabled)
        self.filesTabEnabled = defaults.bool(forKey: Key.filesTabEnabled)
        self.captureTabEnabled = defaults.bool(forKey: Key.captureTabEnabled)
        self.timerTabEnabled = defaults.bool(forKey: Key.timerTabEnabled)
        // The Claude tab is gone, and an install that had it as its *only*
        // enabled tab would come back with nothing to show: the tab row is
        // built from the enabled set, so it renders empty, while the pill
        // falls back to a tab the user switched off. The "you can't disable
        // the last one" guard in Settings can't help — it only ever saw five
        // tabs. Nothing in the app recovers from that, so hand the music tab
        // back instead.
        if !musicTabEnabled && !spectrumTabEnabled && !filesTabEnabled
            && !captureTabEnabled && !timerTabEnabled {
            self.musicTabEnabled = true
        }
    }

    private static func encodePresets(_ presets: [TimerPreset]) -> Data? {
        try? JSONEncoder().encode(presets)
    }

    private static func decodePresets(_ data: Data?) -> [TimerPreset]? {
        guard let data else { return nil }
        return try? JSONDecoder().decode([TimerPreset].self, from: data)
    }
}
