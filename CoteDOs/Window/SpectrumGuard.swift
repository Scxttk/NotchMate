import AppKit
import Combine
import CoreGraphics
import SwiftUI

/// Watches over a takeover that was put up to *guard* the Mac — ⌥⌘S, pressed
/// on the way out of the room — and ends it when there is a reason to.
///
/// An armed takeover ends the way a screensaver ends: into the lock screen.
/// Whatever takes it down — a keystroke, the cursor moving, Esc, the swipe, or
/// the music running out while nobody is there — the Mac locks behind it. The
/// takeover holds a display-sleep assertion for as long as it is up (see
/// `SpectrumFullscreenController`), so it stands *in front of* the display
/// sleeping rather than after it, and the lock is the half of that behaviour it
/// has to give back.
///
/// Only armed takeovers are watched. The one a tap on the spectrum page puts up
/// happens while you sit in front of it; that is something to look at, and it
/// stays until its own gesture or Esc takes it down.
final class SpectrumGuard {

    /// Why an armed takeover ended, and when. Kept until the Mac is unlocked
    /// again and then shown in the pill: the lock screen you come back to looks
    /// the same whether you ended the guard yourself, somebody else touched the
    /// Mac, or the music simply ran out — and the *time* is what tells those
    /// apart. "Eingabe 14:02" on a Mac you left at 13:50 is somebody else.
    struct EndReport: Equatable {
        enum Cause: Equatable { case input, silence }
        let cause: Cause
        let at: Date
    }

    private let spectrum: SpectrumAnalyzer
    private weak var activities: ActivityManager?
    private let state = SpectrumFullscreen.shared
    private var timer: Timer?
    /// Since when the tap has heard nothing. The takeover survives a gap
    /// between tracks; it doesn't survive the music being over.
    private var silentSince: Date?
    /// Whether there was anything audible when the takeover went up. Only those
    /// are given up when the room goes quiet — ⌥⌘S pressed in a silent room is
    /// exactly as wanted as one pressed over Spotify, and must not lock the Mac
    /// ninety seconds later on its own.
    private var startedWithAudio = false
    /// Whether the takeover currently up is guarding the Mac (see
    /// `SpectrumFullscreen.isArmed`). Copied when it appears rather than read
    /// on demand, because it has to survive being read *after* the takeover is
    /// already gone — that is the moment the lock is owed.
    private var armed = false
    /// Whether the Mac has been left alone at least once since the takeover
    /// appeared. Until then input is ignored: arming with ⌥⌘S is itself a
    /// keystroke, and a hand still resting on the trackpad would otherwise end
    /// the takeover — and lock the Mac — half a second after it arrived.
    private var handsOff = false
    /// Why the takeover is being taken down, set just before asking for the
    /// dismissal — the lock and the report both hang off `isPresented` going
    /// false, which by then no longer knows what caused it.
    private var pendingCause: EndReport.Cause?
    /// Waiting to be shown once the Mac is unlocked. There is no point
    /// presenting a pill nobody can see behind the lock screen.
    private var unreportedEnd: EndReport?
    private var cancellables: Set<AnyCancellable> = []
    private var unlockObserver: NSObjectProtocol?

    /// Fresh input has to be at most this old to count as "the user is back".
    /// Not zero: the poll itself lands somewhere inside the second.
    static let inputResetSeconds: TimeInterval = 2
    /// Silence tolerated before the takeover gives up — long enough to cover
    /// track changes, an ad break, or a paused video someone comes back to.
    static let silenceGraceSeconds: TimeInterval = 90
    /// Only polled while a takeover is up, and fast, so it gets out of the way
    /// promptly once the user is back. There is nothing to watch for otherwise.
    private static let presentedInterval: TimeInterval = 0.5

    init(spectrum: SpectrumAnalyzer, activities: ActivityManager? = nil) {
        self.spectrum = spectrum
        self.activities = activities
    }

    func start() {
        // Locking hangs off the takeover actually being gone, not off the
        // reason it went: Esc and the swipe-up gesture are handled inside the
        // takeover itself and never come through `tick()`, and they are input
        // like any other. Fires at `finishDismissal`, so the shrink animation
        // plays out first and the lock screen lands on an empty desktop.
        //
        // `@Published` hands the current value to a new subscriber, so this
        // also settles the timer on a `start()` after wake. Landing on the
        // false branch there is harmless: `armed` is false until a takeover of
        // this run's own has been seen, and the lock is guarded on it.
        state.$isPresented
            .removeDuplicates()
            .sink { [weak self] presented in
                guard let self else { return }
                if presented {
                    self.armed = self.state.isArmed
                    self.startedWithAudio = self.spectrum.hasSignal
                    self.handsOff = false
                    self.silentSince = nil
                    self.schedule()
                    return
                }
                let wasArmed = self.armed
                let cause = self.pendingCause
                self.armed = false
                self.startedWithAudio = false
                self.handsOff = false
                self.silentSince = nil
                self.pendingCause = nil
                self.timer?.invalidate()
                self.timer = nil
                guard wasArmed else { return }
                // Esc and the swipe are input as much as a keystroke is; only
                // the silence rule names itself, so anything unlabelled is
                // somebody having touched the Mac.
                self.unreportedEnd = EndReport(cause: cause ?? .input, at: Date())
                ScreenLock.lockNow()
            }
            .store(in: &cancellables)

        unlockObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.reportEnd()
        }
        // The unlock may already have happened — the guard is torn down with
        // the screen and rebuilt on wake, and on some wakes that lands after
        // the notification has been and gone.
        reportEnd()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        cancellables.removeAll()
        if let unlockObserver {
            DistributedNotificationCenter.default().removeObserver(unlockObserver)
        }
        unlockObserver = nil
        silentSince = nil
        startedWithAudio = false
        armed = false
        handsOff = false
    }

    deinit { stop() }

    private func schedule() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.presentedInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    // MARK: Decisions

    private func tick() {
        // A takeover nobody armed is just something to look at: it stays until
        // its own gesture or Esc takes it down.
        guard state.isPresented, armed else { return }
        let idle = Self.idleSeconds()
        if idle >= Self.inputResetSeconds { handsOff = true }
        guard let cause = Self.endCause(handsOff: handsOff,
                                        idle: idle,
                                        startedWithAudio: startedWithAudio,
                                        silentFor: silentFor())
        else { return }
        // The lock rides on `isPresented` going false (see `start()`), so this
        // only has to ask for the dismissal.
        pendingCause = cause
        state.dismiss()
    }

    /// The pure half, so the rules can be read without a Mac's idle clock and a
    /// running audio tap underneath them. `nil` means: leave it up.
    static func endCause(handsOff: Bool,
                         idle: TimeInterval,
                         startedWithAudio: Bool,
                         silentFor: TimeInterval?) -> EndReport.Cause? {
        // Somebody is here — that outranks anything the music is doing.
        if handsOff, idle < inputResetSeconds { return .input }
        guard startedWithAudio, let silentFor, silentFor >= silenceGraceSeconds else { return nil }
        return .silence
    }

    /// How long the tap has been silent, or `nil` while it hears something.
    /// Tracked here rather than read as an instant "is it quiet right now", so
    /// the takeover isn't torn down by the two seconds between two songs.
    private func silentFor() -> TimeInterval? {
        guard !spectrum.hasSignal else {
            silentSince = nil
            return nil
        }
        guard let since = silentSince else {
            silentSince = Date()
            return 0
        }
        return Date().timeIntervalSince(since)
    }

    /// Show what ended the guard, once there is somebody in front of an
    /// unlocked Mac to see it. The clock time is the point of the whole thing —
    /// "Eingabe" alone says nothing, "Eingabe 14:02" on a Mac left at 13:50
    /// says somebody was here.
    private func reportEnd() {
        guard let report = unreportedEnd, !Self.screenIsLocked() else { return }
        unreportedEnd = nil
        let clock = Self.clockFormatter.string(from: report.at)
        let title: String
        let icon: String
        let tint: Color
        switch report.cause {
        case .input:
            title = String(localized: "activity.guardEnded.input", defaultValue: "Eingabe \(clock)")
            icon = "hand.tap.fill"
            tint = .orange
        case .silence:
            title = String(localized: "activity.guardEnded.silence", defaultValue: "Ton aus \(clock)")
            icon = "speaker.slash.fill"
            tint = .white
        }
        activities?.present(NotchActivity(
            kind: .fileReceived,    // generic "something happened" slot
            priority: 4,
            icon: icon,
            tint: tint,
            title: title,
            autoDismiss: 6
        ))
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    // MARK: System state

    /// Seconds since the last human input anywhere on the system — keyboard,
    /// mouse, trackpad. `combinedSessionState` so input to *other* apps counts
    /// too; this app is usually not the one being typed into.
    static func idleSeconds() -> TimeInterval {
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    /// Nothing should be put on top of the lock screen.
    static func screenIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Int) == 1
    }
}
