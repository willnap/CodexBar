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
strip scrolls. It never exceeds the screen's width. Either side edge can be dragged, with the system's
frame-resize cursor, to make the popup as narrow as one page or as wide as every page side by side; the cursor's
arrows show which ways the width can still go. The popover stays anchored to its button and grows evenly about
it, so the dragged edge follows the pointer at twice the width change (once the screen edge holds the other side,
one for one). The chosen width is kept across launches (`NativeCombinedPopupWidth`).

The combined overview comes first. Accounts with usage left follow, most recently used first; drained ones (a
current window exhausted or down to its low-fuel reserve, the lowest quota warning, as the fuel light reads it)
go to the back, each on its own. A provider's accounts that all have usage left stay side by side, so they can be
compared and switched; a passed reset counts as refilled. The order is frozen for a showing and accounts that
appear meanwhile join its end. SwiftUI's native view-aligned scrolling handles momentum and snaps a column to the
leading edge; selecting a page brings it to the leading edge, or as far as the strip scrolls. Left/right arrow
keys and accessibility adjustment navigate the same scroll position.

The popup shows no page control (2026-10-28): the pages begin at the popup's top edge, with no band above them, and
the columns themselves show where the strip is. `NativeCombinedPageIndicators` and its model are kept, unplaced, for
the fixtures below. When it was shown, the page control sat above the dials like a tab bar, its marks in the dials' own empty top margin (11 points
down; each page's content starts 16 points down), so it adds no band of its own. Its ink is quiet (30% for pages out
of view, 80% for those in it): every page in the window lights its mark, and a page part in lights it by as much of
it as shows, in twentieths, so the marks read like the window's extent over the strip. Marks are placed by their
measured ink, not their image boxes, so unevenly padded custom art sits on the same line as the system symbols. Its
marks follow the pages: one provider logo per run of a
provider's adjacent pages, so a drained account sorted away from its others shows a logo of its own there. The
selected run expands to its account symbols, which emerge from the logo and sit with it on one platter, closer
together than the marks outside it. The control keeps a compact moving viewport, shrinking symbols at its edges
when the sequence overflows. System symbols keep the page control's one configuration (13 pt, small scale).
Custom provider marks, mail and project symbols and website masks were drawn to fill a fixed box, which made a
wide mark (Claude's, iCloud's) short and small beside them; each is scaled from its measured ink to cover a
system circle's 11 pt area, no wider than the widest system mark (14 pt).

Every page runs down behind the toolbar. The toolbar has no bar of its own: as in
Liquid Glass, its controls float as glass over the pages (the refresh arrow and age in one capsule, with 8.5 points
of glass past their ink on every side, the range
control, the settings gear), so each service's tint runs on underneath. A service's own popup floats the same
toolbar over its columns. Account pages carry a hint of their service's colour, and the active login of a service
with several a little more, so services read as separate areas side by side.

Each account's footer names its login (its email) and, beside it, a badge for its plan: white type on a small
rounded square of the service's colour, in the style of `20.square.fill`, darkened only as far as the type needs for
4.5:1 contrast and padded evenly around its ink. It keeps its size in a crowded footer; the name shortens instead. It
reads: a usage multiplier when the plan has one ("Claude Max 20x" and
"Pro 20x" read 20×, "Pro 5x" 5×), otherwise the plan's name without the service's words ("Pro", "Plus",
"Allegretto"). The plan comes from the menu's own plan text, so every provider that reports one has a badge. A
login with no email shows the name its service gives it instead: Kimi Code's profile (`/coding/v1/me`, read with
the usage and never holding it up) has no email for a phone login, so its nickname shows, and its `user_level_name`
("Ultra") is the plan when the usage report names none. claude-swap's reports carry its own source label where a
plan goes; its rows take their plan from the account's Claude profile that claude-swap keeps beside its backups
(`~/.claude-swap-backup/configs`, no credentials), whose rate-limit tier names it. A login nothing identifies shows no
name rather than its service's. The name takes the room it needs before anything else gives.

The toolbar's controls sit as far from the footer above them as from the popup's edge below (3 points of their own
above, after the footer's 6; 9 below).

Page identities include the provider. Their order stays fixed for a showing, including while active logins or
usage readings change. Account pages reuse the normal native instruments, history, warning actions, and login
switching. The bottom toolbar shares the time range, refreshes the connected providers, and opens settings for
the current provider.

The popup is kept between showings, like a service's own popup. A showing resumes where the pages were left (the
page at the leading edge and the selection) when the popup was closed for less than six hours and those pages still
exist; otherwise it opens on the most recently used account. The overview always stays built, so its charts keep
what they drew rather than rising from nothing at each opening. A service's pending background change, and its Claude archive reload, wait
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

## Scrolling

Scrolling the pages ran at about 20 frames a second on a 120 Hz display. Three causes, largest first:

- Hover followed the pages. Charts sliding under a resting pointer reported a new hovered instant every frame, and
  every column re-rendered its dial, instruments and lights at that instant, about 40 ms a frame. While the pages
  move (`NativeOrbitPopupState.isScrolling`) hover is ignored and the dials show live readings; the next pointer
  move inspects again.
- Background changes rebuilt the columns mid-gesture. Each store change replaced every account, recomputed every
  chart and light, and made SwiftUI compare the old and new histories entry by entry. Changes now wait while the
  pages move (`holdsPresentation`) and land when they settle, and a rebuilt row equal to the shown one keeps it
  with everything prepared from it: rows are `Equatable`, and metrics compare their readings, not their caches.
- The lazy stack built a page as it scrolled in and discarded it as it left, 40–70 ms a page. Pages are now built
  once per showing: an opening builds and updates only the pages on screen (`pagesInView`), the rest are built a
  frame apart once the popup has appeared, and the ones off screen are released when it closes, so the next
  opening still updates only its own. A swipe that starts before every page is built builds the rest at once
  rather than slide in a placeholder.

Per swipe of about a second (release app, 2026-10-22; `CODEXBAR_SCROLL_PROBE=1` logs a `Combined scroll frames`
line per scroll with the display-link frame intervals and the pages built during it):

| | Before | After |
| --- | --- | --- |
| Frames drawn | 14–23 | 86–94 |
| Typical frame | 42–66 ms | 8.3 ms |
| Longest frame | 86–136 ms | about 45 ms |
| Frames missed | 93–122 | 5–13 |
| Pages built while scrolling | 2 | 0 |

The first swipe after an opening still misses about 40 frames while the pages built after it appeared draw for the
first time, and the menu bar's minute refresh, which rebuilds every account's row on the main thread, can stall a
swipe it coincides with.

## Overview data

The overview compares recorded tokens by default. Clicking the top-left spend or top-right token readout
switches both charts to that absolute unit. Spend is available when the recorded amounts share one currency;
different currencies never share a scale. Missing readings remain unknown.

A solid, borderless capsule follows the selected complication's circle. The dial keeps the same center and
top spacing as every account column; the popup clips the traveling capsule at its existing edge. The same
interpolated shape fills the capsule and masks the inverted readout ink, so glyphs invert only where it covers
them, including during a reversal. There is no selection-based text crossfade through an unreadable color.

One smooth 0.35-second transition controls the capsule, pie boundaries, product/account marks, curves, area
fills and reading beads. Reduce Motion suppresses that transition. Accounts keep their page order between
units, and zero shares retain their identities while collapsing, so neighboring boundaries remain a partition
of the ring. Icons consume the same interpolated angles as the bands and stay on their centerline; they fade
as space becomes too tight for a full identity. Wider sectors give the secondary marks up to eight more
design points of separation. Arc direction responds to the segment's position so provider marks stay above and
account badges below the product, receding smoothly at the circle's vertical extrema before changing sides.
The bands use true circular gauge-style corner fillets and parallel cuts of equal physical width, including
the closing seam. Template icons remain content of native
regular Liquid Glass for adaptive foreground contrast.

Both token and spend histories are prepared in one sample pass. Unit selection reads the already prepared
arrays rather than clearing the graph or scheduling another scan. The native plot hosting boundary installs
its own copy of the shared transition. All accounts use one absolute scale per metric; rendering normalizes
against that one common maximum and keeps the plot domain fixed so curves and overlay beads interpolate to
the same heights. Raw amounts and accessibility values retain their actual units. A different range or changed
source waits for matching prepared data instead of displaying old totals under new bounds.

The history shares the account graphs' line weight, area fill, grid, glass reading beads, rounded reference
marker, time detail pill and axis row. Hour labels and hover times retain the user's **system clock cycle** even
when app language or a SwiftUI display locale has another regional default. For example, a British display
locale with the user's US 12-hour clock shows `1 pm`; an actual 24-hour preference retains `13`. Day-period
wording and date order still follow the display language and region. Hover detail keeps minute precision.
Each plotted instant uses the trailing selected window ending there. Hovering or dragging reads that same
instant for the ring, both totals and chart markers; leaving restores live readings.

Day is the trailing 24 hours, Week the trailing 7 × 24 hours, and Month the trailing 30 × 24 hours, including across
daylight-saving changes. The same bounds apply to the account charts, spending bars, reset counts and
complications. Dated requests split boundary days exactly when their coverage is complete. A whole-day or
whole-hour bucket is never prorated; incomplete boundary coverage stays marked partial. Nonprojected charts
label the start, exact midpoint and Now, evenly spaced across the plot. Column tints extend under the divider
and its top and bottom margins.

Distinct account-attributed machine reports and distinct profile reports contribute independently. Repeated,
unattributed machine-wide reports contribute once per provider (to that provider's first account), and do not
overlap known account totals.

Claude transcript reports carry account attribution when their organization belongs uniquely to the verified
ClaudeSwap row. Their physical collection scope remains this Mac, but separate organizations are separate
account reports in All. Restored reports recover that attribution from their validated slot/principal/organization
owner digest, including cache files written before the flag was recorded. Ambiguous organization ownership and
ambient machine reports retain the existing exclusion and deduplication rules.

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
open -n /Applications/CodexBar.app --args --native-preview --preview-combined \
  --preview-output /tmp/codexbar-combined
open -n /Applications/CodexBar.app --args --native-preview --preview-combined --preview-overview \
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

### Recorded chart continuity

The combined chart prepares every range from the native range control together, including tokens and each range's available money currency. Selecting a range synchronously selects its cached snapshot; the selection is excluded from the preparation task's source identity, so a click cannot start or restart the 49-sample calculation. Initial display waits for the complete range set.

Account data or the clock can start a replacement preparation. Every range from the preceding set stays available during that work, and all replacements publish together. Series, time bounds, labels and scrubbed readings come from the selected snapshot; cancelled or superseded source revisions cannot replace it.

Samples use their fixed position within the plotted range as identity, while retaining their exact observation dates. Missing prefixes do not renumber the first recorded run, and real internal gaps still split lines. The hosted native chart applies the shared transition to its whole configuration, including recorded lines and their shaded areas, so refreshes and Day/Week/Month changes do not briefly erase the plot or hard-cut its fill.

Pie account badges follow the same policy as individual columns: use the existing badge only when the provider has multiple accounts. A provider with one account has its product mark and any configured provider mark, without an invented account symbol.

Segment identity artwork stays in template rendering mode inside its tinted native glass. The sector does not impose a foreground style outside that glass: the material owns the adaptive vibrant foreground for product, provider and account marks. Named account artwork also explicitly requests template rendering, matching website and product artwork.
