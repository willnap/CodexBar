# Native design integration

The native derivative uses the reviewed custom gauges and one status button per enabled service. Each button opens a retained AppKit popup for the selected login. Actual account ownership must remain authoritative; unavailable measurements must remain unknown.

Gauge health receives typed credential outcomes, availability and monitored service incidents. Usage pace uses the existing account-scoped pace calculation, not invented throughput. Existing finite symbol effects run on meaningful state transitions and respect Reduce Motion. Ordinary refreshes must preserve view identity and event times. Disabled services are removed; the no-services fallback has a disabled state.

Custom gauges are the default. Legacy icons remain selectable with their existing functioning style controls; unsupported gauge layouts are not presented as choices. Menu Bar and Menu settings expose controls that affect these production surfaces. Providers show enabled services first, with search and concise native rows. Custom provider symbols replace image logos in the native derivative; settings tabs retain colour with appropriate system symbols.

Adaptive is the default for missing or invalid native refresh preferences. Valid saved choices remain authoritative. Opening the popup informs Adaptive, and refresh-on-open stays off by default. When enabled it schedules background refresh after presentation, cancels on dismissal, coalesces requests, and never prompts for credentials. Launch at login defaults on and respects saved opt-outs and ServiceManagement approval state.

The installed bundle path and certificate-backed signing identity remain stable across rebuilds. User-selected provider folders retain security-scoped bookmarks and restore access on launch. No permission revocations, cross-app privacy rules or system protections are bypassed.

Target macOS 26+, Swift 6, existing AppKit/SwiftUI/Observation APIs, no new dependencies. Verification uses isolated fixtures and the real policy/timer seams, followed by make test, make check, signed package verification and a production relaunch with already-authorized real accounts. Do not present fixture usage as live usage or claim physical UI timing that was not measured.
