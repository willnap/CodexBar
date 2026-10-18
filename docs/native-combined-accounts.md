---
summary: "Automatic combined account menu for the native gauge interface"
read_when:
  - Working on the native account pager or combined usage overview
---

# Combined native account menu

The native gauge interface automatically uses one menu bar item when **more than three distinct enabled
providers** have a saved account or cached usage evidence. An enabled provider without a connection does not
count. Three or fewer connected providers retain their separate items. Saved accounts continue to count when
a refresh fails, so an outage does not rearrange the menu bar.

The combined item shows up to three recently used accounts. Recency comes from quota increases, timestamped
token/cost activity, or credit consumption. A routine polling timestamp does not count as activity. Ties use
active login status and stable account identity. Repeated accounts of the same provider use their account
symbols in the menu bar.

The popup opens on the most recently used account. Accounts remain grouped by provider, with the combined
overview immediately to the left of the first account. SwiftUI's native view-aligned scrolling handles
momentum and page snapping. Left/right arrow keys, accessibility adjustment, and clickable symbol indicators
navigate the same scroll position. Indicators show provider logos and expand the selected provider to show
its account symbols. The indicator keeps a compact moving viewport, shrinking symbols at its edges when the sequence overflows.

Page identities include the provider. Their order stays fixed for a showing, including while active logins or
usage readings change. Account pages reuse the normal native instruments, history, warning actions, and login
switching. The bottom toolbar shares the time range, refreshes the connected providers, and opens settings for
the current provider.

## Overview data

The overview uses the same native glass dial and corner instruments. The dial explicitly shows the **mean of
each account's most constrained quota remaining**; it does not imply that independent quotas form a shared
allowance. Corners show known token, cost, request, and account totals. Missing or estimated coverage remains
labelled as partial. Different currencies stay separate, with their subtotals available in the cost tooltip.

Distinct account-attributed machine reports and distinct profile reports contribute independently. Repeated,
unattributed machine-wide reports contribute once per provider, and do not overlap known account totals.
Historical token bars use measured daily buckets or timestamped events. Aggregate-only period reports do not
become invented daily bars.

## Offline validation

Use the normal repository test commands, which suppress Keychain access:

```sh
./Scripts/test_fast.sh --filter NativeCombinedAccountsTests
make test
make check
```

The fixture entry point runs before credential stores initialize and uses the production pager. Build the
native bundle, which includes the authored SF Symbol catalog and native app configuration:

```sh
NATIVE_BUILD_CONFIGURATION=debug ./Scripts/build_native_app.sh
open -n "$HOME/Applications/CodexBar Native.app" --args --native-preview --preview-combined \
  --preview-output /tmp/codexbar-combined
open -n "$HOME/Applications/CodexBar Native.app" --args --native-preview --preview-combined --preview-overview \
  --preview-output /tmp/codexbar-overview
```

Each fixture has four providers and eight accounts. The output contains app-view metadata and a synthetic
symbol artwork sheet. The latter renders the actual indicator glyphs in each selection state without
sampling a window or screen. Add `--preview-control-check` to exercise the production input element and
record the actual native scroll offsets in `page-control-check.json`. Events are delivered directly to the
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
