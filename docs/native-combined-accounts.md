---
summary: "Combined account menu for the native gauge interface, automatic or always"
read_when:
  - Working on the native account pager or combined usage overview
---

# Combined native account menu

The native gauge interface automatically uses one menu bar item when **more than three distinct enabled
providers** have a saved account or cached usage evidence. An enabled provider without a connection does not
count. Three or fewer connected providers retain their separate items. Saved accounts continue to count when
a refresh fails, so an outage does not rearrange the menu bar.

Settings › Menu Bar › **Combine into one icon** chooses between that default (**With 4 or more services**) and
**Always**, which combines every connected service even when only one is connected (`nativeCombinesAllServices`).
With nothing connected there is no combined popup to open, so each enabled service keeps its own gauge.

The combined item is one menu bar button holding the full gauges of the one or two most recently used accounts,
side by side, drawn exactly like a service's own gauge. The most recent is also the account the popup opens on.
Recency comes from quota increases, timestamped token/cost activity, or credit consumption. A routine polling
timestamp does not count as activity. Ties use active login status and stable account identity.

The popup lays its pages side by side, 240 points each with a divider between them, like a service's own account
columns. Up to three pages show in full; with more, it shows two and a half, so the cut-off column shows that the
strip scrolls. It never exceeds the screen's width. Accounts remain grouped by provider, with the combined
overview immediately to the left of the first account. SwiftUI's native view-aligned scrolling handles
momentum and snaps a column to the leading edge; selecting a page brings it to the leading edge, or as far as the
strip scrolls. Left/right arrow keys, accessibility adjustment, and clickable symbol indicators
navigate the same scroll position. Indicators show provider logos and expand the selected provider to show
its account symbols. The indicator keeps a compact moving viewport, shrinking symbols at its edges when the sequence overflows.

Every page runs down behind the page control to the toolbar, which rises into the empty foot of each account's
footer. Account pages carry a hint of their service's colour, and the active login of a service with several a
little more, so services read as separate areas side by side.

Page identities include the provider. Their order stays fixed for a showing, including while active logins or
usage readings change. Account pages reuse the normal native instruments, history, warning actions, and login
switching. The bottom toolbar shares the time range, refreshes the connected providers, and opens settings for
the current provider.

The popup is kept between showings, like a service's own popup. A showing opens on the most recently used account
with that moment's page order and width. A service's pending background change, and its Claude archive reload, wait
for `popoverDidShow`, once the popup has finished appearing: a rebuild queued behind a `Task.yield` still runs
before the run loop draws, so the window used to wait for it. The toolbar receives rows each service has already
prepared, and `preparingInspection` returns a row prepared for the same history unchanged instead of rebuilding it.

An opening draws what the readings already produced. A closed popup's refresh (`prepareForOpening`) builds each
account's chart lanes, predictions, spend history, warning lights and reset redemptions when the readings change.
The clock only redoes what reads it: a minute keeps the lanes and observation dates, which change with their history,
range or day, and clears predictions, spend, marked events and lights, which follow the clock to the minute like the
open popup's own clock. Nothing derived from history is recomputed while drawing: reset redemptions come from the
prepared history and the overview renames each account's ordered lane instead of sorting it again.

Measured on the release app with three services and two and a half columns, from a posted click to the popup window
being on screen (2026-10-21; the click handler's own time in brackets, from the `Combined popup shown` log line):

| Opening | Before | After |
| --- | --- | --- |
| Again within seconds | 215–290 ms (140–200 ms) | 121–132 ms (45–50 ms) |
| After two and a half minutes closed | 300–600 ms (225–494 ms) | 131–169 ms (53–87 ms) |
| During a refresh | up to 1.5 s | the click no longer waits for the rebuild it triggered |
| First after launch | about 460 ms | about 420 ms (renders everything once) |

The log line's `waitedMilliseconds` is how long the click sat in the event queue before its handler ran. The idle
openings above were measured soon after a launch. After hours idle macOS compresses much of the app's memory (880 MB
of 1.6 GB was compressed once), and an opening that has to decompress what it draws took about 580 ms; the app's
memory footprint is the remaining cause there. A click during a refresh can also wait behind the menu bar icon's
rebuild of the account rows (one measured at 94 ms).

## Overview data

The overview is laid out like an account page, with no captions. Its dial is a pie on the account dials' outer
lane, in their glass: each account's share of the range's tokens as one rounded island in that account's colour,
marked with its service where it fits, with the share in the island's tooltip. The top corners total spend (when
every cost is in one currency) and tokens, as on an account page. Banked resets and extra usage belong to one
account each and do not add up meaningfully, so the bottom corners stay empty.

Its chart is the account chart itself, with one lane per account: the account's longest quota window, from that
account's own prepared lanes, in the same colour as its share and page tint. Hovering reads every lane at once.

Distinct account-attributed machine reports and distinct profile reports contribute independently. Repeated,
unattributed machine-wide reports contribute once per provider (to that provider's first account), and do not
overlap known account totals.

## Offline validation

Use the normal repository test commands, which suppress Keychain access:

```sh
./Scripts/test_fast.sh --filter NativeCombinedAccountsTests
make test
make check
```

The fixture entry point runs before credential stores initialize and uses the production page strip. Build the
native bundle, which includes the authored SF Symbol catalog and native app configuration:

```sh
NATIVE_BUILD_CONFIGURATION=debug ./Scripts/build_native_app.sh
open -n "$HOME/Applications/CodexBar Native.app" --args --native-preview --preview-combined \
  --preview-output /tmp/codexbar-combined
open -n "$HOME/Applications/CodexBar Native.app" --args --native-preview --preview-combined --preview-overview \
  --preview-output /tmp/codexbar-overview
```

Each fixture has four providers and eight accounts. The output contains app-view metadata, a synthetic
symbol artwork sheet, and `popup-render.png`, SwiftUI's offscreen render of the production popup with its pages
laid side by side (the AppKit-hosted charts, page control and glass do not render there). The latter renders the actual indicator glyphs in each selection state without
sampling a window or screen. Add `--preview-control-check` to exercise the production input element and
record the strip's actual scroll offset, and whether the selected page is in view, in `page-control-check.json`. Events are delivered directly to the
fixture control, without posting events to the desktop. The app-view bitmap exporter may
omit native composited scroll layers, so its bitmap alone is not evidence of the popup's visual appearance.

Do not use the upstream `package_app.sh` script for this native redesign. That bundle omits the authored
native asset catalog and native app configuration.

## Page-control port

The indicator is a SwiftUI/AppKit port of `UIPageControl`, following the user's explicit request to retain the
AppKit app. The Catalyst control is used as a rendering and geometry reference; no private UIKit bridge is
shipped. The standalone probe in the workspace validation folder demonstrates the real Catalyst control.

Custom images use the native Footnote/Small SF configuration, retain their natural widths, and have eight
points of spacing. The moving viewport shrinks overflowing symbols. The native AppKit input element owns
pointer capture, keyboard focus, wheel phases and one adjustable VoiceOver element. Clicks animate the
account transition; continuous scrubbing updates the native scroll position immediately. Hold-to-scrub and
repeating edge movement traverse the frozen full account sequence, even when provider symbols expand or
collapse. Releasing outside, cancellation, disappearance, disabling, or changing the page inventory ends the
gesture. A scroll reader issues programmatic page changes while native scroll geometry reports the
visible page. Pending navigation prevents intermediate animation targets from collapsing the selected
provider group or leaving the indicator ahead of its page. RTL and vertical directions, single-page hiding, symbol overrides, tints and background styles are
supported by the component. Reduce Motion and Reduce Transparency follow the system settings.

The fixture comparison sheet includes a render using the same standard SF Symbols as the Catalyst reference.
This is an independently rendered port, not Apple's UIKit binary. Automated geometry and input verification
does not establish pixel identity, physical trackpad behavior, or the user's visual acceptance.
