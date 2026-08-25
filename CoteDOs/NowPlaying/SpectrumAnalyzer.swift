import Accelerate
import AudioToolbox
import Combine
import CoreAudio
import Foundation
import QuartzCore

/// The band levels, deliberately split off `SpectrumAnalyzer` into their own
/// observable object.
///
/// They change 30×/s; every other property the analyzer publishes changes a
/// few times a minute at most. With all of it on one object, a band update
/// invalidated *every* view that observes the analyzer — which reaches up to
/// `NotchRootView`, so AppKit re-laid out the entire hosting view 30×/s for a
/// wave the size of a thumbnail (`sample` showed `NSHostingView.layout` under
/// the display cycle as the main thread's biggest item). Views that draw the
/// bars observe this; views that only need `hasSignal`/`isLive`/`sourceBundleID`
/// observe the analyzer and hold still while the wave moves.
final class SpectrumBands: ObservableObject {
    /// Normalised per-band magnitudes (0…1), published on the main thread.
    @Published fileprivate(set) var values: [CGFloat]

    fileprivate init(count: Int) {
        values = Array(repeating: 0, count: count)
    }

    #if DEBUG
    /// Frozen levels for the snapshot harness — the stage view is only worth
    /// looking at with a real spectrum shape in it. Lives here because the
    /// setter is deliberately closed to everything but the analyzer.
    static func forTesting(_ values: [CGFloat]) -> SpectrumBands {
        let bands = SpectrumBands(count: values.count)
        bands.values = values
        return bands
    }
    #endif
}

/// Real-time frequency visualizer data. Taps the system audio output with a
/// CoreAudio process tap (macOS 14.4+, needs the audio-recording permission),
/// runs an FFT over it and exposes a handful of log-spaced frequency bands so
/// the now-playing wave reacts to the actual song. On older systems, or if the
/// permission is denied / the tap fails, `bands` stays flat and the visualizer
/// falls back to its procedural animation.
final class SpectrumAnalyzer: ObservableObject {
    /// Live band levels. Their own observable, not a `@Published` property
    /// here — see `SpectrumBands` for why.
    let bands: SpectrumBands
    /// True once a tap is actually running and feeding real data.
    @Published private(set) var isLive = false
    /// True while the tapped signal actually carries audible content — not just
    /// whether the tap is running. This is what drives "is something playing"
    /// for sources with no scriptable now-playing state (browser video, calls,
    /// system sounds, …): CoreAudio's own per-process "is running output" API
    /// turned out to be unreliable in practice (some helper processes report it
    /// permanently true; short-lived ones can flip true and false again before
    /// a listener callback ever fires), so this reads the real signal the tap
    /// already has instead of trusting that heuristic. Held true for a couple
    /// of seconds after the signal drops so brief gaps (between songs, a pause
    /// in speech) don't flicker the hero pill.
    @Published private(set) var hasSignal = false
    private var lastSignalTime: CFTimeInterval = 0
    private static let signalHoldSeconds: CFTimeInterval = 2.0
    private static let signalThreshold: Float = 0.08

    /// Bundle ID of whichever app currently has an active output stream, so the
    /// collapsed pill can show its icon instead of a generic glyph when there's
    /// no scriptable track. Refreshed on a plain 1s poll (not a CoreAudio
    /// property listener) while the tap is running — a poll is simpler and, for
    /// this cosmetic purpose, more than fast enough; see `hasSignal`'s doc for
    /// why the listener-based equivalent proved unreliable for the on/off signal.
    @Published private(set) var sourceBundleID: String?
    private var sourceCheckTimer: DispatchSourceTimer?
    /// The process objects the current tap was built for. A tap is bound to the
    /// processes it was created with, so when a different app starts playing the
    /// tap has to be rebuilt or the wave would keep drawing the old app's audio
    /// — or nothing, once that app quits.
    private var tappedProcesses: [AudioObjectID] = []

    let bandCount: Int

    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var running = false
    private var sampleRate: Double = 48_000

    // Rebuilds the tap when the user switches output device (e.g. AirPods
    // in/out): the aggregate can otherwise keep feeding silent samples forever.
    private var deviceChangeListener: AudioPropertyListener?
    private var pendingRebuild: DispatchWorkItem?
    private var deviceChangeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    // FFT scratch (all preallocated — nothing is allocated on the audio thread).
    /// 2048, because 32 log-spaced bands need bins finer than 46.9 Hz: at that
    /// width the bottom half-dozen bands all land on the same two bins and move
    /// as twins. 23.4 Hz keeps them distinct, and the FFT is still cheap on any
    /// Apple-Silicon Mac.
    private let fftSize = 2_048
    private let log2n: vDSP_Length
    private var fftSetup: FFTSetup?
    private var window: [Float]
    private var sampleBuffer: [Float]      // sliding window of the last fftSize mono samples
    private var windowed: [Float]
    private var realp: [Float]
    private var imagp: [Float]
    private var magnitudes: [Float]
    private var smoothed: [Float]          // per-band, with attack/decay
    private var lastPublish = 0.0
    // The dB window floats, because no fixed one can work: measuring real
    // playback showed two ordinary tracks differing by ~20 dB in absolute
    // loudness (mastering level, not "quiet vs busy" within a song). A fixed
    // range either clips the loud track to the ceiling within a second or
    // never lets the quiet one clear the floor. Three attempts at picking a
    // good fixed range is how long that took to accept.
    // `loudnessCeilDb` tracks the loudest thing currently
    // playing (fast attack, slow release — like a VU meter's peak hold) and
    // the dB→0…1 mapping always uses a fixed-width slice directly below it,
    // so each track's own dynamic range gets used regardless of its overall
    // loudness.
    private var loudnessCeilDb: Float = 40   // seeded, not zero, so the first second isn't blank
    private static let loudnessAttack: Float = 0.5        // fraction of the way to a new peak, per callback
    private static let loudnessReleasePerSecond: Float = 6 // dB/s the ceiling falls once the signal quiets down
    private static let loudnessCeilMin: Float = 10          // never let a silent stretch collapse the window
    private static let windowWidthDb: Float = 26
    // Higher bands carry ~20 dB less energy than the bass; lift them (curved so
    // the low bands stay put) to keep every bar in the same visible range.
    private static let highBandBoost: Float = 20

    // Beat emphasis. The absolute window above answers "how loud is this band
    // right now" — which for heavily compressed, loudness-normalized music
    // (Spotify pins everything near -14 LUFS and modern masters have a few dB
    // of short-term movement at best) means the bars find their static
    // positions and just stand there, while dynamic material (a YouTube video,
    // speech) dances. So each band also tracks its own recent average, and the
    // published level leans mostly on the *deviation* from that average: a
    // kick 6 dB over its band's norm hits the top no matter how compressed
    // the master is, and the absolute term underneath keeps bass reading
    // taller than treble.
    private var averageDb: [Float]
    private var averageSeeded = false
    /// Seconds for a band's running average to absorb a level change.
    private static let averageTau: Float = 1.6
    /// Where "exactly average" sits (offset/range ≈ 0.39) and how many dB a
    /// beat needs above its band's norm to reach the top. Voice gets its
    /// drama for free — pauses swing every band from zero to full — while
    /// music holds energy continuously, so between beats a band sits exactly
    /// at its average: this resting point *is* the trough depth. Kept low and
    /// the window narrow so sustained music still breathes visibly.
    private static let beatOffsetDb: Float = 3.5
    private static let beatRangeDb: Float = 9
    /// Mix of deviation-from-average vs absolute level in the published bar.
    private static let beatWeight: Float = 0.72

    // Dormancy: the tap keeps delivering callbacks during silence — most of
    // the day, for most people — and running a 2048-point FFT ~46× a second
    // against digital zeroes is exactly the "erhöhter Energieverbrauch"
    // Battery settings pins on the app. A cheap peak scan gates the FFT: after
    // a couple of silent seconds the analysis sleeps and each callback costs
    // one buffer scan; the first non-silent sample wakes it instantly.
    private var silentSeconds: Float = 0
    private var isDormant = false
    private static let dormancyAfterSeconds: Float = 2
    private static let dormancyPeakGate: Float = 1e-4

    // Suspension: dormancy makes silent callbacks cheap, but the tap itself is
    // not free even then — while it exists it streams zeroes through the HAL
    // all day. After prolonged silence the whole tap is torn down, and the
    // source-check timer becomes a cheap resume probe (see `sourceTimerFired`).
    //
    // The tap is only given up when the machine is *genuinely* quiet: silent
    // **and** with no other process holding an output stream. That condition
    // matters more than it looks. Suspending merely because nothing is audible
    // meant a paused player — the overwhelmingly common state — left the wave
    // asleep, and waking it depended on either the player poll (20 s while
    // idle) or a probe that backed off to 30 s. The spectrum then took half a
    // minute to notice music had started, which reads as simply broken.
    // Keeping the tap while an audio app is open costs a dormant callback
    // whose FFT is already gated off, and buys an instant wave.
    private var desired = false            // start() called and not stop()ed
    private var suspended = false          // tap torn down after silence
    private static let suspendAfterSeconds: Float = 30
    /// How often the probe looks for a process producing output again.
    private static let probeIntervalSeconds: Double = 2

    private let queue = DispatchQueue(label: "com.scott.notchmate.spectrum", qos: .userInitiated)

    /// Lifecycle tracing. The tap's state is otherwise invisible from outside
    /// the process — a private aggregate device does not show up in the device
    /// list, and coreaudiod's sleep assertion tracks *audio flowing*, not
    /// whether our tap exists, so both of the obvious external checks answer a
    /// different question than the one being asked. Run a Debug build from a
    /// terminal to see the transitions.
    private func trace(_ message: @autoclosure () -> String) {
        #if DEBUG
        // stderr, not `print`: stdout redirected to a file is block-buffered, so
        // a traced run that is killed rather than exited loses everything it had
        // to say — which is exactly the run you are tracing.
        fputs("[spectrum] \(message())\n", stderr)
        #endif
    }

    init(bandCount: Int = 6) {
        self.bandCount = bandCount
        self.bands = SpectrumBands(count: bandCount)
        self.log2n = vDSP_Length(log2(Float(fftSize)))
        self.window = [Float](repeating: 0, count: fftSize)
        self.sampleBuffer = [Float](repeating: 0, count: fftSize)
        self.windowed = [Float](repeating: 0, count: fftSize)
        self.realp = [Float](repeating: 0, count: fftSize / 2)
        self.imagp = [Float](repeating: 0, count: fftSize / 2)
        self.magnitudes = [Float](repeating: 0, count: fftSize / 2)
        self.smoothed = [Float](repeating: 0, count: bandCount)
        self.averageDb = [Float](repeating: 0, count: bandCount)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
    }

    deinit {
        // Tear down CoreAudio synchronously only — no DispatchQueue.main.async
        // here: capturing `self` from deinit resurrects a deallocating object
        // and traps (that was the SIGABRT).
        teardown()
        unregisterDeviceChangeListener()
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    // MARK: - Lifecycle

    func start() {
        guard !desired else { return }
        desired = true
        buildTap()
    }

    /// Actually creates the tap + aggregate and starts IO. Split off `start()`
    /// so the silence suspension can rebuild the tap without touching the
    /// user-level started/stopped state.
    private func buildTap() {
        guard !running else { return }
        suspended = false
        silentSeconds = 0
        guard #available(macOS 14.4, *) else { return }   // process taps are 14.4+

        // 1. A private tap of exactly the processes currently making sound —
        //    not a global tap of the system output.
        //
        //    The difference is not cosmetic. A global tap attaches to the output
        //    *device*, and with AirPods Pro that put them into their microphone
        //    mode: macOS reported "CoteDOs — Mikrofon" and the stem stopped
        //    skipping tracks, because a press was being read as mute rather than
        //    transport. Tapping the playing processes instead never touches the
        //    device. The app already scans for those processes every second for
        //    the pill's source icon, so this costs nothing new.
        //
        //    Nothing playing means nothing to tap: leave the tap unbuilt and let
        //    the source poll bring it back, which is the same path a silence
        //    suspension already uses.
        let processes = foreignOutputProcesses().map(\.id)
        guard !processes.isEmpty else {
            suspended = true
            // `startSourceCheckTimer`, not `reschedule`: on a cold launch into
            // silence the timer does not exist yet, and rescheduling nothing
            // would leave the analyzer with no probe and therefore no way back.
            startSourceCheckTimer()
            return
        }
        tappedProcesses = processes
        let desc = CATapDescription(stereoMixdownOfProcesses: processes)
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var tap: AudioObjectID = 0
        guard AudioHardwareCreateProcessTap(desc, &tap) == noErr, tap != 0 else { buildFailed(); return }
        tapID = tap

        guard let tapUID = stringProperty(tapID, kAudioTapPropertyUID) else { buildFailed(); return }
        sampleRate = tapFormat(tapID)?.mSampleRate ?? 48_000

        // 2. A private aggregate device that contains the tap, so we can install
        //    an IOProc and receive the tapped audio.
        let aggUID = UUID().uuidString
        let sub: [String: Any] = [
            kAudioSubTapUIDKey: tapUID,
            kAudioSubTapDriftCompensationKey: true,
        ]
        let aggDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Côte d'OS Spectrum",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [sub],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]
        var agg: AudioObjectID = 0
        guard AudioHardwareCreateAggregateDevice(aggDescription as CFDictionary, &agg) == noErr, agg != 0 else {
            buildFailed(); return
        }
        aggregateID = agg

        // 3. Receive audio on our own queue and analyse it.
        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, queue) { [weak self] _, inInputData, _, _, _ in
            self?.process(inInputData)
        }
        guard status == noErr, let proc else { buildFailed(); return }
        ioProcID = proc
        guard AudioDeviceStart(aggregateID, proc) == noErr else { buildFailed(); return }

        running = true
        // Cleared here rather than on entry: resetting before the attempt would
        // let a permanently failing build sit at one retry forever.
        failedBuilds = 0
        registerDeviceChangeListener()
        startSourceCheckTimer()
        trace("tap built")
        DispatchQueue.main.async { self.isLive = true }
    }

    /// A failed tap build must *not* kill the analyzer the way `stop()` does.
    /// `stop()` clears the user-level `desired` flag, so routing a build failure
    /// through it means one transient HAL error during a suspend/resume cycle
    /// silently disables the spectrum until the next screen wake — every later
    /// probe and `pokeResume()` then bails on `guard desired`. Spotify keeps its
    /// output stream open while paused, so those cycles happen all day.
    ///
    /// So: clean up whatever half-built objects exist, fall back to the suspended
    /// state, and let the probe try again.
    private func buildFailed() {
        trace("tap build FAILED — falling back to probing")
        teardown()
        suspended = true
        // A build that keeps failing (no permission, say) while some app holds
        // an output stream would otherwise retry every probe tick forever. Back
        // off instead; a real signal is not what is missing here.
        failedBuilds += 1
        startSourceCheckTimer()
    }

    /// Consecutive failed tap builds, which stretch the probe interval.
    private var failedBuilds = 0

    func stop() {
        // `suspended` counts as running for the reset below: the tap is gone
        // but `isLive` stayed true through the suspension.
        let wasRunning = aggregateID != 0 || tapID != 0 || suspended
        desired = false
        suspended = false
        pendingRebuild?.cancel()
        pendingRebuild = nil
        teardown()
        unregisterDeviceChangeListener()
        stopSourceCheckTimer()
        guard wasRunning else { return }
        // Reset published state on the main thread — weak so a pending block can
        // never resurrect a deallocating instance.
        lastSignalTime = 0
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isLive = false
            self.hasSignal = false
            self.sourceBundleID = nil
            self.bands.values = Array(repeating: 0, count: self.bandCount)
        }
    }

    /// Synchronous CoreAudio teardown, safe to call from `deinit`.
    private func teardown() {
        running = false
        tappedProcesses = []
        if aggregateID != 0, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = 0 }
        // The tap only ever gets created on 14.4+ (see start), so this is only
        // reachable there; the guard is just for the compiler.
        if tapID != 0, #available(macOS 14.2, *) {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = 0
        for i in smoothed.indices { smoothed[i] = 0 }
    }

    // MARK: - Device change handling

    private func registerDeviceChangeListener() {
        guard deviceChangeListener == nil else { return }
        let listener = AudioPropertyListener(
            object: AudioObjectID(kAudioObjectSystemObject), address: deviceChangeAddress
        ) { [weak self] in self?.rebuildForDeviceChange() }
        listener.start()
        deviceChangeListener = listener
    }

    private func unregisterDeviceChangeListener() {
        deviceChangeListener?.stop()
        deviceChangeListener = nil
    }

    /// The default output device changed (e.g. AirPods connected/disconnected).
    /// The existing aggregate can silently keep feeding zero samples, so this
    /// does a full teardown + rebuild of the tap and aggregate rather than just
    /// restarting the IOProc.
    ///
    /// The listener fires on `queue` — the same queue the IOProc dispatches to.
    /// Tearing the IOProc down from its own queue deadlocks the HAL
    /// (`AudioDeviceDestroyIOProcID` waits synchronously for in-flight IO
    /// blocks), so hop to the main thread, where `start`/`stop` already run.
    /// A device switch also fires the notification several times in a burst
    /// while routing settles, so debounce before rebuilding.
    private func rebuildForDeviceChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingRebuild?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.running else { return }
                self.teardown()
                // `buildTap`, not `start`: `start` guards on `desired`, which is
                // still true here, so it returned immediately and left the tap
                // torn down for good. Switching output device (AirPods in or
                // out) killed the spectrum until the next screen sleep.
                self.buildTap()
            }
            self.pendingRebuild = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    // MARK: - Silence suspension

    /// Main thread. Drops the tap (and with it coreaudiod's
    /// `PreventUserIdleSystemSleep` assertion) after prolonged silence. The
    /// source-check timer stays alive as the resume probe. No published state
    /// changes: `hasSignal` has long expired and the bands sit at zero by the
    /// time this fires, and `isLive` deliberately stays true — as far as the
    /// UI is concerned the analyzer is still on duty.
    private func suspendForSilence() {
        guard desired, running, !suspended else { return }
        suspended = true
        trace("suspending after \(Int(silentSeconds))s of silence, nothing holding an output stream")
        teardown()
        rescheduleSourceCheckTimer()
    }

    /// Main thread. Rebuilds the tap after a silence suspension.
    private func resumeFromSuspension(_ reason: String) {
        guard desired, suspended else { return }
        trace("resuming — \(reason)")
        buildTap()
    }

    /// A trustworthy external hint that audio is starting: the scriptable
    /// player's state flipped to playing. Resumes without waiting for a probe.
    func pokeResume() {
        resumeFromSuspension("player started")
    }

    // MARK: - Audio thread

    /// Runs on `queue`. Pulls channel 0, slides it into the analysis window, and
    /// recomputes the bands.
    private func process(_ bufferList: UnsafePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard let first = abl.first, let raw = first.mData else { return }
        let channels = max(1, Int(first.mNumberChannels))
        let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
        guard frames > 0 else { return }
        let ptr = raw.bindMemory(to: Float.self, capacity: frames * channels)

        let audioDt = Float(Double(frames) / sampleRate)

        // Dormancy gate (see the properties above): scan the incoming block's
        // peak before doing any real work.
        var framePeak: Float = 0
        for i in 0..<frames {
            let v = abs(ptr[i * channels])
            if v > framePeak { framePeak = v }
        }
        if framePeak < Self.dormancyPeakGate {
            silentSeconds += audioDt
            if !isDormant, silentSeconds >= Self.dormancyAfterSeconds {
                isDormant = true
                for i in smoothed.indices { smoothed[i] = 0 }
            }
            // Whether that is long enough to drop the tap is decided by the
            // source timer, which can also see whether any app still holds an
            // output stream — a question this thread must not ask (the scan
            // walks every CoreAudio process object).
        } else {
            silentSeconds = 0
            isDormant = false
        }

        if !isDormant {
            // Slide the window and append the newest frames (channel 0).
            if frames >= fftSize {
                for i in 0..<fftSize { sampleBuffer[i] = ptr[(frames - fftSize + i) * channels] }
            } else {
                let keep = fftSize - frames
                for i in 0..<keep { sampleBuffer[i] = sampleBuffer[i + frames] }
                for i in 0..<frames { sampleBuffer[keep + i] = ptr[i * channels] }
            }
            computeBands(audioDt: audioDt)
        }

        // Always runs — its change gate makes it nearly free while dormant,
        // and it is what lets the hasSignal hold expire after silence.
        publishIfDue()
    }

    #if DEBUG
    /// Test entry: slides mono `samples` into the analysis window and runs the
    /// same band computation the tap drives, returning the smoothed levels.
    /// Exists because the dB→bar mapping is exactly the part that regressed
    /// silently once before (bars standing still on compressed masters) — a
    /// test can feed synthetic "music" through the real FFT path and measure
    /// whether the bars actually move.
    func ingestForTesting(_ samples: [Float]) -> [Float] {
        if samples.count >= fftSize {
            for i in 0..<fftSize { sampleBuffer[i] = samples[samples.count - fftSize + i] }
        } else {
            let keep = fftSize - samples.count
            for i in 0..<keep { sampleBuffer[i] = sampleBuffer[i + samples.count] }
            for i in 0..<samples.count { sampleBuffer[keep + i] = samples[i] }
        }
        computeBands(audioDt: Float(Double(samples.count) / 48_000))
        return smoothed
    }
    #endif

    /// `audioDt`: duration of the audio this callback delivered. The window
    /// release and the running averages tick on *audio* time, not the wall
    /// clock — in production the two coincide (the tap delivers in real time),
    /// but audio time is deterministic under callback jitter and lets tests
    /// feed audio faster than real time without freezing the time constants.
    private func computeBands(audioDt: Float) {
        guard let fftSetup else { return }
        vDSP_vmul(sampleBuffer, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    raw.bindMemory(to: DSPComplex.self).baseAddress.map {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }

        // Log-spaced bands from 40 Hz to 12 kHz (or Nyquist).
        //
        // The ceiling was 16 kHz, which put the top band at 13.3–16 kHz — above
        // where streamed audio keeps anything. That bar was visibly dead, and
        // measurably so: replaying 30 s of speech through this exact math, band
        // 31 averaged level 0.194 at a 16 kHz ceiling and 0.289 at 12 kHz. The
        // envelope taxes the run's two end bars (see `WaveCanvas.envelope`), so
        // the last bar needs ~0.19 before it leaves the height floor at all —
        // a 16 kHz ceiling parks it right on that line, while the first bar,
        // carrying bass at level ~1, clears it constantly.
        let fMin = 40.0
        let fMax = min(12_000.0, sampleRate / 2)
        let binHz = sampleRate / Double(fftSize)
        // Deliberately twitchy: quick onto a transient and quick to fall back
        // between beats, so the bars punch instead of gliding. Slower constants
        // (0.6/0.82) read as a wave rather than as the iPhone's nervous meter.
        let attack: Float = 0.78     // how fast bars rise toward a new peak
        let decay: Float = 0.7       // how fast they fall

        var rawDb = [Float](repeating: 0, count: bandCount)
        for b in 0..<bandCount {
            let lo = fMin * pow(fMax / fMin, Double(b) / Double(bandCount))
            let hi = fMin * pow(fMax / fMin, Double(b + 1) / Double(bandCount))
            let loBin = max(1, Int(lo / binHz))
            let hiBin = min(fftSize / 2 - 1, max(loBin, Int(hi / binHz)))
            var peak: Float = 0
            for bin in loBin...hiBin { peak = max(peak, magnitudes[bin]) }
            rawDb[b] = 20 * log10(peak + 1e-6)
        }

        // Slide the window to follow the loudest band this callback: fast
        // attack so a track coming in loud doesn't take seconds to stop
        // clipping, slow release so it doesn't chase every quiet beat within
        // a song — only settles down once the track itself has been quieter
        // for a couple of seconds.
        let dt = audioDt
        let framePeakDb = rawDb.max() ?? loudnessCeilDb
        if framePeakDb > loudnessCeilDb {
            loudnessCeilDb += (framePeakDb - loudnessCeilDb) * Self.loudnessAttack
        } else {
            loudnessCeilDb -= Self.loudnessReleasePerSecond * dt
        }
        loudnessCeilDb = max(Self.loudnessCeilMin, loudnessCeilDb)
        let floorDb = loudnessCeilDb - Self.windowWidthDb

        // Fraction of the way each band's running average moves toward the
        // current frame — time-based so the tau holds at any callback rate.
        let averageAlpha = dt > 0 ? min(1, dt / Self.averageTau) : 1

        for b in 0..<bandCount {
            // Higher bands carry ~20 dB less energy, so lift them (measured)
            // to keep every bar in the same visible range instead of pinned low.
            let boost = Self.highBandBoost * pow(Float(b) / Float(max(1, bandCount - 1)), 1.5)
            let boosted = rawDb[b] + boost

            if !averageSeeded { averageDb[b] = boosted }
            averageDb[b] += (boosted - averageDb[b]) * averageAlpha

            // Two readings blended: the absolute level inside the floating
            // window (keeps bass taller than treble, quiet passages low), and
            // the deviation from this band's own recent average (makes every
            // beat punch, however compressed the master — see `beatWeight`).
            let absolute = min(1, max(0, (boosted - floorDb) / Self.windowWidthDb))
            let beat = min(1, max(0, (boosted - averageDb[b] + Self.beatOffsetDb) / Self.beatRangeDb))
            // In silence a band sits exactly at its own average, which the
            // beat term would read as a healthy mid-level bar (and hold
            // `hasSignal` open forever). Gate it on audibility: inaudible in
            // absolute terms → no beat contribution either.
            let gate = min(1, absolute * 12)
            let level = gate * (Self.beatWeight * beat + (1 - Self.beatWeight) * absolute)
            smoothed[b] = level > smoothed[b]
                ? smoothed[b] + (level - smoothed[b]) * attack
                : smoothed[b] * decay
        }
        averageSeeded = true
        if smoothed.contains(where: { $0 > Self.signalThreshold }) {
            lastSignalTime = CACurrentMediaTime()
        }
    }

    /// Blend each band a little with its neighbours (simple 3-tap kernel, edges
    /// replicated) so the published shape reads as one continuous curve instead
    /// of `bandCount` independent, jumpy bars: one loud isolated bin between two
    /// quiet ones reads as noise rather than as music, and at small band counts
    /// that is most of the wave.
    ///
    /// The kernel is even — 25/50/25. A lighter 15/70/15 gives back more
    /// between-bar contrast and is worth another look, but the one time it was
    /// judged, the tap had Safari and Spotify audio mixed together, so the
    /// comparison was worthless. Re-check it against a single source before
    /// changing this.
    /// Applied only at publish time, on a copy: `smoothed` itself keeps its
    /// unblended per-band values for the attack/decay recursion above, so this
    /// can't compound blur into itself frame over frame.
    private func spatiallySmoothed(_ source: [Float]) -> [Float] {
        guard source.count > 2 else { return source }
        return source.indices.map { i in
            let prev = source[max(0, i - 1)]
            let next = source[min(source.count - 1, i + 1)]
            return (prev + 2 * source[i] + next) / 4
        }
    }

    /// Last levels actually handed to SwiftUI, for the change gate below.
    private var lastPublished: [Float] = []
    #if DEBUG
    private var lastTraceTime: CFTimeInterval = 0
    #endif

    /// UI update rate. Each publish is one SwiftUI update of the bars (and
    /// only the bars — see `SpectrumBands`), with `WaveBarsView` easing
    /// between them. 30 is what the wave was tuned at; 15 was tried while
    /// hunting the app's idle cost and made no measurable difference, because
    /// the cost was never in the publish rate.
    private static let publishesPerSecond: Double = 30
    /// How much a band has to move before it's worth a redraw. The old 0.004
    /// was below the level of a single displayed pixel on these bars, so
    /// dither in a quiet passage still forced the full update rate.
    private static let publishEpsilon: Float = 0.02

    /// Publish to SwiftUI at `publishesPerSecond` regardless of the (faster)
    /// audio callback — but only when something the UI shows would actually
    /// change. Without the gate, silence still cost a main-thread update per
    /// frame for an unchanged all-zero wave; with it, a quiet system reduces
    /// the publisher to a float comparison.
    #if DEBUG
    /// Publish `levels` as though the tap had delivered them: bands, signal and
    /// live flag all set, none of which `ingestForTesting` touches (it returns
    /// the smoothed levels and leaves the published state alone, which is what
    /// its callers want).
    ///
    /// Without this the marketing shots draw the *procedural fallback* — the
    /// fixed pattern the wave runs when there is no tap. It looks convincing,
    /// which is the problem: it would put a wave that ignores the music on the
    /// README under the claim that these are real frequencies.
    func publishForTesting(_ levels: [Float]) {
        bands.values = spatiallySmoothed(levels).map { CGFloat($0) }
        hasSignal = true
        isLive = true
    }
    #endif

    private func publishIfDue() {
        let now = CACurrentMediaTime()
        guard now - lastPublish >= 1.0 / Self.publishesPerSecond else { return }
        let signalNow = now - lastSignalTime < Self.signalHoldSeconds
        let changed = signalNow != hasSignal
            || lastPublished.count != smoothed.count
            || zip(smoothed, lastPublished).contains { abs($0 - $1) > Self.publishEpsilon }
        guard changed else { return }
        lastPublish = now
        lastPublished = smoothed
        #if DEBUG
        if now - lastTraceTime > 2 {
            lastTraceTime = now
            trace(String(format: "publishing — peak %.2f, signal %@, dormant %@",
                         smoothed.max() ?? 0, signalNow ? "yes" : "no", isDormant ? "yes" : "no"))
        }
        #endif
        let snapshot = spatiallySmoothed(smoothed).map { CGFloat($0) }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.bands.values = snapshot
            if self.hasSignal != signalNow { self.hasSignal = signalNow }
        }
    }

    // MARK: - CoreAudio property helpers

    /// `Unmanaged<CFString>`, not `CFString?`: CoreAudio hands back a +1
    /// reference the caller owns, and writing it through a raw pointer into a
    /// managed optional gives ARC nothing to release — one leaked string per
    /// call, on a path the resume probe walks every 2 s. It is also the only
    /// warning the build emits ("forming UnsafeMutableRawPointer to a variable
    /// of type Optional<CFString>"), which is the compiler saying exactly this.
    private func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private func tapFormat(_ tap: AudioObjectID) -> AudioStreamBasicDescription? {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &asbd) == noErr else { return nil }
        return asbd
    }

    // MARK: - Source app identification

    private func startSourceCheckTimer() {
        // A rebuild after suspension finds the timer already alive.
        guard sourceCheckTimer == nil else { rescheduleSourceCheckTimer(); return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now())
        timer.setEventHandler { [weak self] in self?.sourceTimerFired() }
        timer.resume()
        sourceCheckTimer = timer
    }

    private func stopSourceCheckTimer() {
        sourceCheckTimer?.cancel()
        sourceCheckTimer = nil
    }

    /// One timer, three cadences: 1 s while a signal plays (the pill's source
    /// icon should track app switches quickly), 5 s while the tap runs but
    /// everything is silent (the icon isn't shown then, and the scan walks
    /// every CoreAudio process object — no reason to do that each second all
    /// day), and the backoff ladder while suspended, where the same scan *is*
    /// the resume probe.
    private var sourceCheckInterval: Double {
        if suspended {
            return Self.probeIntervalSeconds * pow(2, Double(min(failedBuilds, 4)))
        }
        return isDormant ? 5.0 : 1.0
    }

    private func rescheduleSourceCheckTimer() {
        sourceCheckTimer?.schedule(deadline: .now() + sourceCheckInterval)
    }

    /// Runs on `queue`, self-rescheduling (the cadence depends on state).
    private func sourceTimerFired() {
        let playing = foreignOutputProcesses()
        let source = playing.first.map { Self.attributedBundleID(for: $0.bundleID) }
        if suspended {
            // Anything producing output again is worth a tap: going from "no
            // app holds an output stream" to "one does" is a real transition,
            // not the unreliable per-process running flag being consulted as
            // truth (see `hasSignal`).
            if source != nil {
                DispatchQueue.main.async { [weak self] in self?.resumeFromSuspension("an app started output") }
            }
        } else {
            publish(sourceBundleID: source)
            // Give the tap up only when the machine is genuinely quiet. A
            // paused player still holds its stream, and that is precisely when
            // the wave has to be ready to come back instantly.
            if silentSeconds >= Self.suspendAfterSeconds, source == nil {
                DispatchQueue.main.async { [weak self] in self?.suspendForSilence() }
            } else if playing.map(\.id) != tappedProcesses {
                // The tap is bound to the processes it was built for, so a new
                // app starting playback is invisible to it until it is rebuilt.
                // Cheap, and rare in practice — a paused player keeps its stream
                // open, so this fires on real app changes rather than on pauses.
                trace("retapping — the set of playing processes changed")
                DispatchQueue.main.async { [weak self] in self?.rebuildForDeviceChange() }
            }
        }
        rescheduleSourceCheckTimer()
    }

    /// Every process other than us that currently holds an output stream, in
    /// CoreAudio's own order, with its bundle ID.
    ///
    /// One scan serving two callers: the pill wants the first one's bundle ID
    /// for its source icon, and `buildTap` wants the object IDs so it can tap
    /// exactly those processes instead of the whole machine.
    private func foreignOutputProcesses() -> [(id: AudioObjectID, bundleID: String)] {
        let ownBundleID = Bundle.main.bundleIdentifier
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var processes = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &processes) == noErr else {
            return []
        }

        var isRunningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var found: [(id: AudioObjectID, bundleID: String)] = []
        for process in processes {
            var isRunning: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(process, &isRunningAddress, 0, nil, &runningSize, &isRunning) == noErr,
                  isRunning != 0 else { continue }
            guard let bundleID = stringProperty(process, kAudioProcessPropertyBundleID), bundleID != ownBundleID else { continue }
            found.append((process, bundleID))
        }
        return found
    }

    /// The (attributed) bundle ID of the first process holding an output
    /// stream, or nil. Doubles as the resume probe while suspended: "someone is
    /// producing output again" is exactly the signal that makes rebuilding the
    /// tap worthwhile.
    /// WebKit's audio/GPU XPC helpers (e.g. `com.apple.WebKit.GPU`) are what
    /// CoreAudio actually reports as the running process for any WebKit-based
    /// browser tab — they're spawned on demand and re-parented to `launchd`,
    /// so there's no reliable way back to the tab's own app. Safari is by far
    /// the common case, so attribute these to Safari rather than showing no
    /// icon at all.
    private static func attributedBundleID(for bundleID: String) -> String {
        bundleID.hasPrefix("com.apple.WebKit") ? "com.apple.Safari" : bundleID
    }

    private func publish(sourceBundleID id: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.sourceBundleID != id else { return }
            self.sourceBundleID = id
        }
    }
}
