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
</p>

<p align="center">
  <img src="assets/notch-collapsed.png" width="220" alt="The collapsed pill on a desktop">
  <br>
  <sub><b>Playing, it's a pill. Idle, it's nothing at all.</b><br>Move the cursor up there and it fades in.</sub>
</p>

---

## A real spectrum, not an animation

<p align="center">
  <img src="assets/tab-spectrum.png" width="820" alt="The spectrum tab">
</p>

A CoreAudio process tap on whatever your Mac is playing — 32 bands over a 2048-point FFT. It taps the *processes* making sound rather than the output device, which is the difference between this working and your AirPods' stem controls quietly breaking.

Every bar is quantised onto the palette of the album-cover slice it sits over, then toned down into the band Apple's own now-playing bars occupy — muted, one light level across the run, no settings to get wrong.

The wave belongs to whoever is making the sound, too. A Safari video tints the bars with Safari's blue — pulled from its icon, through the same colour election album art goes through — instead of borrowing the cover of whatever's paused in Spotify.

## Then it takes the whole screen

<p align="center">
  <img src="assets/spectrum-fullscreen.png" width="880" alt="The fullscreen takeover">
</p>

⌥⌘S from anywhere, or a click on the spectrum tab, and the run grows out of the island until it fills the display. Escape brings it back — and the wave flies home to the pill, not to the page, because the page is collapsing behind it by then.

**The part I actually built it for:** hit ⌥⌘S on your way out of the room. The run holds the screen awake while you're gone, and whatever ends it locks the Mac behind it — because locking is the half of display-sleep behaviour the takeover just displaced. Quitting the app while it's up locks too. That isn't an escape hatch.

It's fussier than it looks, on purpose:

- Nothing arms a run by itself. A Mac that decides on its own that you've left, takes the screen and then locks when you reach for the trackpad is a Mac fighting you; the hotkey is the whole trigger.
- A run left over music that runs out ends on its own after ninety seconds of silence, and locks — the Mac was left, and the music finishing doesn't change that. "Audible" comes from the tap itself, not from a player's play button: a browser video counts, a paused Spotify track with a song loaded doesn't. Press ⌥⌘S in a silent room and none of this applies; it stays up until you come back.
- When an armed run ends it leaves a note in the pill saying why and when. `Input 14:02` on a Mac you left at 13:50 is somebody else.

Swiping deliberately doesn't get you here. A two-finger swipe opens the island and stops: carrying the same gesture on into a full-screen visual you didn't ask for turned out to be far too easy to trigger by accident.

## Volume and brightness, in the notch

This is the reason I open the app at all. A CGEvent tap grabs the hardware keys, CoreAudio applies the change directly, and Apple's grey box never appears. ⇧⌥ for 1/64 steps instead of 1/16. Needs Accessibility.

## And it knows when to disappear

Nothing playing, no timer, no activity — the pill isn't dimmed, it's *gone*, and click-through. Move the cursor into the space it would occupy and it fades in; hover it and it opens.

When Safari goes fullscreen its URL bar slides up under the pill, so the pill moves out of the way — next to the address field, found through the Accessibility API, click-through until you leave. What it dodges is the visible toolbar rather than fullscreen as such: press `f` on a YouTube video and there's no toolbar to avoid, so the pill stays centred and stays interactive.

It also steps aside when the frontmost app's menus reach far enough right to collide with it, and follows the cursor across displays while collapsed.

## The rest of the tabs

<table>
<tr>
<td width="50%"><img src="assets/tab-music.png" alt="Music"></td>
<td><b>Music</b><br><br>Spotify and Apple Music — play, skip, scrub, and pick the output device. AppleScript rather than MediaRemote, because Apple sealed that framework off in macOS 15.4 and broke most third-party notch apps overnight. A hard refresh every 5 s with the position interpolated locally in between: not instant, but it survives OS updates that private APIs don't.</td>
</tr>
<tr>
<td><img src="assets/tab-files.png" alt="Shelf"></td>
<td><b>Shelf</b><br><br>Drag files onto the notch, drag them off later, wherever later turns out to be. Held as bookmarks rather than paths, so a rename or a reboot doesn't lose them, with QuickLook thumbnails cached between launches.</td>
</tr>
<tr>
<td><img src="assets/tab-capture.png" alt="Capture"></td>
<td><b>Capture</b><br><br>⌥⌘Space, type, done — appended under a heading in today's Obsidian daily note. Obsidian doesn't need to be running; it writes the file. Also grabs the frontmost Safari or Chrome tab as a markdown link, and opens a Terminal in the vault.</td>
</tr>
<tr>
<td><img src="assets/tab-timer.png" alt="Timer"></td>
<td><b>Timer</b><br><br>Named presets that auto-chain, because I kept starting a pomodoro in a phone app and then closing the phone app. Order the list Focus/Break and it cycles. Sessions can log to the daily note as Dataview-friendly bullets.</td>
</tr>
</table>

The pill grows rightward for a running timer or a shelf badge, so the spectrum stays exactly centred under the notch instead of being shoved sideways:

<p align="center">
  <img src="assets/pill-spectrum.png" width="300" alt="The spectrum-only pill at its widest">
  &nbsp;&nbsp;
  <img src="assets/pill-shelf.png" width="240" alt="The pill with a shelf badge">
</p>

Every tab can be switched off in Settings if you only came for some of this.

## Requirements

| | |
|---|---|
| **macOS 14** | for the app |
| **macOS 14.4** | for the spectrum — CoreAudio process taps don't exist below it, and the wave falls back to a procedural animation |
| **Apple silicon** | it builds for Intel; I have no Intel Mac, so call that untested rather than supported |
| **No notch needed** | it draws its own |

## Permissions

Three, each asked for only when you touch the feature that needs it, and each one optional if you don't.

| | Without it | Why |
|---|---|---|
| **Automation** | media controls, browser capture and the Terminal button do nothing | Apple Events are the only public way to drive Spotify, Music, Safari, Chrome and Terminal |
| **Accessibility** | volume keys go back to Apple's OSD, the Safari dodge stops, the lock at the end of a takeover falls back to a ⌃⌘Q keystroke | a CGEvent tap for the hardware keys; AX reads to find Safari's URL field |
| **Audio Recording** | the spectrum animates but ignores your music | the CoreAudio process tap |

That last one is filed under **Audio Recording**, not Microphone. Resetting Microphone appears to work and changes nothing, which cost me an hour once:

```sh
tccutil reset AudioCapture com.scott.notchmate
```

## Reduce Motion and VoiceOver

Turn on **Reduce Motion** (Accessibility → Display) and the island stops springing — every transition becomes a short crossfade instead. The spectrum keeps moving, because the spectrum is the content rather than decoration; muting it to reduce motion would be like muting a music player.

VoiceOver reads the collapsed pill as one sentence — track, artist, the timer if one is running, how many files are on the shelf — rather than as a row of unlabelled images, and the transport buttons have names.

## Privacy

The app makes no network requests. No analytics, no update check, no telemetry — after the Claude tab came out in 1.5.0 there isn't a single `URLSession` call site left in the source. Grep it.

Audio is analysed in-process and never written anywhere. Captured notes are files in your vault. Shelf entries are bookmarks on disk. Settings are in `UserDefaults`. That's the whole data story.

## Getting it running

Grab the zip from the [latest release](../../releases/latest), unzip, drag `CoteDOs.app` into `/Applications`. The file name skips the accents; the app calls itself Côte d'OS. Its bundle identifier and data folders still carry the app's older names underneath, so your settings and shelf survive a rename — plumbing, not facade.

From 1.5.0 the app is signed with a Developer ID and notarized, so it opens on a double-click — no Gatekeeper detour, no `xattr` incantation. Releases up to 1.4.0 were ad-hoc signed and still need one.

It adds itself as a login item on first launch. Updating from a release called `Ledge.app` or `NotchMate.app`? Delete the old one first — your settings survive, but macOS will ask for the permissions again, because a grant follows the code signature rather than the bundle identifier.

Which is the thing that's bitten me most often: rebuild and reinstall, and macOS leaves the Accessibility checkbox *checked* while the permission underneath it is dead. If volume keys stop landing in the notch after a rebuild, remove the entry and add it again. Don't trust the checkbox.

## Uninstalling

Delete the app, then, to leave nothing behind:

```sh
rm -rf ~/Library/Application\ Support/NotchMate ~/Library/Caches/NotchMate
defaults delete com.scott.notchmate
tccutil reset AudioCapture com.scott.notchmate
```

The login item goes with the app. Automation and Accessibility have to come off by hand in System Settings; macOS has no CLI for revoking those.

## Building it yourself

```sh
xcodebuild -project CoteDOs.xcodeproj -scheme CoteDOs -configuration Debug build
```

Or `open CoteDOs.xcodeproj` and press ⌘R in Xcode 16+. No SPM, no CocoaPods — every dependency is a system framework, so there's nothing to fetch.

Two things worth knowing before you dig in. Brightness resolves the private `DisplayServices` framework at runtime through `dlopen`, and the screen lock resolves `SACLockScreenImmediate` out of `login.framework` the same way; if Apple ever pulls those symbols, both features turn themselves off and the system behaviour takes back over. That's the bargain you make with private APIs, and I'm fine with it. The app also isn't sandboxed — half of what it does is impossible inside a container, which is why it isn't on the Mac App Store and won't be.

The icon is drawn in code: `swift Tools/GenerateAppIcon.swift` renders all seven catalog sizes plus a flattened marketing copy, no design file involved. The screenshots are drawn in code too — `-only-testing:CoteDOsTests/MarketingShots` mounts the real views offscreen and composites them onto a backdrop. Real views, real layout constants, real FFT; invented track, cover and files.

## License

[MIT](LICENSE). Do whatever you want with it.
