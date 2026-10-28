# Native energy use

macOS reported CodexBar Native as using significant energy (2026-10-20). Measured on the running app:

- 92 CPU-minutes over 7 hours (22 % of a core on average), 2.3 GB resident;
- a refresh cycle every 5 minutes cost about 38 s of CPU, at 100–250 % for half a minute: the main thread at 92 %,
  the Claude cost scan pinning a core, and a background thread re-encoding history;
- between cycles, 1–3 s of CPU every 30–60 s (the minute pace tick and ClaudeSwap refreshes).

## Causes and fixes

**History grew without bound and was resorted on every render.** Codex session logs record a quota reading per model
turn; the anonymous archive held 65,594 readings for 32 days (median 3.9 s apart, 88 % repeats) and `codex.json` was
20 MB. Rendering an account merged its live reading into each quota series by rehashing and resorting the whole
series (`nativeOrbitMergedRawEntries`), which was 66 % of the main thread.

- Merges of ordered series run in one pass; expired readings are dropped as a prefix.
- The session archive keeps the first and last reading of each 5-minute bucket within a run of identical readings
  (`nativeOrbitThinnedObservations`). Every change, run end and recording gap longer than a bucket survives exactly,
  so segments, resets and hover values are unchanged; re-adding a dropped reading never changes the result, so a full
  rescan never republishes. 65.5k → 14.3k readings on the measured data.

**The Codex daily-token archive stored every day again on every fetch.** One account held 100,000 archived
observations (99.9 % repeats, the cap), validated with calendar arithmetic on every render; the snapshot store
decoded, merged and re-encoded the 19 MB file on every refresh. The archive now keeps a day's reading only when its
count changes, as its corrections contract says (19 MB → 650 KB).

**Every observer rebuilt every account.** The menu bar icon (twice per change), its visibility pass, automatic
switching and each popover rebuilt the same account presentations after every store change. `nativeOrbitAccounts`
now remembers each provider's rows until an input they were built from changes (or after five seconds, for the
clock-derived parts). A reader that builds observes those inputs as before; a reader served remembered rows observes a
per-provider generation, so each change notifies it once and only for its provider.

**History saves re-encoded every provider.** Saves now write only providers whose history differs from the last
successful save.

**The Claude cost scan redid everything.** Each scan reconciled, sorted and repriced all 252k transcript rows (3,074
files) and summed them again, for the machine report and once more per organization. `ClaudeReportEngine` keeps each
report between scans: unchanged transcripts are recognised by their row storage, changed ones are replayed into every
request's winner, and only the day/model and time buckets their rows touch are re-summed, each in a full rebuild's
order, so reports are byte-identical (`CostUsageClaudeReportEngineTests` compares them across appended, inserted,
removed, reordered and partly incomplete transcripts and a range change). A new range, time zone or price catalogue
rebuilds everything; legacy caches without rows keep the full rebuild.

**Claude caches were rewritten on every scan.** The 80 MB transcript cache and its 33 MB memo were encoded and written
after each refresh. The redesign first deferred those writes to every ten minutes; upstream's sharded cache (project
shards behind a manifest, see [Claude](claude.md)) now writes only the shards a refresh changed, so writes happen on
every change again without rewriting the whole cache, and the deferral was dropped when the two were merged.

**Kimi re-listed every session directory.** About 6,900 session and agent directories were enumerated on each pass
(6.7 s of a refresh). Each directory's listing is kept until that directory's modification date changes.

**Codex file checks rebuilt the environment.** The credential-file guard asked whether it ran under tests by copying
the whole process environment for every file a session scan touched (1.7 s per refresh); it is decided once.

**Each reading wrote history.** A refresh saved quota history after every provider's reading; saves now wait ten
seconds after a change so one refresh is written once (a quit never waits).

**Every process's arguments were read several times a refresh.** Claude and Codex refreshes resolve Pi's history
scope from running Pi processes, even with Pi off, by reading every process's argument and environment block
(`KERN_PROCARGS2`), two or three times per refresh (about 1.25 s). Both are fixed at process start, so they are read once
per process (`DarwinProcessRecordCache`), again only while a process is under a minute old or its pid is reused.

**Other providers reread unchanged files.** Kept until the file changes (`FileContentStamp`): Claude Desktop's plan
history and web logs (claude-swap refreshes), Antigravity's conversation databases (charging the scan budget what
reading them did), OpenCode Go's database rows, Muse's cache (also saved only when a session changed) and Grok's
session signals. Not changed: the Codex scanner (its parser hash guards every user's cache), the Codex session-history
walk (an old session can be resumed, so date folders cannot be skipped), and Devin/Windsurf's Local Storage reads
(caching them would keep sign-in tokens in memory between refreshes).

**Codex session readings were re-collected on every refresh.** The session-history scan rehashed and sorted every
reading of the month, and the repair after it re-sorted every recovered series, about 4 s, even when no log had grown.
The scanner keeps its sorted collection until a contributing file is read further, and a repair whose readings and
history match the last one that changed nothing is skipped.

**Closed popovers re-rendered.** A closed popover rebuilt its columns three seconds after each background change, many
times over a refresh. It now gathers changes for 30 seconds; opening shows the prepared columns at once and applies
anything pending straight after.

**Abandoned temporaries.** A Claude cache write killed before its rename leaves an 80 MB temporary; relaunches had
left 450 MB. Copies older than an hour are removed once per directory and launch.

## Results

Release build, adaptive refresh, the same accounts and history (2026-10-20, 22:37–22:54):

- startup: about 50 CPU-seconds in the first 30 s while the in-memory caches fill from disk;
- then 6.5 CPU-seconds in 15 min 43 s: 0.7 % of a core, almost all of it the menu bar's once-a-minute redraw
  (about 0.4 s); resident memory settled at 1.6 GB (was 2.1–2.3 GB).

## Measuring

```sh
# CPU seconds per 10 s, with the large caches' write times
ps -o time= -p "$(pgrep -x CodexBarNative)"
top -l 0 -s 1 -pid "$(pgrep -x CodexBarNative)" -stats pid,cpu,idlew,power
sample "$(pgrep -x CodexBarNative)" 12 1 -file sample.txt   # during a burst
```

Don't measure with `--native-popup-preview-provider`: its proof dump rebuilds every provider on each popup refresh.
