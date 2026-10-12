#!/usr/bin/env bash
# Verifies that a Codex parser hash change cannot silently wipe users' Codex cost caches:
# regenerating must fail until the previous hash is adopted or the rebuild is declared intentional.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/Scripts" "$WORK/Sources/CodexBarCore/Vendored/CostUsage" "$WORK/Sources/CodexBarCore/Generated"
cp "$ROOT_DIR/Scripts/regenerate-codex-parser-hash.sh" "$WORK/Scripts/"
SCRIPT="$WORK/Scripts/regenerate-codex-parser-hash.sh"
PARSER="$WORK/Sources/CodexBarCore/Vendored/CostUsage/CostUsageScanner.swift"
STORE="$WORK/Sources/CodexBarCore/Vendored/CostUsage/CostUsageStore.swift"
GENERATED="$WORK/Sources/CodexBarCore/Generated/CodexParserHash.generated.swift"

write_store() {
  {
    echo 'enum CostUsageStore {'
    echo '    static let compatiblePredecessorParserHashes: Set<String> = ['
    for hash in "$@"; do
      echo "        \"$hash\", // fixture"
    done
    echo '    ]'
    echo '    static let other: Set<String> = ["0000000000000000"]'
    echo '}'
  } >"$STORE"
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

current_hash() {
  sed -n 's/^[[:space:]]*static let value = "\([0-9a-f]*\)".*$/\1/p' "$GENERATED"
}

echo 'struct Parser { let version = 1 }' >"$PARSER"
write_store
"$SCRIPT" >/dev/null || fail "initial generation must succeed without a previous hash"
"$SCRIPT" --check >/dev/null || fail "freshly generated hash must pass --check"
FIRST="$(current_hash)"
[[ "$FIRST" =~ ^[0-9a-f]{16}$ ]] || fail "generated hash is malformed: $FIRST"

# Store-only and Claude-only files never change the hash.
echo '// storage bookkeeping' >>"$STORE"
echo 'struct ClaudeOnly {}' >"$WORK/Sources/CodexBarCore/Vendored/CostUsage/CostUsageScanner+Claude.swift"
"$SCRIPT" --check >/dev/null || fail "store and Claude-only edits must not change the parser hash"

# A hashed parser edit without adopting the previous hash fails both modes and leaves the cache identity alone.
echo 'struct Parser2 {}' >>"$PARSER"
if "$SCRIPT" --check >/dev/null 2>&1; then fail "--check must fail for a stale hash"; fi
CHECK_OUTPUT="$("$SCRIPT" --check 2>&1 || true)"
[[ "$CHECK_OUTPUT" == *"is not in"*"compatiblePredecessorParserHashes"* ]] ||
  fail "--check must explain that the previous hash is not adopted"
if "$SCRIPT" >/dev/null 2>&1; then fail "regeneration must refuse an unadopted previous hash"; fi
[[ "$(current_hash)" == "$FIRST" ]] || fail "a refused regeneration must not rewrite the generated hash"
if "$SCRIPT" --check >/dev/null 2>&1; then fail "--check must still fail after a refused regeneration"; fi

# A hash elsewhere in the store file does not count as adoption.
write_store
sed -i.bak "s/0000000000000000/${FIRST}/" "$STORE" && rm -f "$STORE.bak"
if "$SCRIPT" >/dev/null 2>&1; then fail "only compatiblePredecessorParserHashes may adopt the previous hash"; fi

# Adopting the previous hash lets the documented workflow (regenerate, then --check) pass.
write_store "$FIRST"
"$SCRIPT" >/dev/null || fail "regeneration must succeed once the previous hash is adopted"
SECOND="$(current_hash)"
[[ "$SECOND" != "$FIRST" ]] || fail "parser edits must change the hash"
"$SCRIPT" --check >/dev/null || fail "--check must pass after regeneration"

# An intentional semantic change can rebuild caches, but only when declared.
echo 'struct Parser3 {}' >>"$PARSER"
if "$SCRIPT" >/dev/null 2>&1; then fail "an undeclared rebuild must be refused"; fi
"$SCRIPT" --semantic-change >/dev/null 2>&1 || fail "--semantic-change must allow an intentional rebuild"
[[ "$(current_hash)" != "$SECOND" ]] || fail "--semantic-change must write the new hash"
"$SCRIPT" --check >/dev/null || fail "--check must pass after a declared semantic change"

echo "regenerate-codex-parser-hash tests passed"
