#!/bin/sh
# Reproducibly stages the minimal embeddable quickjs-ng engine in Sources/CQuickJS.
set -eu

QUICKJS_VERSION="0.17.0"
QUICKJS_TAG="v${QUICKJS_VERSION}"
EXPECTED_SHA256="559bc4c420475e55c7ab4510adbc562f55d7524d75e8e89d79ce4bb02f5687d9"
ARCHIVE_URL="https://github.com/quickjs-ng/quickjs/archive/refs/tags/${QUICKJS_TAG}.tar.gz"

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TARGET_DIR="${ROOT_DIR}/Sources/CQuickJS"
MODE=${1:-check}

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/codexbar-quickjs-regen.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT HUP INT TERM
ARCHIVE_FILE="${WORK_DIR}/quickjs.tar.gz"
SOURCE_DIR="${WORK_DIR}/quickjs-${QUICKJS_VERSION}"
STAGE_DIR="${WORK_DIR}/stage"

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

curl -fsSL "$ARCHIVE_URL" -o "$ARCHIVE_FILE"
ACTUAL_SHA256=$(sha256_file "$ARCHIVE_FILE")
if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
    echo "error: quickjs-ng archive hash ${ACTUAL_SHA256} does not match ${EXPECTED_SHA256}" >&2
    exit 1
fi

tar -xzf "$ARCHIVE_FILE" -C "$WORK_DIR"
mkdir -p "$STAGE_DIR/include"

for source in quickjs.c dtoa.c libregexp.c libunicode.c; do
    cp "${SOURCE_DIR}/${source}" "$STAGE_DIR/$source"
done

# Keep the public fork's tracked sources below 2 MB without changing the translation unit.
python3 - "$STAGE_DIR" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
source = root / "quickjs.c"
original = source.read_bytes()
boundary = original.index(b"static JSValue js_reflect_apply(JSContext *ctx, JSValueConst this_val,")
line = original[:boundary].count(b"\n") + 1
license = original[:original.index(b"*/") + 2] + b"\n"
marker = (b"/* Continued in an included section to keep each tracked source below 2 MB. */\n"
          b'#include "quickjs-tail.h"\n')
header = license + f'\n#line {line} "quickjs.c"\n'.encode()
source.write_bytes(original[:boundary] + marker)
tail = root / "quickjs-tail.h"
tail.write_bytes(header + original[boundary:])
assert source.read_bytes().removesuffix(marker) + tail.read_bytes()[len(header):] == original
assert max(source.stat().st_size, tail.stat().st_size) < 2_000_000
PY

for header in \
    builtin-array-fromasync.h \
    builtin-iterator-zip-keyed.h \
    builtin-iterator-zip.h \
    cutils.h \
    dtoa.h \
    libregexp-opcode.h \
    libregexp.h \
    libunicode-table.h \
    libunicode.h \
    list.h \
    quickjs-atom.h \
    quickjs-c-atomics.h \
    quickjs-opcode.h \
    quickjs.h
do
    cp "${SOURCE_DIR}/${header}" "$STAGE_DIR/include/$header"
done

cp "${SOURCE_DIR}/LICENSE" "$STAGE_DIR/LICENSE"

case "$MODE" in
    check | --check)
        for file in quickjs.c quickjs-tail.h dtoa.c libregexp.c libunicode.c LICENSE; do
            cmp "${STAGE_DIR}/${file}" "${TARGET_DIR}/${file}"
        done
        for file in "$STAGE_DIR"/include/*.h; do
            cmp "$file" "${TARGET_DIR}/include/$(basename "$file")"
        done
        echo "ok: vendored quickjs-ng ${QUICKJS_TAG} matches ${EXPECTED_SHA256}"
        ;;
    write | --write)
        rm -f \
            "${TARGET_DIR}/quickjs.c" \
            "${TARGET_DIR}/quickjs-tail.h" \
            "${TARGET_DIR}/dtoa.c" \
            "${TARGET_DIR}/libregexp.c" \
            "${TARGET_DIR}/libunicode.c" \
            "${TARGET_DIR}/LICENSE"
        mkdir -p "${TARGET_DIR}/include"
        cp "$STAGE_DIR"/*.c "$TARGET_DIR/"
        cp "$STAGE_DIR"/quickjs-tail.h "$TARGET_DIR/"
        cp "$STAGE_DIR"/LICENSE "$TARGET_DIR/"
        cp "$STAGE_DIR"/include/*.h "$TARGET_DIR/include/"
        echo "wrote ${TARGET_DIR} from quickjs-ng ${QUICKJS_TAG} (${EXPECTED_SHA256})"
        ;;
    *)
        echo "Usage: $0 [check|write]" >&2
        exit 2
        ;;
esac
