#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORKSPACE=$(cd "$ROOT/../.." && pwd)
GAUGE_SOURCE="$WORKSPACE/Implementation/Components/UsageIndicator"
APP="$WORKSPACE/App/CodexBar Native.app"
LOCAL_APP="${NATIVE_APP_INSTALL_PATH:-$HOME/Applications/CodexBar Native.app}"
STAGE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/codexbar-native-package.XXXXXX")
STAGE="$STAGE_ROOT/CodexBar Native.app"
trap 'rm -rf "$STAGE_ROOT"' EXIT
export COPYFILE_DISABLE=1
# The installed app is optimized; set NATIVE_BUILD_CONFIGURATION=debug for a debug package.
CONF="${NATIVE_BUILD_CONFIGURATION:-release}"
SCRATCH_PATH="${NATIVE_SWIFTPM_SCRATCH_PATH:-}"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export CLANG_MODULE_CACHE_PATH="${NATIVE_CLANG_MODULE_CACHE_PATH:-$ROOT/.build/clang-cache}"
cd "$ROOT"
python3 "$ROOT/Scripts/generate_settings_search_index.py" --check

# Always build the current workspace gauge component; keep the derivative standalone.
mkdir -p "$ROOT/Sources/CodexBar/NativeGauge/Generated"
for name in ComputeGauge LaurelGauge NativeGaugeGeometry UsageModel ServiceIdentity; do
    if ! cmp -s "$GAUGE_SOURCE/$name.swift" "$ROOT/Sources/CodexBar/NativeGauge/Generated/$name.swift"; then
        cp "$GAUGE_SOURCE/$name.swift" "$ROOT/Sources/CodexBar/NativeGauge/Generated/$name.swift"
    fi
done

# iCloud adds Finder metadata to generated resource bundles during signing.
# Keep SwiftBuild outputs in temporary local storage; source and app stay here.
BUILD_STORAGE="${NATIVE_BUILD_STORAGE:-${TMPDIR:-/tmp}/CodexBarNative-${UID}}"
mkdir -p "$ROOT/.build" "$BUILD_STORAGE"
if [[ -z "$SCRATCH_PATH" && -d "$ROOT/.build/out" && ! -L "$ROOT/.build/out" ]]; then
    ditto --noextattr --norsrc "$ROOT/.build/out" "$BUILD_STORAGE/out"
    mv "$ROOT/.build/out" "$ROOT/.build/native-cloud-output-$(date +%Y%m%d-%H%M%S)"
fi
if [[ -z "$SCRATCH_PATH" && ! -e "$ROOT/.build/out" ]]; then
    rm -f "$ROOT/.build/out"
    mkdir -p "$BUILD_STORAGE/out"
    ln -s "$BUILD_STORAGE/out" "$ROOT/.build/out"
fi
BUILD_OUTPUT_ROOT="${SCRATCH_PATH:-$ROOT/.build}/out"
if [[ -d "$BUILD_OUTPUT_ROOT" ]]; then xattr -cr "$BUILD_OUTPUT_ROOT/"; fi

BUILD_ARGS=(--disable-sandbox --jobs "${NATIVE_BUILD_JOBS:-8}" -c "$CONF")
if [[ -n "$SCRATCH_PATH" ]]; then BUILD_ARGS+=(--scratch-path "$SCRATCH_PATH"); fi
swift build "${BUILD_ARGS[@]}" --product CodexBar
swift build "${BUILD_ARGS[@]}" --product CodexBarCLI
swift build "${BUILD_ARGS[@]}" --product CodexBarClaudeWatchdog
source "$ROOT/Scripts/package_product_paths.sh"
if [[ -n "$SCRATCH_PATH" ]]; then
    BIN=$(swift build --show-bin-path -c "$CONF" --scratch-path "$SCRATCH_PATH")
else
    BIN=$(codexbar_swiftpm_bin_path "$CONF")
fi

mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources" "$STAGE/Contents/Frameworks" "$STAGE/Contents/Helpers"
cp "$BIN/CodexBar" "$STAGE/Contents/MacOS/CodexBarNative"
cp "$BIN/CodexBarCLI" "$STAGE/Contents/Helpers/CodexBarCLI"
cp "$BIN/CodexBarClaudeWatchdog" "$STAGE/Contents/Helpers/CodexBarClaudeWatchdog"
cp "$ROOT/Icon.icns" "$STAGE/Contents/Resources/Icon.icns"
cp "$ROOT/LICENSE" "$STAGE/Contents/Resources/CodexBar-LICENSE.txt"
cp "$GAUGE_SOURCE/Provider-LICENSE.txt" "$STAGE/Contents/Resources/Provider-LICENSE.txt"
cp "$GAUGE_SOURCE/gauge-calibration.json" "$STAGE/Contents/Resources/"

shopt -s nullglob
for bundle in "$BIN/"*.bundle; do
    case "$(basename "$bundle")" in
        *Tests.bundle|*Widget.bundle) continue ;;
    esac
    cp -R "$bundle" "$STAGE/Contents/Resources/"
done
cp -R "$BIN/CodexBar_CodexBarCore.bundle" "$STAGE/Contents/Helpers/"
cp -R "$BIN/Sparkle.framework" "$STAGE/Contents/Frameworks/"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$STAGE/Contents/MacOS/CodexBarNative" 2>/dev/null || true

# Compile every build so deletions and restored files cannot reuse stale artwork.
ASSET_OUTPUT="$STAGE_ROOT/GaugeAssets"
mkdir -p "$ASSET_OUTPUT"
xcrun actool "$GAUGE_SOURCE/ComputeGauge.xcassets" \
    --compile "$ASSET_OUTPUT" --platform macosx \
    --minimum-deployment-target 26.0 --output-format human-readable-text
cp "$ASSET_OUTPUT/Assets.car" "$STAGE/Contents/Resources/Assets.car"

cat > "$STAGE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>CodexBar Native</string>
<key>CFBundleDisplayName</key><string>CodexBar Native</string>
<key>CFBundleIdentifier</key><string>com.will.codexbar.native.debug</string>
<key>CFBundleExecutable</key><string>CodexBarNative</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleIconFile</key><string>Icon</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSUIElement</key><true/>
<key>CodexBarNativeGauges</key><true/>
<key>CodexBarTeamID</key><string>NATIVEGAUGE</string>
<key>SUEnableAutomaticChecks</key><false/>
<key>SUFeedURL</key><string></string>
<key>NSHumanReadableCopyright</key><string>CodexBar © Peter Steinberger. MIT License. Native gauge redesign by Will.</string>
</dict></plist>
PLIST

# Opt-in development entry point for inspecting the actual status-item popup.
if [[ -n "${NATIVE_POPUP_PREVIEW_PROVIDER:-}" ]]; then
    python3 - "$STAGE/Contents/Info.plist" <<'PYPLIST'
import os, plistlib, sys
path = sys.argv[1]
with open(path, "rb") as source:
    info = plistlib.load(source)
info["CodexBarNativePopupPreview"] = os.environ["NATIVE_POPUP_PREVIEW_PROVIDER"]
with open(path, "wb") as target:
    plistlib.dump(info, target)
PYPLIST
fi

printf 'Upstream revision: %s\nGauge source: current UsageIndicator component\n' "$(/usr/bin/git rev-parse HEAD)" \
    > "$STAGE/Contents/Resources/Build-Provenance.txt"
(
    cd "$GAUGE_SOURCE"
    /usr/bin/shasum -a 256 ComputeGauge.swift LaurelGauge.swift NativeGaugeGeometry.swift UsageModel.swift \
        ServiceIdentity.swift gauge-calibration.json
) >> "$STAGE/Contents/Resources/Build-Provenance.txt"
(
    cd "$STAGE"
    /usr/bin/shasum -a 256 Contents/Resources/Assets.car
) >> "$STAGE/Contents/Resources/Build-Provenance.txt"
xattr -cr "$STAGE"
find "$STAGE" -name '._*' -delete
bash "$ROOT/Scripts/native_signing.sh" "$STAGE"
codesign --verify --deep --strict "$STAGE"
# iCloud reintroduces FinderInfo on nested packages. Keep the signed runtime
# outside cloud storage and expose it here through a stable link plus an archive.
mkdir -p "$(dirname "$LOCAL_APP")" "$ROOT/.build/native-package"
if [[ -d "$LOCAL_APP" ]]; then
    mv "$LOCAL_APP" "$BUILD_STORAGE/Previous Native $(date +%Y%m%d-%H%M%S).app"
fi
ditto --noextattr --norsrc "$STAGE" "$LOCAL_APP"
xattr -cr "$LOCAL_APP"
codesign --verify --deep --strict "$LOCAL_APP"
ditto -c -k --keepParent --norsrc --noextattr "$STAGE" "$WORKSPACE/App/CodexBar Native.zip"
if [[ -L "$APP" ]]; then
    rm "$APP"
elif [[ -d "$APP" ]]; then
    mv "$APP" "$ROOT/.build/native-package/Previous Cloud Native $(date +%Y%m%d-%H%M%S).app"
fi
ln -s "$LOCAL_APP" "$APP"
printf 'Built %s (workspace link: %s)\n' "$LOCAL_APP" "$APP"
