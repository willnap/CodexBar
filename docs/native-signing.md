# App signing identity

`Scripts/build_native_app.sh` signs each rebuild with the same certificate instead
of an ad-hoc signature. The installed app is `/Applications/CodexBar.app` with
CodexBar's own bundle identifier, `com.steipete.codexbar`; an install that isn't
one of these builds is moved to `~/Applications/CodexBar Backups/` first.

The default signing identity lives in:

```
~/Library/Application Support/CodexBar Native/Signing/
```

The directory has mode `0700`. Its certificate, dedicated signing keychain and
generated keychain password have mode `0600`. The private key is imported as
non-extractable; temporary key material is removed after signing. Only
`/usr/bin/codesign` is added to its application access list. The Apple partition
is enabled for this isolated signing key so codesign can use it without a
Keychain prompt. The keychain is unlocked only for signing and locked afterward.
No login/account keychain, default keychain, global search list, certificate
trust, or system security policy is changed.

Keep this directory across builds. Deleting or replacing the signing identity
creates a different app identity. An incomplete directory causes the build to
stop rather than silently rotating the identity. Restore its original files if
they are lost. A failed first bootstrap may leave an incomplete directory; it is
safe to remove only if that identity has never signed an installed app. Run the
build again afterward.

To use an existing signing certificate instead, set `NATIVE_SIGNING_IDENTITY` to
its fingerprint or identity name before running the build. The chosen identity
must stay the same across builds. Ad-hoc (`-`) signing is rejected. This local
self-signed identity does not provide Developer ID notarization or Gatekeeper
distribution trust.

macOS may require one new permission grant when moving from the earlier ad-hoc
app to the certificate-signed app. Relaunch the installed app and grant its
requested access once; remove and re-add its Full Disk Access entry if macOS
still associates the old entry with the earlier identity. The stable signature
allows later builds to be recognized as the same app. Permissions remain subject
to macOS policy and user revocation, and do not confer another app's sandbox
container access.

Apple describes update identity and self-signed certificates in
[Technical Note TN2206](https://developer.apple.com/library/archive/technotes/tn2206/_index.html).
The automatically generated designated requirement includes the bundle
identifier and the root certificate hash. A matching bundle identifier alone
cannot satisfy it.

Safe checks (no keychain bootstrap):

```sh
python3 Scripts/test_native_signing.py
```

Explicit integration validation creates and deletes a disposable signing
keychain and signs two synthetic copies of `/usr/bin/true`, with no provider
probes or account credential reads:

```sh
NATIVE_SIGNING_INTEGRATION=1 python3 Scripts/test_native_signing.py
```

It checks identical certificate-backed requirements despite different code
hashes, rejects an ad-hoc impostor with the same identifier, and verifies that the
default keychain and search list remain unchanged. The integration check may
require execution outside the workspace sandbox for macOS keychain creation.

## Background Keychain access

A stable signing identity and non-interactive Keychain access solve different
problems. Background cache reads, adds, updates and deletes carry the per-query
no-UI policy and now execute inside a serialized legacy-interaction scope. The
scope reads the existing process policy, suppresses UI, runs the synchronous
operation and restores the prior policy. Explicit user actions share the same
lock and never force interaction on. Unknown or unchangeable policy skips the
operation rather than displaying a password dialog. Permanent test suppression
cannot be undone by scoped restoration.

This handles the documented file-based Keychain limitation where SecItem's
per-query flags can still display an ACL dialog (Apple issue FB16959400; see
[Chromium's compatibility implementation](https://chromium.googlesource.com/chromium/src/crypto/+/refs/heads/main/apple/scoped_keychain_user_interaction_allowed.cc)).
It does not unlock a Keychain or change an item's access list. Rejected old cache
items remain unread; existing fresh login data can repair the application's own
cache through the same non-interactive gateway.
