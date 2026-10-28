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

`docs/screenshots/native-showcase/readme-light.png` and `readme-dark.png` are the README screenshot: the combined
window opened on its All page, six columns wide, under the combined menu bar item. Every page is the production view
fed a month of generated usage for fictitious accounts (`NativeOrbitShowcaseScene`); nothing is drawn to imitate it.
Each service reports only the windows it really has, in its own brand accent, and pages take the production order
(most recently used first). Most accounts run with room to spare; four lamps cover different realms without any
red:

- Claude Max 20x a little ahead of pace on its week (amber hare), with Sonnet's own allowance and extra usage.
- Codex Pro with a saved reset just added (green) and three banked.
- Kimi Code on pace across its session, week and monthly pool (no lamp).
- GLM Coding Plan with half its week unused and under a day to go (green tortoise).
- Gemini Code Assist during a provider incident (amber status lamp).
- DeepSeek pay-as-you-go against a prepaid balance, the sixth page, counted on the All page.

Each account's quarter-hour request slices add up to its daily totals, so the All page's chart can split a day at
any range start. Past windows cost what the current one does for the same work, and accounts stop where they were
last used, so each chart's history agrees with its projection. The clock is set so that "now" is always a weekday
afternoon.

The window sits on nothing, so the capture keeps transparency and suits GitHub's light and dark pages. The scene's
panel always reports itself key: glass draws its tint only in the key window, and macOS refuses focus to the scene
while someone works in another app. Build, then capture the scene window in each appearance:

```sh
open -n "$HOME/Applications/CodexBar Native.app" --args --native-preview --preview-scene --preview-light
screencapture -x -o -l <window id> readme-light.png   # and again with --preview-dark
```

`--preview-scene-services` instead fans out one popover per service, as the earlier header did, and
`CODEXBAR_PREVIEW_BACKDROP` puts an image behind either scene. `CODEXBAR_PREVIEW_DAYS` sets the combined window's
range (1, 7 or 30).

For a single popup, `--native-preview --preview-orbit --preview-open --preview-window --preview-showcase
--preview-provider claude --preview-light` draws it as a rounded card over the backdrop.

Both panels blend their material within the window, so the capture shows only the backdrop (or transparency) behind
the glass, never the screen. Use a window-only capture: the panel belongs to an inactive app, so a region capture of the
screen shows whatever is in front of it. The panel takes key without activating the app. Don't make it ignore the
mouse: that stops it taking key, and its glass goes flat.
