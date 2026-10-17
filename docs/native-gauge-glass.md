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

`docs/screenshots/native-showcase/readme-header.jpg` is a README header: eight popovers from seven providers
fanned out under their menu bar gauges, over the Golden Gate Sunset aerial. Every popover is the production view
fed a month of generated usage for fictitious accounts (`NativeOrbitShowcaseScene`); nothing is drawn to imitate
it. Each provider reports only the windows it really has, in its own brand accent, and each card shows a different
situation:

- Amp Free's daily meter on course to run out before it renews (amber fuel).
- Codebuff credits beside its weekly window.
- Codex weekly-only, with three banked resets and an idle personal account.
- Claude in front, a light session with room to spare (green tortoise), extra usage and a second account.
- StepFun running every session to its limit.
- Bedrock spend against a monthly budget.
- Kiro's monthly credits exhausted (red fuel) with a second account to switch to.

Past windows cost what the current one does for the same work, and inactive accounts stop where they were left,
so each chart's history agrees with its projection. The clock is set so that "now" is always a weekday afternoon.
To recreate it, take a still from the aerial (Wallpaper settings downloads it), build, and capture the scene window:

```sh
ffmpeg -ss 30 -i ~/Library/Application\ Support/com.apple.wallpaper/aerials/videos/4207734D-74FE-4F92-B5E1-6EC8DEE24A15.mov \
  -frames:v 1 -vf crop=3840:1606:0:0 -q:v 2 backdrop.jpg
open -n --env CODEXBAR_PREVIEW_BACKDROP=$PWD/backdrop.jpg "$HOME/Applications/CodexBar Native.app" --args \
  --native-preview --preview-scene --preview-light
screencapture -x -o -l <window id> header.png
```

For a single popup, `--native-preview --preview-orbit --preview-open --preview-window --preview-showcase
--preview-provider claude --preview-light` draws it as a rounded card over the backdrop.

Both panels blend their material within the window, so the capture shows only the backdrop behind the glass,
never the screen. Use a window-only capture: the panel belongs to an inactive app, so a region capture of the
screen shows whatever is in front of it. The panel takes key without activating the app. Don't make it ignore the
mouse: that stops it taking key, and its glass goes flat.
