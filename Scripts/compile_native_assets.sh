#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 APP_BUNDLE GAUGE_ASSET_CATALOG" >&2
    exit 1
fi

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP="$1"
GAUGE_ASSETS="$2"
ICON_NAME=NativeIcon
ICON_SOURCE="$ROOT/$ICON_NAME.icon"
OUTPUT=$(mktemp -d "${TMPDIR:-/tmp}/codexbar-native-assets.XXXXXX")
trap 'rm -rf "$OUTPUT"' EXIT

if [[ ! -f "$APP/Contents/Info.plist" || ! -d "$GAUGE_ASSETS" || ! -f "$ICON_SOURCE/icon.json" ]]; then
    echo "Native assets require an app Info.plist, gauge catalog, and authored Icon Composer package." >&2
    exit 1
fi

# One catalog preserves the gauge symbols and the icon's authored layers/appearances together. A separate
# icon compilation followed by copying Assets.car would discard one of them. Let Apple's compiler supply the
# matching fallback icon and bundle metadata instead of flattening one appearance into the legacy Icon.icns.
xcrun actool "$GAUGE_ASSETS" "$ICON_SOURCE" \
    --compile "$OUTPUT" --platform macosx --target-device mac \
    --minimum-deployment-target 26.0 --app-icon "$ICON_NAME" \
    --output-partial-info-plist "$OUTPUT/IconMetadata.plist" \
    --output-format human-readable-text --warnings --errors

python3 - "$APP" "$OUTPUT" "$ICON_NAME" <<'PY'
import plistlib
import shutil
import sys
from pathlib import Path

app, output = map(Path, sys.argv[1:3])
icon_name = sys.argv[3]
with (output / "IconMetadata.plist").open("rb") as source:
    icon_info = plistlib.load(source)
if icon_info.get("CFBundleIconName") != icon_name:
    raise SystemExit("Asset compiler did not declare the authored native app icon")
if not (output / "Assets.car").is_file():
    raise SystemExit("Asset compiler did not produce the combined asset catalog")
if icon_info.get("CFBundleIconFile") != icon_name or not (output / (icon_name + ".icns")).is_file():
    raise SystemExit("Asset compiler did not produce the matching fallback icon")
resources = app / "Contents" / "Resources"
resources.mkdir(parents=True, exist_ok=True)
for item in output.iterdir():
    if item.name == "IconMetadata.plist":
        continue
    destination = resources / item.name
    if item.is_dir():
        shutil.copytree(item, destination, dirs_exist_ok=True)
    else:
        shutil.copyfile(item, destination)
info_path = app / "Contents" / "Info.plist"
with info_path.open("rb") as source:
    info = plistlib.load(source)
info.update(icon_info)
with info_path.open("wb") as destination:
    plistlib.dump(info, destination, sort_keys=False)
PY
