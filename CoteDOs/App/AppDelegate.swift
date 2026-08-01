import AppKit
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: NotchWindowController?
    private var statusBarController: StatusBarController?
    /// Owns the fullscreen-spectrum window. Created at launch but idle until
    /// something asks for the takeover (a tap on the spectrum page, or ⌥⌘S).
    private var spectrumFullscreen: SpectrumFullscreenController?
    /// Watches over a takeover that was put up to guard the Mac (⌥⌘S) and locks
    /// the machine behind it when it ends.
    private var spectrumGuard: SpectrumGuard?

    let viewModel = NotchViewModel()
    let nowPlaying = NowPlayingManager()
    let shelf = FileShelfModel()
    let activities = ActivityManager()
    let systemHUD = SystemHUD()
    /// Shared audio-spectrum tap. Long-lived (not owned by the music tab) so the
    /// collapsed pill's wave can show the real spectrum too; its lifecycle is
    /// driven centrally in `NotchRootView` off screen state alone — it runs
    /// whenever the screen is awake, and `spectrum.hasSignal` (derived from the
    /// tapped audio itself) reports whether anything is actually audible.
    /// 32 bands so the widest renderer (the spectrum-only pill at its maximum
    /// bar count) keeps one band per bar; the narrower waves bucket down via
    /// `WaveBarsView.fitted()`. Band mapping cost is O(FFT bins) regardless
    /// of band count.
    let spectrum = SpectrumAnalyzer(bandCount: 32)
    lazy var capture = ObsidianCapture(activities: activities)
    lazy var pomodoro = PomodoroManager(activities: activities)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // As the unit tests' host app, do nothing: the real startup builds the
        // notch panel, taps system audio and grabs hardware keys — on a CI
        // runner the audio tap's consent prompt has nobody to click it, and
        // the test runner then "never began executing tests".
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }

        // Accessory app: no Dock icon, lives in the menu bar / notch.
        NSApp.setActivationPolicy(.accessory)
        applyAppearance(UserSettings.shared.appearance)

        // Turns the analyzer's source bundle ID into the icon and accent the
        // waves tint themselves with. Read as a singleton from the view bodies,
        // so it only needs pointing at the analyzer once.
        SourceAppAccent.shared.follow(spectrum)

        let controller = NotchWindowController(viewModel: viewModel, nowPlaying: nowPlaying, shelf: shelf, activities: activities, pomodoro: pomodoro, capture: capture, spectrum: spectrum)
        controller.show()
        windowController = controller

        statusBarController = StatusBarController()

        enableLaunchAtLogin()

        capture.onHotKey = { [weak self] in self?.windowController?.presentCapture() }
        capture.start()

        spectrumFullscreen = SpectrumFullscreenController(spectrum: spectrum, nowPlaying: nowPlaying)
        // ⌥⌘S toggles the fullscreen spectrum from anywhere, so it can be put up
        // (and taken down) without going through the island first. Armed: the
        // hotkey is how you leave the Mac on purpose, so whatever ends the
        // takeover — you coming back, or somebody else touching it — locks the
        // machine, and you can tell which happened by what you find on return.
        // It is the only way in: nothing arms a takeover by itself.
        HotKeyCenter.shared.register(.spectrumFullscreen) {
            SpectrumFullscreen.shared.toggle(armed: true)
        }
        let spectrumGuard = SpectrumGuard(spectrum: spectrum, activities: activities)
        spectrumGuard.start()
        self.spectrumGuard = spectrumGuard

        nowPlaying.start()
        activities.start()
        systemHUD.start(presenting: activities)

        // Keep the thumbnail cache from growing without bound across launches.
        DispatchQueue.global(qos: .utility).async {
            Persistence.pruneThumbnailCache()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(resetData),
            name: .notchMateResetData,
            object: nil
        )
        registerSleepWakeObservers()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Quitting while the takeover is guarding the Mac must not be a way out
        // of it: whatever route got here (the menu bar's Quit, a `kill`), the
        // machine locks on the way down, exactly as it would have if the
        // takeover had been dismissed. `SIGKILL` is beyond reach — nothing in
        // userland survives that — but every ordinary quit is covered.
        if SpectrumFullscreen.shared.isPresented, SpectrumFullscreen.shared.isArmed {
            ScreenLock.lockNow()
        }
        nowPlaying.stop()
        activities.stop()
        systemHUD.stop()
        spectrum.stop()
        capture.stop()
        spectrumGuard?.stop()
        // Session state is already persisted on every transition; just disarm
        // the 1s tick. The wall-clock session resumes on the next launch.
        pomodoro.suspendTicking()
    }

    // MARK: - Sleep/Wake

    /// Tear down every live listener/monitor when the machine sleeps and rebuild
    /// them on wake. Without this the 1s now-playing timer, the CoreAudio/IOKit
    /// listeners and the global hover monitors stay armed through sleep — the
    /// crash/drain class reported against every competing notch app.
    private func registerSleepWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(systemWillSleep),
                           name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(systemDidWake),
                           name: NSWorkspace.didWakeNotification, object: nil)
        // Screen sleep is *not* system sleep: the machine stays awake, so our
        // timers/observers keep running. Pause the per-second now-playing work and
        // the visualizer while the display is off — nobody can see it, and a
        // free-running 30fps visualizer is the documented idle-drain of these apps.
        center.addObserver(self, selector: #selector(screensDidSleep),
                           name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(screensDidWake),
                           name: NSWorkspace.screensDidWakeNotification, object: nil)
    }

    @objc private func systemWillSleep() {
        nowPlaying.stop()
        activities.stop()
        systemHUD.stop()
        spectrum.stop()
        pomodoro.suspendTicking()
        windowController?.suspendMonitors()
        spectrumGuard?.stop()
    }

    @objc private func systemDidWake() {
        nowPlaying.start()
        activities.start()
        systemHUD.start(presenting: activities)
        pomodoro.resumeTicking()
        windowController?.resumeMonitors()
        spectrumGuard?.start()
    }

    @objc private func screensDidSleep() {
        nowPlaying.setScreensAwake(false)
        pomodoro.setScreensAwake(false)
        // The display went dark, so no takeover of ours is up holding it awake:
        // there is nothing to guard until the screen comes back.
        spectrumGuard?.stop()
        // The AX polls (Safari fullscreen, menu-bar overlap) answer questions
        // about a display nobody can see — stop them with the screen, not
        // just with system sleep.
        windowController?.suspendMonitors()
    }

    @objc private func screensDidWake() {
        nowPlaying.setScreensAwake(true)
        pomodoro.setScreensAwake(true)
        windowController?.resumeMonitors()
        spectrumGuard?.start()
    }

    @objc private func screenParametersChanged() {
        windowController?.reposition()
    }

    @objc private func resetData() {
        shelf.clear()
        pomodoro.clear()
    }

    /// Register Côte d'OS as a login item so it starts automatically at every login.
    private func enableLaunchAtLogin() {
        guard SMAppService.mainApp.status != .enabled else { return }
        do {
            try SMAppService.mainApp.register()
        } catch {
            NSLog("CoteDOs: could not enable launch at login: \(error)")
        }
    }
}
