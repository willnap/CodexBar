# Codex desktop account switching

Updated 2026-10-12. This replaces the 2026-10-10/11 investigation, which concluded that the desktop app owned a
separate account session that CodexBar could not change. That conclusion was wrong: the desktop app and the Codex CLI
share one login file, and the desktop only needs a restart to pick up a change.

No credentials or token values were read for this work. Nothing was switched on a real account, and the desktop app was
never quit or launched by CodexBar or its tests.

## Installed application

- `/Applications/ChatGPT.app`, bundle identifier `com.openai.codex`, version `26.1007.30912` on this Mac.
- Bundled CLI: `Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex`, version `0.162.0-alpha.17.2`
  (`codex-cli/codex-package.json`). `codex-cli/bin/codex` is a `/bin/sh` launcher that `exec`s that binary.

## How the desktop gets its account

1. The desktop's Codex surface runs a child process,
   `…/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex … app-server`. The Electron side
   asks that app-server for the account (`account/read`). It never reads `auth.json` itself.
2. The app-server builds its `AuthManager` once at startup (`AuthManager::shared_from_config` in the app-server's
   `lib.rs`). That loads `CODEX_HOME/auth.json`; the default is `~/.codex/auth.json`. This Mac uses the file store
   because `config.toml` has no `cli_auth_credentials_store` setting.
3. After startup the login stays in memory. The app-server reloads it only after a login or logout it performs itself
   (`account_processor.rs`), or during token refresh. Refresh uses `reload_if_account_id_matches`
   (`login/src/auth/manager.rs`), which skips the file when its `account_id` differs from the cached one. The bundled
   binary contains the matching log text "Skipping auth reload due to account id mismatch". So a running app-server
   neither adopts a different account from the file nor overwrites that account's tokens through the guarded refresh.

So swapping `auth.json` switches the CLI immediately. The desktop switches only when its app-server starts again, which
in practice means quitting and reopening the app. The community tools
[frndchagas/codex-account](https://github.com/frndchagas/codex-account) (`bin/codex-account`) and
[Loongphy/codex-auth](https://github.com/Loongphy/codex-auth) (`src/app.zig`, bundle id `com.openai.codex`) use the
same recipe.

## What CodexBar does (explicit "Use in ChatGPT & Codex CLI")

`NativeCodexDesktopHandoff` (`Sources/CodexBar/NativeGauge/NativeCodexDesktopHandoff.swift`) wraps the existing
promotion transaction inside `activateNativeCodexAccount`:

1. **Preconditions, before anything changes.** The existing file-store checks (`NativeCodexActivationCapability`)
   still apply. A symbolic link at the live `auth.json` is refused. Same-user processes are listed with `libproc`, and
   every native `codex` binary is attributed to its owner:
   - **Desktop:** inside the desktop bundle, or descended from the desktop app (this covers a custom CLI path).
   - **CodexBar:** descended from CodexBar (its own usage probes).
   - **External:** anything else, such as a terminal CLI, `codex exec`, or an IDE integration.

   An external session blocks the switch with "Close the running Codex CLI or IDE session first…", because it keeps
   the old login in memory. For the desktop app and its app-servers, only `CODEX_HOME` and `HOME` are decoded from
   `KERN_PROCARGS2`. The switch is refused if the resulting Codex home differs from CodexBar's live home, or if the
   environment cannot be read. No argument or other environment value is decoded.
2. **CodexBar's own probes.** CodexBar's long-lived Codex CLI status session is reset, and its short-lived
   `codex app-server` usage probes are allowed up to 10 s to exit. Otherwise the switch stops before touching the
   desktop.
3. **Quit.** `NSRunningApplication.terminate()` sends the app an ordinary quit, so its own confirmation for running
   chats or automations still appears. CodexBar waits up to 20 s for the app process and every desktop-owned `codex`
   process to exit. If the user cancels the quit, the app stays open and no file is touched ("ChatGPT didn't quit…
   No account was changed."). If the app exits but an app-server lingers, CodexBar reopens the app and changes
   nothing. A new CLI session that appears during the quit also aborts, and the app is reopened.
4. **Save the outgoing login.** This is the existing `CodexDisplacedLivePreservation*` transaction. When the live login
   matches a saved account by identity (account id plus email), the live bytes, which hold the newest rotated tokens,
   are copied back into that account's managed home. An unmatched login is imported as a new saved account, never
   dropped.
5. **Install** the target through `CredentialFileWriter.writePrivate`: a 0600 staged file, `fsync`, then `rename(2)`.
   `DefaultCodexLiveAuthSwapper` refuses a symbolic link at `auth.json`.
6. **Reopen only if this switch closed the app**, using `NSWorkspace.openApplication` with the default configuration
   (like `open -b com.openai.codex`, with no environment changes). If install fails after the quit, the app is reopened
   on the old, untouched login.
7. **Verify without UI.** The reopened app must be a process that started after the install, so every app-server that
   held the old login is known to have exited first. CodexBar also waits up to 15 s to see a desktop app-server that
   started after the install. That is recorded as extra evidence, and the switch still succeeds without it. Finally,
   the account projection is re-read from `auth.json` and must still show the target as the one live owner. If the app
   doesn't reopen, CodexBar reports that the login switched and asks the user to open the app.

The menu now reads "Use in ChatGPT & Codex CLI". The app name comes from the installed bundle, and the label falls back
to "Codex CLI" when the desktop app is not installed.

## Auto Switch never quits the desktop app

Only the explicit menu action sets `NativeCodexDesktopHandoff.quitPolicy` to `.askToQuit`, as a task-local value. The
default is `.never`. The automatic path sets `.never` explicitly, so it cannot inherit permission from a manual switch
that happens to be running. With `.never`:

- If the desktop app is closed, Auto Switch switches the login as before.
- If the desktop app is open, or an external CLI session is running, the switch is **deferred**. The exhaustion is not
  counted as attempted. The user gets one notification per exhaustion ("Auto Switch is waiting…"), and the menu shows
  the reason. The switch retries as soon as `NSWorkspace` reports that `com.openai.codex` terminated, or after the
  10-minute cooldown.

## Not covered

- **Stale-desktop detection** (optional item 8). While the desktop is running, CodexBar does not flag that its
  app-server started on a different login than the current `auth.json`. This can happen after a switch from another
  tool. This Mac's desktop logs under `~/Library/Logs/com.openai.codex` are empty files, so they offer no
  `account_login_completed` signal to use.
- **CodexBar's probes are drained, not stopped.** A new usage probe may start mid-switch. It cannot change the result,
  because the transaction re-reads the live and target files right before the rename, and `codex`'s guarded refresh
  ignores a file whose account changed.
- **Preferences still promotes the CLI only.** The Settings pane's system-account promotion
  (`StatusItemController+Actions`) still changes `auth.json` without restarting the desktop.
- **Missed launch environment.** When the desktop app is not running, its next launch environment cannot be checked.
  A `CODEX_HOME` set through `launchctl setenv` would go unnoticed.

## Evidence gathered on this Mac (read-only)

- The bundled binary contains "Skipping auth reload due to account id mismatch" and "Reloading auth for account".
- Process census with the live `LiveNativeCodexDesktopSystem`: 694 same-user processes were listed. The desktop app
  wasn't running, so `prepare` returned `ready` with no desktop to quit. The login target name resolved to
  "ChatGPT & Codex CLI".
- `KERN_PROCARGS2` home decoding works on a LaunchServices-launched third-party app: CodexBar Native resolved to
  `~/.codex`. A harmless sleeper binary named `codex`, started with
  `CODEX_HOME=/private/tmp/claude-501/fake-codex-home`, was classified as an external session, and its home was
  decoded exactly. `prepare` refused the explicit switch and deferred the automatic one.
- Apple platform binaries such as Finder and Dock expose no environment through `KERN_PROCARGS2`. CodexBar would refuse
  in that case rather than guess.

## Tests

`Tests/CodexBarTests/NativeCodexDesktopHandoffTests.swift` replaces every process and app interaction with
`FakeCodexDesktopSystem`, which uses scripted processes and a manual clock. It covers:

- Running vs. not running.
- A cancelled quit, and an app-server that outlives its app.
- A failed install that reopens the app.
- Reopening only when the switch closed the app, plus the app-server evidence.
- External sessions blocking an explicit switch and deferring an automatic one.
- A `CODEX_HOME` mismatch, and an environment that cannot be read.
- Auto policy never quitting the app, and CodexBar probe draining.
- Symbolic-link refusal, and census attribution, including reused process IDs.

The `NativeCodexDesktopHandoffPromotionTests` suite runs the real promotion transaction inside a handoff. It checks
that rotated outgoing tokens are saved back into their account before the target is installed, while no desktop
process is alive, and that an unmatched outgoing login is archived. `NativeAccountAutoSwitchTests` checks that only
the explicit action carries `.askToQuit`, including for an automatic task created inside a manual switch's scope. It
also checks that a deferred automatic switch notifies once and resumes when the desktop app quits.
