# Changelog

All notable changes to Côte d'OS (formerly Ledge, formerly NotchMate — the
bundle identifier still is NotchMate, see the README for why).

## [Unreleased]

### Added
- **The island can be carried to another border.** Press it and pull: the whole
  panel follows the cursor and lands on the nearest screen edge when you let
  go — top, bottom, left or right, sliding freely along whichever it picks. It
  is always on one, the way a picture-in-picture window is; nothing ends up
  adrift in the middle of the screen. Where it landed survives a relaunch, and
  it opens *inward* from its edge, so an island parked at the bottom grows
  upward instead of off the screen.
  - Released within a hair of an edge's centre it lands exactly centred; on the
    top edge that is the notch's home pose again. "Notch zurück nach oben" in
    the status menu does the same from anywhere, and only lights up while the
    island is somewhere you put it.
  - Parked off home, the two automatic placements stand down: no Safari-URL-bar
    dodge and no menu-bar-overlap hide. Both exist to make the pose *at the
    notch* survive; once you have chosen a spot, moving the island out from
    under you is the last thing it should do.
- **On a side border the island stands up.** Not the landscape island turned on
  its side — a layout of its own. The tab strip becomes a column pinned to the
  edge, glyphs upright; the spectrum's bars stack down the run and grow out of
  the border; the pages slide vertically, the way the column reads. The open
  island is portrait there (300 × 420) rather than a 212 pt-thick sliver, which
  is what lets the music page keep its cover and its controls.
  - The band the tab strip lives in always hugs the border, so the island is a
    mirror of itself rather than the same layout moved: at the bottom the strip
    is along the bottom edge, and the pill hands its glyph over in place
    instead of across the island.
  - The swipes turn with it. Pulling the island out of its border is a swipe
    away from that border — down at the top, up at the bottom, right at the
    left edge — and paging between tabs runs *along* the border, so on a side
    dock you page up and down.
  - **It goes in a corner too.** Drop it near either end of a border and it
    pins itself there instead of sliding to the nearest free spot. That needs
    more than running `along` to its limit: the island is centred in a panel
    much longer than itself, so a collapsed pill shoved as far as it goes still
    stopped a third of a screen short of the corner. In a corner the island is
    pinned to that end of its panel instead. Each screen corner is reachable
    two ways — from the border above it or the one beside it — and the island
    lies down or stands up accordingly.
  - **The proportions were redone.** The portrait island was a straight swap of
    the landscape one, 420 pt tall, which left every page a small cluster
    adrift in black. It is 320 × 264 now, sized from what actually has to fit
    (a 214 pt tab column, 130–200 pt of page content). The music page stacks
    cover over title over wave rather than crowding them into a row — the cover
    is half again as big and the title stopped truncating — and the timer's
    presets stack into a column instead of scrolling off the edge. The
    spectrum's letterbox got its own ratio for a portrait page, which had been
    holding the run to half the width it had.
  - Two things degrade rather than rotate, on purpose. A live activity on a
    side border shows its glyph and its progress bar but not its words: a
    device name turned on its side reads as a rendering fault. And the wave
    that travels from pill to page as one object stays a top-border trick —
    every number behind that flight is measured from an island hanging off the
    top edge; elsewhere the pill and the page cross-fade, as they already do
    with a timer readout in the pill.
  - "Notch mittig nach oben" is in Settings › Notch as well as the status menu.
    The status menu is the one surface a mis-placed island can cover, and
    Settings is where you go looking after regretting a drag.
- **⌥⌘N pauses the notch.** The panel hides and becomes fully click-through,
  so the exact spot it occupies can be hovered and clicked — until now the
  only way to reach something living under the notch was quitting the app.
  Also in the status menu ("Notch pausieren", with a checkmark, the menu-bar
  icon hollows out while paused). While paused, nothing wakes it — hover,
  swipe, file drags and ⌥⌘Space are all inert; ⌥⌘N brings it back. Not
  persisted: a fresh launch always starts with the notch on.

### Changed
- **The output-device pill has its own switch.** Connecting AirPods already
  gets a banner from macOS, so Côte d'OS announcing the same thing a moment
  later reads as a stutter rather than a feature. "Audio-Ausgabe-Wechsel" in
  Settings › Notch turns the pill off on its own, without taking charging and
  the file-received pill with it. It stays on by default — a switch to a
  speaker or an interface gets no banner from macOS at all. Switched off,
  the route change costs nothing: no device lookup, no battery readout.
- **The fullscreen guard is ⌥⌘S only.** 1.5 shipped it as a screen saver as
  well: an untouched Mac with something playing had the screen taken from it
  fifteen seconds before the display would have gone dark, and locked when you
  came back. Guessing that you have left is the part that doesn't work — it
  guesses wrong on anything you sit and read — so the guess is gone, along with
  its Settings toggle. Pressing ⌥⌘S does what the screen saver did, at the one
  moment you actually know you're leaving.
  - A run armed over music still ends and locks after ninety seconds of
    silence. One armed in a silent room never ends itself: ⌥⌘S with nothing
    playing stays up until you come back.
  - Nothing else changes — the arming, the lock, the note in the pill saying
    what ended the run and when, and the unarmed takeover you get from the
    spectrum tab are all as they were.

### Fixed
- **Capture no longer costs you the daily template.** Writing the first thing of
  the day — a capture, or a finished focus timer — into a daily note that did not
  exist yet created it as a bare file: the heading, the bullet, and nothing else.
  No frontmatter, so the day dropped out of every Bases view that filters on it,
  and no way to get the template back either, because Obsidian only templates a
  note at the moment it creates one. Côte d'OS now reads the vault's own daily
  template (Templater's folder templates, or the core Daily-notes setting) and
  fills in the date expressions itself — `tp.date.now` with its offsets,
  `tp.file.title`, `{{date}}`, and moment formats down to `dddd` in the Mac's
  language. Anything it cannot evaluate is left standing verbatim rather than
  guessed at, and a vault with no template behaves exactly as before.
- **Closing the notch takes the same time whatever is playing.** The last step of
  the collapse waited half a second for the tab glyph to finish drifting to the
  centre — but only when the pill had nothing to show, since music, any other
  system audio or a running timer skipped that wait. So the same gesture closed
  the island in 0.36 s or in 0.94 s, decided by something inaudible in the room
  and invisible on screen. The row now gathers on its own quick clock instead of
  riding the capsule's long one, which is what that wait was for; the capsule
  keeps settling exactly as calmly as it did.
- **A live activity no longer jumps the pill open.** With a volume, route or
  charging pill up, the closing island landed on the activity's width — 220 pt
  or more against the pill's 50 — in a single unanimated frame. It morphs now,
  the way an activity arriving and leaving always did. The cursor also reaches
  the whole of such a pill: hover and clicks were still being tested against the
  narrow content width, so most of a visible route pill was deaf.
- **Focus time lands on the day it was worked.** A block running through midnight
  was logged to the note for the day it *ended*, which opened tomorrow's daily
  with a `23:50–00:15` entry. It goes to the day it started.
- **A split cover no longer splits the wave.** A sleeve whose colours sit on
  opposite sides of the artwork — one half green, the other purple — drew every
  bar left of centre in the first colour and every bar right of it in the
  second, with a hard seam down the middle where they met. Each slice was
  electing its own colour honestly; the run just never had to agree on one.
  Now the hue the most bars elect sets the family and the rest may lean 20°
  toward their own, so the sleeve shows up as its colour instead of as a
  diagram of where that colour sits. Per-bar saturation and brightness are
  untouched, which is what still makes a run read as *this* cover.
- **The bars have lost their halo.** Every bar threw its own light, scaled by
  how loud it was. Measured against the reference it is the wrong instinct: the
  Dynamic Island's bars have no glow at all, and ours turned the black around
  the run milky grey — most of what made the colours look dirty.
- **The wave no longer freezes on screen after the music stops.** Quitting
  Spotify mid-song, or closing a browser tab that was playing, left the pill
  open over a motionless spectrum — sometimes for hours, until some app made a
  sound again. The band levels are written from the audio callback, so a tap
  torn down while a signal was still being held had nothing left to clear them.
  The same freeze also kept the ⌥⌘S guard from ever seeing the silence it waits
  for, so an armed run never ended.

## [1.5.0] – 2026-07-30

The release where the wave gets the whole screen, and the app gets signed
properly.

**Read this one before updating:** 1.4 → 1.5 replaces the bundle, so macOS asks
for the Audio Recording grant one more time. It is the last time. Until now the
app was signed by a free personal team, which can only issue *development*
signatures, and macOS treats every rebuild of one of those as a different app —
so every update cost you that grant, and a dead spectrum afterwards looked like a
bug in the app. From 1.5 the signature is a Developer ID, which survives updates.

Also worth knowing: **the audio spectrum needs macOS 14.4**, not 14.0. CoreAudio
process taps don't exist below that. Everything else in the app runs on 14.0, and
the README never mentioned the difference.

### Added
- **The spectrum as a screen saver.** Leave the Mac alone with something audible
  playing and, fifteen seconds before macOS would blank the display, the
  fullscreen spectrum takes the screen instead and holds it awake. Touch
  anything and it shrinks away — and the Mac locks behind it, because locking is
  the half of display-sleep behaviour the takeover displaces. Quitting is not an
  escape hatch either. On by default; the toggle is in Settings → Notch.
  - It watches for *audible* audio, from the tap itself rather than from a
    player's play button, so a browser video counts and a paused Spotify track
    with a song loaded does not.
  - It won't throw a spectrum over a fullscreen YouTube tab: if something else is
    already holding a display-sleep assertion, it stands down.
  - When an armed run ends it leaves a note in the pill saying *why* and *when* —
    "Input 14:02" on a Mac you left at 13:50 is somebody else.
- **Fullscreen spectrum, on demand.** ⌥⌘S from anywhere, or a click on the
  spectrum tab. The run grows out of the island rather than appearing, and Escape
  plays it backwards — home to the pill, not to the page, which is collapsing by
  then. Swiping is deliberately not a way in: a two-finger swipe opens the island
  and stops there, because carrying the gesture on into a full-screen visual was
  too easy to trigger by accident.
- **The wave belongs to whoever is making the sound.** A Safari video now tints
  the bars with Safari's blue, pulled from its icon through the same colour
  election album art goes through — instead of drawing white, or worse, borrowing
  the cover of a paused track in Spotify.
- **English.** The whole interface, not just the parts that happened to be
  translated. Both permission prompts too.
- **Reduce Motion is answered.** Turn it on in Accessibility → Display and the
  island stops springing — every transition becomes a short crossfade. The
  spectrum keeps moving, because the spectrum is the content, not decoration.
- **VoiceOver has something to say.** The transport buttons were four unnamed
  buttons; they have names now. The collapsed pill reads as one sentence — track,
  artist, the timer if one is running, how many files are on the shelf — rather
  than as a row of unlabelled images.
- A new icon, drawn in code, with all seven sizes generated from one source
  instead of six of them exported by hand.

### Changed
- **The spectrum's colours match the iPhone's.** Measured per bar off three
  now-playing waveforms on a real iPhone — a vivid pink sleeve, a
  red/orange/green one and a near-white pastel — Apple's bars sit at saturation
  0.08–0.38 and, whatever the cover looks like, all peak at the same brightness.
  Côte d'OS was running 0.63–0.81 and letting each colour keep its own light
  level, so a bright orange bar sat 0.30 above the magenta one beside it and the
  seam read as a break in the wave. The cover's colours are toned *down* now
  rather than boosted, and every bar draws at one light level, with the
  bar-to-bar shading doing the rest.
  - The cause was narrow: the Cover style was the only one that never passed
    through the ceiling the rest of the app used, and nothing checked. It does
    now — a test holds every bar of four very different synthetic sleeves inside
    the measured band.
  - **A bar takes its colour from its whole slice of sleeve, not the top half of
    it.** Each bar used to elect two colours, one per half, and draw from the
    upper one — so anything occupying the top of the artwork became the wave. A
    One Piece sleeve of reds, oranges and greens came out cyan, because that is
    where its sky is, and Ado's pink sleeve came out blue. Running both real
    covers through the pipeline against the phone's own bars: the phone reads
    olive → orange, and we now read olive → red → orange where we read cyan six
    times. A bar holds one hue from tip to foot on the phone — under 10° across
    its whole height — so the vertical run is a drain, not a second colour, and
    it is derived rather than elected.
- **One wave at three sizes.** The pill, the spectrum page and the fullscreen
  takeover are one continuous run that travels and grows, not three renderers
  that hand off to each other. Widening the pill's wave now gives you fewer,
  fatter bars in a taller pill — the page in miniature — instead of more
  hairlines.
- **The Safari dodge dodges the toolbar, not fullscreen.** Press `f` on a YouTube
  or Twitch video and there is no toolbar to avoid, so the pill stays centred and
  stays interactive.
- The wave costs less on battery: it steps between spectrum updates instead of
  easing, which is what the Dynamic Island does.
- The menu bar's Quit item says "Quit Côte d'OS". It has been saying "Quit
  NotchMate" since the rename, because the string catalog quietly overrode the
  code.
- Five tabs instead of six.
- **The tab bar is icons only, and the icons are two thirds larger.** They used
  to inherit the label's 13 pt and then the whole row was scaled to 0.72 to fit
  five German titles into the island — about 9 pt of icon. Without the titles the
  row fits unscaled and the glyphs draw at 15 pt, which is as large as the 24 pt
  pill band holds them: the same glyph is what the collapsed pill shows, and at
  17 pt the capsule's rounded ends were shaving its corners. The selected tab
  sits in a filled capsule where its title used to be. The names are still there
  on hover, and VoiceOver reads them.
- **Capture is somewhere to write.** It was a one-line field that looked like a
  search box and behaved like one — a thought longer than a few words scrolled
  sideways out of its own field as you typed it. It is a card that grows to four
  lines now. Return still files the note, Shift-Return breaks a line.
- The shelf centres its files instead of laying them out from the left edge with
  half the page empty beside them.
- The tab icons are no longer pressed against the top rim of the island.
- **The now-playing cover brings the player forward instead of deep-linking to
  the track.** A `spotify:track:` URI opens the song where it *lives* — its
  album — not the playlist you are playing it from, which is the one thing you
  wanted. The playlist is the playback context, and Spotify's scripting
  dictionary has no property for it; only the Web API does, and this app makes
  no network requests. Opening the player leaves you where you already were,
  which for anyone who pressed play in a playlist is that playlist.

### Removed
- **The spectrum's style and colour settings.** Solid, Shades, Alternating and
  Gradient are gone, along with the colour source picker, the two accent colour
  wells and the four Cover-style sliders. The wave takes its colours from the
  album cover, the way it does on the phone, and there is nothing left to set
  wrong. Existing preferences are simply no longer read.
- **The Claude tab.** It read Claude Code's OAuth credential out of the login
  keychain, called an undocumented usage endpoint with it, and wrote refreshed
  tokens back. Fine on my own Mac; not something to hand to strangers in a signed
  release. Its one side effect: the app now makes **no network requests at all**.

### Fixed
- Around eighty interface strings fell back to German in every locale, English
  included — the entire Obsidian pane, the whole capture surface, and two of the
  tab titles.
- Five Settings labels had been showing older text than the code intended, for
  the same reason as the Quit item. The volume/brightness toggle in particular
  still called itself experimental.
- A transient CoreAudio error during a suspend/resume cycle no longer disables
  the spectrum until the next screen wake. Spotify holds its output stream open
  while paused, so those cycles happen all day.
- The tap survives an output-device change. AirPods in or out used to kill the
  spectrum.
- A small CoreAudio string leak on the path the resume probe walks every two
  seconds.
- **Loud passages no longer drain the spectrum of its colour.** Each bar fades
  from its own colour toward a paler foot — measured off an iPhone's island,
  whose bars are about 13 pt tall — and that fade was applied in proportion to
  the bar. On the spectrum page's much taller bars it covered nearly the whole
  bar, so the louder the music got, the whiter the wave went, until fullscreen
  was white. The collapsed pill is unchanged; it was never tall enough for this
  to show.
- In Capture, the button showing Obsidian's icon opened Terminal, and the one
  that opened Obsidian was an unlabelled diamond next to it.
- **Capture finds its heading even when the heading has been decorated.** It
  matched the configured text exactly, so a daily-note template switching to
  Obsidian's Iconize plugin — `## :LiInbox: Capture` where the settings field
  said `## 📥 Capture` — stopped matching, and every capture from then on went
  into a second section the app appended to the *bottom* of the note, under
  "Plan für morgen". Nothing said so; you find out when you go looking for
  something you filed. Emoji, icon tokens and punctuation are ignored now, and
  the words are what count.

## [1.4.0] – 2026-07-24

The identity release: the app knows what it's called now, and when to
get out of the way.

### Added
- **Idle means invisible.** With nothing to show — no music, no timer, no live
  activity — the pill hides entirely. Moving the cursor into the area the
  expanded notch would occupy reveals the collapsed pill; hovering the pill
  (or the two-finger swipe) opens it as usual, and it fades away again when
  the cursor leaves. As a side effect, clicking "through" the hidden notch
  can no longer steal focus in the idle case: an invisible panel is now
  unconditionally click-through.
- **Safari-fullscreen dodge.** When Safari runs fullscreen, its URL bar moves
  up under the pill. The pill now slides to the right of the address field
  (located via Accessibility, with a generic fallback) and goes
  click-through for the duration; leaving fullscreen slides it back. Hover
  is suppressed while dodged — the capture hotkey stays the escape hatch.

### Changed
- The app is **Côte d'OS** now — display name, menu, settings window, the
  audio-tap device, and the product itself: the bundle is `CoteDOs.app`
  (project, targets and module follow suit). Only the bundle identifier and
  the data folders deliberately stay on their old names so settings and
  shelf data survive; expect macOS to ask for Automation and Accessibility
  again, the grants follow the app.
- With music playing and a focus timer running, the spectrum no longer gets
  pushed off-centre: the audio hero stays exactly under the notch and the
  timer (and shelf badge) grow rightward instead.
- The dodged pill's position was dialed in live (temporary sliders, then
  baked in): 70 pt right of the URL field, 8 pt above its centre line.
- The Settings window was rebalanced into five tabs — the near-empty Daten
  tab folded into Allgemein (with a version footer), the Features grab bag
  became Notch, and the window grew so nothing scrolls.
- CI builds the renamed project again (the workflow still pointed at
  `Ledge.xcodeproj` and failed on every push since the rename).

## [1.3.0] – 2026-07-21

The polish release: better colors, bouncier motion, and one honest bug fix
that had been hiding since the spectrum tap learned to hear non-music audio.

### Added
- **Spectrum-only pill.** A new toggle in the now-playing settings replaces the
  mini cover in the collapsed pill with a wider, slightly taller wave. This
  mode exists to be watched, so it takes the room it needs — and it comes with
  two controls: bar count (6–32, at 32 every bar is its own analyzer band) and
  pill width (36–140pt); the bars spread evenly, so fewer bars means wider
  gaps. The music tab keeps its cover.
- **Claude tab**: usage limits at a glance plus a gearbox-style shifter for
  model/effort/mode of the Claude desktop app.
- **Per-tab visibility toggles** — hide the tabs you never open.
- **Focus-session tracking** in the pomodoro timer, logged to Obsidian.
- The "Cover" spectrum style now quantises each bar onto a real per-bar palette
  taken from the slice of artwork the bar sits over, with four tuning sliders
  (palette size, brightness steps, saturation, brightness). The old version
  masked a blurred cover and smeared neighbouring colors into every bar.

### Changed
- The app is **Ledge** now, all the way down: project, targets and the app
  bundle itself (`Ledge.app`). Only two invisible legacies remain so existing
  installs keep their data — the bundle identifier (your settings) and the
  Application Support folder name (your shelf). Updating from a
  `NotchMate.app` build means granting Automation and Accessibility once
  more; the grants follow the app.
- Cover accents are tone-mapped instead of floored: muted sleeves stay muted
  instead of turning neon, black-and-white covers with a faint color cast get
  that cast as a washed-out tint instead of plain white, and the
  gradient/alternating styles use up to two more colors the sleeve actually
  contains when it has them.
- Neutral can win the accent now. A mostly-white sleeve with a face used to
  tint the whole wave skin-orange, because grey pixels couldn't vote; when the
  neutral area outweighs the strongest hue's vividness, the wave goes luminous
  silver-white instead. A bold red logo on white still wins.
- The wave tapers toward its edges (full crest in the middle, ~45% at the
  rims), so it reads as a swell instead of a rectangle.
- The island opens with a visible overshoot-and-settle now, like the iPhone's.
  Closing stays deliberately calm — overshoot on the way out reads wrong.
- Opening and closing are one continuous gesture now, verified frame by frame
  with a new choreography test that renders the staged walk through its real
  spring curves. While music plays, the island used to sit still for 200 ms
  before opening (two stages of the walk change nothing in that case — they're
  skipped now), and closing braked to a near-standstill at every intermediate
  stage because the rests matched the spring's settling time. Each stage now
  retargets the spring while the silhouette is still moving.
- Beat peaks overdrive a bar's tip (and its glow) toward white-hot, like a
  VU meter pushed into the red — only levels above 70% reach it, so it reads
  as energy, not as a palette change.
- The expand animation stopped dropping frames. Profiling the live app
  showed the island's drop shadow and rim gradient being software-rendered
  on the main thread for every frame of the morph, the wave's bars each
  rasterizing their own gradient and glow 30× a second, and all five tab
  pages being built mid-spring. The chrome and the wave are GPU-composited
  now, and the pages mount only once the island has come to rest — shape
  first, content into a still frame.
- The spectrum got stage lighting: no more grey-washed edge bars (the Shades
  style is a full-saturation brightness ramp now), gradients run through up to
  three colors the cover actually contains, and every bar throws a glow that
  pulses with its band.
- The bars dance to compressed masters now, not only to dynamic audio. Each
  band tracks its own running average and the level leans on the deviation
  from it — a kick punches to the top even on a loudness-normalized Spotify
  master that barely moves in absolute dB.
- New tab glyphs: the music tab wears the app's waveform instead of a generic
  note, and the Claude tab got Claude Code's crab.
- The spectrum analyzer resolves 32 bands (was 6) over a 2048-point FFT (was
  1024 — the finer bins keep the low bands distinct), enough to feed the wide
  pill at its maximum bar count; the smaller waves bucket down as before. Its
  time constants tick on audio time instead of the wall clock — deterministic
  under callback jitter, and testable faster than real time.
- Silence costs almost nothing now. The analyzer used to run a 1024-point FFT
  ~46 times a second against digital zeroes and push 30 UI updates a second
  for an unchanged flat wave — the "high energy use" Battery settings kept
  flagging. A peak gate puts the analysis to sleep after two silent seconds
  (the first audible sample wakes it), and the publisher only touches the
  main thread when a level actually moves.
- New original waveform app icon (the earlier one leaned on the Obsidian logo).

### Fixed
- The pill's hover and click areas now match what it draws. With only
  non-music audio playing (a YouTube tab, a call), the visible pill was wider
  than the area that reacted to the cursor — its outer edges were dead.
- Dragging a file onto the notch works again (broken by the click-through
  gate).
- Volume-key clicks and mute double-logging in the HUD.
- Two force-unwrap crashes that never fired but could have: the launch-path
  directory lookup and the Accessibility menu-bar walk now degrade instead.

## [1.2.1] – 2026-07-06

- **Fixed** the collapsed notch stealing focus from apps under its hidden
  footprint — clicking "through" the invisible expanded area now reaches the
  app you actually see.
- **Fixed** a spectrum freeze (the tap tore itself down from its own IO queue)
  and rebuilt the tap when the output device changes, so AirPods handoffs
  don't silence the bars.
- **Added** pomodoro timers with named presets, a passive readout in the pill,
  and optional auto-chaining. Yes, that's a feature in a patch release.

## [1.2.0] – 2026-07-06

- **Added** menu-bar overlap detection: when the frontmost app's menus reach
  the notch, the pill hides instead of fighting them for the pixels.
- **Added** cover-aware spectrum colors — the wave tints itself from the
  album artwork.
- **Fixed** a batch of hover/collapse edge cases and hardened the capture
  tab's link output and track-open behavior.

## [1.1.0] – 2026-07-04

- **Changed** the notch into a detached, iPhone-style island with a staged
  expand/collapse morph — the version where it started looking like the thing
  it's imitating.
- **Changed** the music tab: live audio spectrum from a system tap, and the
  now-playing hero collapses into the pill.
- **Changed** the capture tab into a compact pill with vault label and quick
  actions.
- **Fixed** the volume HUD popping open on its own.

## [1.0.0] – 2026-07-02

First release: now-playing controls in the notch, file shelf with drag & drop,
Obsidian quick capture, live activities (battery, audio routes), and a
volume/brightness HUD that replaces Apple's gray OSD.

[1.5.0]: https://github.com/Scxttk/CoteDOs/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/Scxttk/CoteDOs/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/Scxttk/CoteDOs/compare/v1.2.1...v1.3.0
[1.2.1]: https://github.com/Scxttk/CoteDOs/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/Scxttk/CoteDOs/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/Scxttk/CoteDOs/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/Scxttk/CoteDOs/releases/tag/v1.0.0
