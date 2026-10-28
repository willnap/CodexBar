# Native gauge glass

The popup dials draw remaining usage and reset countdowns with the system Liquid Glass material
(`glassEffect`). Nothing paints highlights, gradients or shadows to imitate it.

## Construction

- **Rails:** usage and countdown share the authored geometry: radii 108/82/56 and an 18-unit width on the
  256-unit canvas, with a round cap at each end (`NativeOrbitRail`). The countdown rail was briefly slimmed to
  12 units and is back at the authored width.
- **Cuts:** pieces are cut radially, as in the authored symbols. The usage draw front and every cut between
  countdown segments round their corners by 3.5 units (`NativeOrbitSymbol.cutCorner`). That is enough for the
  glass rim to wrap the edge while the cut still reads as a gauge reading. Caps stay round. A cut that falls
  inside a cap stays sharp, so on short inner rails a cap still spans several segments.
- **Readings:** the centreline still spans each reading exactly. At full, the usage piece covers the outline in
  `NativeOrbitArtwork.swift`.
- **Material:** `.clear` glass tinted with the provider colour: 80% for usage and 60% for the countdown, so the two
  read apart. Clear glass keeps the system's lensing and rim light visible. At 90% tint over a blank track, regular
  glass renders as opaque paint with a drop shadow.
- **Clearance:** each countdown rail stops 14 units of arc short of the usage arc's caps on its lane.
- **Container:** each lane's usage and countdown glass share a `GlassEffectContainer`, because glass cannot
  sample other glass. All countdown segments are islands of one glass shape, so each keeps a complete rim.
- **Chart readings:** the dots on the now and hover line are beads of the same glass, in one container so
  close readings flow together. A prediction is barely tinted, as its open dot was.
- Empty tracks stay faint and neutral. Reduce Transparency fills the same shapes, and draws the original
  dots, with solid colour.

## Judging it

Glass draws a flat, untinted inactive appearance whenever its window is not key. A window opened from a shell
launch is not allowed to activate the app, so captures of an ordinary window show every glass variant as the
same grey band. The `--native-popup-preview-provider` inspection window is a non-activating panel that takes
key by itself, so it shows the glass exactly as the status popup does. Capture it with
`screencapture -x -o -l <window id>` while it is key. If its title is greyed out, the capture shows inactive
glass and says nothing about the design.

`Path.contains` flattens long curves by up to about half a unit, so geometry tests keep their sample points
clear of edges. Rail arcs are split at fixed 15° stops so that overlapping pieces flatten identically.

## Showcase renders

The README images in `docs/screenshots/native-showcase/` are the production views fed a month of generated usage for
fictitious accounts (`NativeOrbitShowcaseScene`); nothing is drawn to imitate them. Each stays under the repository's
2 MB file limit.

- `hero-{light,dark}`: `--preview-scene`, the combined window on its All page, three and three-quarter columns wide,
  cropped to the window with an even margin under the right end of a full-width menu bar, over the Solar Gradients
  wallpaper at midday or after dark (Sonoma if macOS hasn't downloaded it).
- `before-after`: a screenshot of CodexBar 0.82.1 built from upstream `main`, open on real accounts, beside the hero
  scene in light mode at the same height (`CODEXBAR_PREVIEW_NOTCH` draws a notched MacBook's menu bar to match;
  `CODEXBAR_PREVIEW_WALLPAPER_FRAME` the same time of day). The desktop outside the original menu is continued from the
  wallpaper beside it, where another window covered it. `ReadmeOriginalMenuShotTests` can instead open the original
  menu on the showcase's fictional logins.
- `feature-*`: cards with the same padding on every side, each whole columns (240 points between dividers) cut from the
  hero, the accounts scene held seven hours into its forecast
  (`CODEXBAR_PREVIEW_INSPECT_HOURS=7`), `--preview-scene-trouble` or the motion recording, with rounded corners over
  the night wallpaper.
- `icon-{light,dark}`: `NativeIcon.icon` exported with Xcode's `ictool` (`--platform macOS --rendition Default|Dark
  --design-generation 27`).

Readings arrive every few minutes in whole percentages, accounts in use sit early in their windows after earlier
windows drained deep, and spend and tokens are a heavy user's: about 1.3 billion tokens a day on Claude Max 20x at
$0.52 per million with cache reads, 1.4 billion on Codex Pro, and the other services close enough behind that the
lead on the All page changes hands. Codex was the main tool earlier in the month and Claude has overtaken it. The clock
is set so that "now" is always a weekday afternoon for the viewer; logins elsewhere (China, the US) work on their own
hours, so their histories differ in shape. Each account's quarter-hour request slices add up to its daily totals.

Scenes without a wallpaper or `CODEXBAR_PREVIEW_BACKDROP` sit on nothing, so their captures keep transparency. The
scene's panel always reports itself key: glass draws its tint only in the key window, and macOS refuses focus to the scene
while someone works in another app. Build, then capture each scene window in each appearance:

```sh
open -n /Applications/CodexBar.app --args --native-preview --preview-scene --preview-light
# --preview-scene-accounts, --preview-scene-api, --preview-scene-trouble; --preview-dark for the dark set
screencapture -x -o -l <window id> combined-light.png
```

The `motion` animation records `--preview-scene-motion`: the combined window four whole columns wide (All, both Claude
logins, Codex), where OpenAI has just reset Codex's spare login. With `CODEXBAR_PREVIEW_PLAY=motion` a drawn pointer
starts two seconds after the scene appears and uses the window as a person would, its moves sent to the window as real
hover, click and scroll events: it opens the window (the ignition check), switches All to money, reads back along All's
chart and Claude's, swipes one column to the spare Codex login, rests on its "Reset by OpenAI" mark, clicks Use (in
memory only), steps through Week, Month and Day, and returns to tokens. The real pointer is ignored. Record only the
window and without the pointer (a ScreenCaptureKit stream with `showsCursor` off; `screencapture -v` also records the
real pointer), over a solid backdrop in GitHub's page colour (`CODEXBAR_PREVIEW_BACKDROP`), then extract frames at
15 fps with ffmpeg and encode an animated WebP (`img2webp -loop 0 -lossy -q 60 -m 6 -d 67`), which stays under 2 MB
where a GIF of the same recording is 7-8 MB. `CODEXBAR_PREVIEW_PLAY=startup` reruns the ignition check
alone in any scene.

`--preview-scene-services` fans out one popover per service, and `CODEXBAR_PREVIEW_BACKDROP` puts an image behind any
scene. `CODEXBAR_PREVIEW_DAYS` sets the combined window's range (1, 7 or 30).

For a single popup, `--native-preview --preview-orbit --preview-open --preview-window --preview-showcase
--preview-provider claude --preview-light` draws it as a rounded card over the backdrop.

Both panels blend their material within the window, so the capture shows only the backdrop (or transparency) behind
the glass, never the screen. Use a window-only capture: the panel belongs to an inactive app, so a region capture of the
screen shows whatever is in front of it. The panel takes key without activating the app. Don't make it ignore the
mouse: that stops it taking key, and its glass goes flat.
