#!/bin/bash
# Keep the native development app's cryptographic identity stable across builds.
# The isolated local identity grants no system trust and reads no account credentials.
set -euo pipefail
umask 077

fail() { printf 'Native signing: %s\n' "$*" >&2; exit 1; }
IDENTITY="${NATIVE_SIGNING_IDENTITY:-}"
[[ "$IDENTITY" != "-" ]] || fail 'ad-hoc signing cannot preserve permission identity; choose a certificate identity.'
[[ $# -eq 1 && -d "$1/Contents" && -f "$1/Contents/Info.plist" ]] || fail 'pass an existing app bundle to sign.'
APP_TO_SIGN="$1"
SIGNING_HOME="${NATIVE_SIGNING_HOME:-$HOME/Library/Application Support/CodexBar Native/Signing}"
KEYCHAIN=""
LOCK=""
SCRATCH=""
cleanup() {
    if [[ -n "$KEYCHAIN" ]]; then /usr/bin/security lock-keychain "$KEYCHAIN" >/dev/null 2>&1 || true; fi
    if [[ -n "$SCRATCH" ]]; then rm -rf "$SCRATCH"; fi
    if [[ -n "$LOCK" ]]; then rmdir "$LOCK" 2>/dev/null || true; fi
}
trap cleanup EXIT

SIGN_ARGS=()
if [[ -n "$IDENTITY" ]]; then
    # Respect the user's existing certificate/keychain configuration. No fallback
    # to a different signer is allowed when that configuration fails.
    SIGN_ARGS=(--sign "$IDENTITY")
else
    [[ ! -L "$SIGNING_HOME" ]] || fail 'signing storage must not be a symbolic link.'
    mkdir -p "$SIGNING_HOME"
    chmod 700 "$SIGNING_HOME"
    mkdir "$SIGNING_HOME/.lock" 2>/dev/null || fail 'another signing process is active; retry after it finishes.'
    LOCK="$SIGNING_HOME/.lock"
    KEYCHAIN="$SIGNING_HOME/native-signing.keychain-db"
    CERTIFICATE="$SIGNING_HOME/identity.pem"
    PASSWORD_FILE="$SIGNING_HOME/keychain-password"
    if [[ ! -e "$KEYCHAIN" && ! -e "$CERTIFICATE" && ! -e "$PASSWORD_FILE" ]]; then
        SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/codexbar-native-identity.XXXXXX")
        /usr/bin/openssl rand -hex 32 > "$PASSWORD_FILE"
        chmod 600 "$PASSWORD_FILE"
        KEYCHAIN_PASSWORD=$(cat "$PASSWORD_FILE")
        cat > "$SCRATCH/openssl.cnf" <<'CONFIG'
[req]
distinguished_name = subject
x509_extensions = codesign
prompt = no
[subject]
CN = CodexBar Native Local Signing
O = CodexBar Native Local Development
[codesign]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CONFIG
        /usr/bin/openssl req -new -x509 -newkey rsa:3072 -nodes -sha256 -days 36500 \
            -config "$SCRATCH/openssl.cnf" -keyout "$SCRATCH/identity.key" \
            -out "$CERTIFICATE" >/dev/null 2>&1
        /usr/bin/openssl pkcs12 -export -inkey "$SCRATCH/identity.key" -in "$CERTIFICATE" \
            -out "$SCRATCH/identity.p12" -passout "file:$PASSWORD_FILE"
        /usr/bin/security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
        /usr/bin/security import "$SCRATCH/identity.p12" -k "$KEYCHAIN" -f pkcs12 \
            -P "$KEYCHAIN_PASSWORD" -x -T /usr/bin/codesign >/dev/null
        # Only this new, isolated signing key is affected. No login keychain,
        # global search list, default keychain or certificate trust is modified.
        /usr/bin/security set-key-partition-list -S apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
        chmod 600 "$KEYCHAIN" "$CERTIFICATE"
        printf 'Created persistent local signing identity in %s\n' "$SIGNING_HOME" >&2
    else
        [[ -f "$KEYCHAIN" && -f "$CERTIFICATE" && -f "$PASSWORD_FILE" ]] || \
            fail 'signing storage is incomplete; restore its existing identity instead of replacing it.'
        [[ ! -L "$KEYCHAIN" && ! -L "$CERTIFICATE" && ! -L "$PASSWORD_FILE" ]] || \
            fail 'signing identity files must not be symbolic links.'
        chmod 600 "$KEYCHAIN" "$CERTIFICATE" "$PASSWORD_FILE"
        KEYCHAIN_PASSWORD=$(cat "$PASSWORD_FILE")
    fi
    /usr/bin/security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    IDENTITY=$(/usr/bin/openssl x509 -in "$CERTIFICATE" -noout -fingerprint -sha1 | \
        /usr/bin/sed 's/.*=//; s/://g')
    [[ "$IDENTITY" =~ ^[[:xdigit:]]{40}$ ]] || fail 'cannot read the persistent signing certificate.'
    SIGN_ARGS=(--sign "$IDENTITY" --keychain "$KEYCHAIN")
fi

# codesign synthesizes a certificate-backed requirement for every nested bundle
# using that bundle's own identifier. Do not propagate a single outer identifier
# as a custom requirement through --deep.
/usr/bin/codesign --force --deep --timestamp=none "${SIGN_ARGS[@]}" "$APP_TO_SIGN"
/usr/bin/codesign --verify --deep --strict "$APP_TO_SIGN"
REQUIREMENT=$(/usr/bin/codesign -d -r- "$APP_TO_SIGN" 2>&1)
[[ "$REQUIREMENT" != *cdhash* && ( "$REQUIREMENT" == *anchor* || "$REQUIREMENT" == *certificate* ) ]] || \
    fail 'signature does not have a stable certificate-backed designated requirement.'
printf '%s\n' "$REQUIREMENT"
