<p align="center">
  <img src="assets/icon.png" width="120" alt="Côte d'OS">
</p>

<h1 align="center">Côte d'OS</h1>

<p align="center">
  <strong>Your Mac's notch, doing something other than hiding a camera.</strong>
</p>

<p align="center">
  <a href="../../actions/workflows/build.yml"><img src="https://img.shields.io/github/actions/workflow/status/Scxttk/CoteDOs/build.yml?style=flat-square&label=build" alt="Build status"></a>
  <a href="../../releases/latest"><img src="https://img.shields.io/github/v/release/Scxttk/CoteDOs?style=flat-square&label=release" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black?style=flat-square" alt="macOS 14+">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/Scxttk/CoteDOs?style=flat-square" alt="MIT license"></a>
</p>

<p align="center">
  <img src="assets/hero.png" width="820" alt="The island expanded into now-playing controls">
  <br>
  <sub>Playing, it's a pill. Idle, it's nothing at all — move the cursor up there and it fades in.</sub>
</p>

---

## A real spectrum, not an animation

<p align="center">
  <img src="assets/tab-spectrum.png" width="820" alt="The spectrum tab">
</p>

A CoreAudio process tap on whatever your Mac is playing — 32 bands over a 2048-point FFT. It taps the *processes* making sound rather than the output device, which is the difference between this working and your AirPods' stem controls quietly breaking.

Every bar is quantised onto the palette of the album-cover slice it sits over, then toned down into the band Apple's own now-playing bars occupy. A Safari video tints the bars with Safari's blue, pulled from its icon through the same colour election album art goes through, instead of borrowing the cover of whatever's paused in Spotify.

## Then it takes the whole screen

<p align="center">
  <img src="assets/spectrum-fullscreen.png" width="880" alt="The fullscreen takeover">
</p>

⌥⌘S from anywhere and the run grows out of the island until it fills the display. Escape brings it back.

**The part I built it for:** hit ⌥⌘S on your way out of the room. The run holds the screen awake while you're gone, and whatever ends it locks the Mac behind it. Quitting the app while it's up locks too — that isn't an escape hatch.

- Nothing arms a run by itself. The hotkey is the whole trigger; a Mac that decides on its own that you've left is a Mac fighting you.
- A run left over music that runs out ends after ninety seconds of silence, and locks. "Audible" comes from the tap, not from a player's play button — a browser video counts, a paused Spotify track doesn't. Started in a silent room, it stays up until you come back.
- When an armed run ends it leaves a note in the pill saying why and when. `Input 14:02` on a Mac you left at 13:50 is somebody else.

## Volume and brightness, in the notch

A CGEvent tap grabs the hardware keys, CoreAudio applies the change directly, and Apple's grey box never appears. ⇧⌥ for 1/64 steps instead of 1/16. Needs Accessibility.

## And it knows when to disappear

Nothing playing, no timer, no activity — the pill isn't dimmed, it's *gone*, and click-through.

When Safari goes fullscreen its URL bar slides up under the pill, so the pill moves aside — found through the Accessibility API, click-through until you leave. It dodges the visible toolbar rather than fullscreen as such: press `f` on a YouTube video and there's nothing to avoid, so the pill stays centred. It also steps aside for a frontmost app's menus, and follows the cursor across displays while collapsed.

## The rest of the tabs

<p align="center">
  <img src="assets/tab-music.png" width="400" alt="Music">
  <img src="assets/tab-files.png" width="400" alt="Shelf">
  <br>
  <img src="assets/tab-capture.png" width="400" alt="Capture">
  <img src="assets/tab-timer.png" width="400" alt="Timer">
</p>

| | |
|---|---|
| **Music** | Spotify and Apple Music — play, skip, scrub, pick the output device. AppleScript rather than MediaRemote, which Apple sealed off in macOS 15.4 and broke most third-party notch apps overnight. Refreshes every 5 s with the position interpolated in between. |
| **Shelf** | Drag files onto the notch, drag them off wherever later turns out to be. Held as bookmarks, so a rename or a reboot doesn't lose them; QuickLook thumbnails cached between launches. |
| **Capture** | ⌥⌘Space, type, done — appended under a heading in today's Obsidian daily note. Obsidian doesn't need to be running. Also grabs the frontmost Safari or Chrome tab as a markdown link. |
| **Timer** | Named presets that auto-chain. Order the list Focus/Break and it cycles; sessions can log to the daily note as Dataview-friendly bullets. |

The pill grows rightward for a running timer or a shelf badge, so the spectrum stays centred under the notch. Every tab can be switched off in Settings.

<p align="center">
  <img src="assets/notch-collapsed.png" width="200" alt="The collapsed pill">
  &nbsp;
  <img src="assets/pill-spectrum.png" width="260" alt="The spectrum-only pill at its widest">
  &nbsp;
  <img src="assets/pill-shelf.png" width="210" alt="The pill with a shelf badge">
</p>

## Requirements

| | |
|---|---|
| **macOS 14** | for the app |
| **macOS 14.4** | for the spectrum — process taps don't exist below it, and the wave falls back to a procedural animation |
| **Apple silicon** | it builds for Intel; untested rather than supported |
| **No notch needed** | it draws its own |

## Permissions

Three, each asked for only when you touch the feature that needs it.

| | Without it | Why |
|---|---|---|
| **Automation** | media controls, browser capture and the Terminal button do nothing | Apple Events are the only public way to drive Spotify, Music, Safari, Chrome, Terminal |
| **Accessibility** | volume keys go back to Apple's OSD, the Safari dodge stops, the lock falls back to a ⌃⌘Q keystroke | a CGEvent tap for the hardware keys; AX reads to find Safari's URL field |
| **Audio Recording** | the spectrum animates but ignores your music | the CoreAudio process tap |

That last one is filed under **Audio Recording**, not Microphone — resetting Microphone appears to work and changes nothing:

```sh
tccutil reset AudioCapture com.scott.notchmate
```

## Accessibility

**Reduce Motion** turns every island transition into a short crossfade. The spectrum keeps moving, because it's the content rather than decoration. VoiceOver reads the collapsed pill as one sentence — track, artist, timer, shelf count — and the transport buttons have names.

## Privacy

No network requests. No analytics, no update check, no telemetry — there isn't a single `URLSession` call site left in the source. Audio is analysed in-process and never written anywhere; captured notes are files in your vault, shelf entries are bookmarks on disk, settings are in `UserDefaults`.

## Installing

Grab the zip from the [latest release](../../releases/latest), unzip, drag `CoteDOs.app` into `/Applications`. From 1.5.0 it's Developer ID signed and notarized, so it opens on a double-click; releases up to 1.4.0 were ad-hoc signed and still need the Gatekeeper detour. It adds itself as a login item on first launch.

Updating from a release called `Ledge.app` or `NotchMate.app`? Delete the old one first — settings survive, but macOS will ask for the permissions again, because a grant follows the code signature rather than the bundle identifier.

Same trap on every rebuild: macOS leaves the Accessibility checkbox *checked* while the permission underneath it is dead. If volume keys stop landing in the notch, remove the entry and add it again.

### Uninstalling

```sh
rm -rf ~/Library/Application\ Support/NotchMate ~/Library/Caches/NotchMate
defaults delete com.scott.notchmate
tccutil reset AudioCapture com.scott.notchmate
```

Automation and Accessibility have to come off by hand in System Settings; macOS has no CLI for revoking those.

## Building

```sh
xcodebuild -project CoteDOs.xcodeproj -scheme CoteDOs -configuration Debug build
```

No SPM, no CocoaPods — every dependency is a system framework.

Brightness resolves the private `DisplayServices` framework at runtime through `dlopen`, and the screen lock resolves `SACLockScreenImmediate` out of `login.framework` the same way; if Apple pulls those symbols, both features turn themselves off. The app isn't sandboxed either, which is why it isn't on the Mac App Store and won't be.

Icon and screenshots are both drawn in code: `swift Tools/GenerateAppIcon.swift` renders the catalog sizes, and `-only-testing:CoteDOsTests/MarketingShots` mounts the real views offscreen and composites them onto a backdrop. Real views, real layout constants, real FFT; invented track, cover and files.

## License

[MIT](LICENSE). Do whatever you want with it.
