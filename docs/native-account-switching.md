# Native popup account switching

How the native popup names accounts and switches between them (2026-10-14).

## The account bar

Every column of a multi-account popup ends in the same bar (`NativeOrbitPopupView.footer`):

- The account's name, leading, at the column's content inset, so names line up across columns.
- At the trailing end: an accent checkmark on the active account, or a plain glass **Switch** button on
  an account that can be activated. The accent is reserved for what is current (checkmark, active
  column, selected range).
- One click switches. There is no menu. While the switch runs, the button's title gives way to a
  mini spinner at the same size; the other Switch buttons are disabled. On success the column slides
  to the front (the existing reorder animation) and gets the checkmark.
- A failed switch replaces that column's name with the reason, in orange, truncated, with the full
  text as its help. It clears on the next attempt (`NativeAccountSwitchController.errorAccountID`).

The previous control was a one-item pull-down (`arrow.right.circle.fill` → "Use in …"), which read
as unclear and could open and close again at once.

## Names

`UsageStore.nativeOrbitCodexLabels` names Codex columns from the accounts actually shown:

- the email, or "Account N" in privacy mode;
- only when another shown column has the same email, the workspace name (never "Personal"), or
  failing a distinct one, its number;
- never a hash.

The old label came from `CodexVisibleAccount.menuDisplayName`, whose discriminator
("Personal · 762492c0") was computed over every visible account, including imported profile copies
(such as `~/.codex-second`) that the popup hides. A hidden copy with the same email made the shown
account carry a hash, and only sometimes: whenever such a copy existed.

claude-swap columns keep `ClaudeSwapAccountProjection.displayLabel` (alias or email; organization or
slot only for duplicate emails), which already follows the same rule.

## Speed

Claude (`UsageStore.switchClaudeSwapAccount`): after `cswap --switch-to`, the switch settles on
claude-swap's own list (about 0.15 s), which names the new active row. The ambient Claude reading, a
slower provider fetch, starts after the switch instead of holding it open (it used to be awaited with
up to 5 s of grace). The popup no longer blanks every Claude column and drops the active mark for the
duration: each reading is tied to its own slot, and the ambient one also to its email and
organization, so nothing can land on the wrong column while the list catches up.

Codex (`NativeCodexDesktopHandoff`): when the desktop app is open it is still quit before the login
changes and reopened after. The handoff no longer waits up to 15 s for the reopened app's Codex
server (`appServerGrace` is 0): every earlier server had exited before the install, so whichever
starts reads the new login. Ownership verification is unchanged.

## Automatic switching

The Codex-only "Auto switch" toggle left the popup toolbar (it fit only unlabeled, and only for Codex)
and is now **Switch accounts automatically** under Settings → Codex → Accounts, stored in the same
`nativeAutoSwitch.codex` default. The switch controller follows the setting live through
`UserDefaults.didChangeNotification`.

## Verifying without real accounts

`--native-preview --preview-orbit --preview-window --preview-open` gives two fixture accounts that can
switch. `CODEXBAR_PREVIEW_SWITCH_AFTER=<seconds>` starts one unattended,
`CODEXBAR_PREVIEW_SWITCH_FAILS=1` makes it fail, and `CODEXBAR_PREVIEW_ANIMATION_SCALE` slows it.
