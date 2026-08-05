#!/bin/sh
# EasyMacTool Release packaging entrypoint.
# Builds Release, packages to dist/EasyMacTool.zip (no AppleDouble files),
# writes SHA-256 sidecar, prints artifact path + digest.
#
# Usage:
#   ./script/release.sh                # build + package + sha256
#   ./script/release.sh --verify       # also launch the built app to confirm it runs
set -e

APP_NAME="EasyMacTool"
PROJECT="${PROJECT:-$(dirname "$0")/../EasyMacTool.xcodeproj}"
CONFIGURATION="Release"
DERIVED_DATA="${DERIVED_DATA:-/tmp/EasyMacTool-DD}"
DIST_DIR="$(dirname "$0")/../dist"
ZIP_NAME="${ZIP_NAME:-EasyMacTool.zip}"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"
SHA_PATH="$DIST_DIR/$ZIP_NAME.sha256"

# 1. Stop the running app if present (avoid file-lock issues during ditto).
echo "==> Stopping $APP_NAME if running..."
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.5

# 2. Build Release.
echo "==> Building $APP_NAME ($CONFIGURATION)..."
xcodebuild \
    -project "$PROJECT" \
    -scheme "$APP_NAME" \
    -configuration "$CONFIGURATION" \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    build

# 3. Resolve built .app path.
APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: Built app not found at $APP_PATH"
    exit 1
fi

# 4. Prepare dist directory.
mkdir -p "$DIST_DIR"
# Clean stale artifacts so a failed prior run doesn't leave a stale zip.
rm -f "$ZIP_PATH" "$SHA_PATH"

# 5. Package with ditto --norsrc --noextattr to avoid AppleDouble (._) files.
#    --keepParent preserves the EasyMacTool.app/ top-level entry so unzipping
#    yields EasyMacTool.app/ (not its contents spilled into cwd).
echo "==> Packaging $ZIP_NAME..."
ditto -c -k --norsrc --noextattr --keepParent "$APP_PATH" "$ZIP_PATH"

# 6. Verify no AppleDouble _._ files inside the archive.
APPLEDOUBLE_COUNT=$(unzip -l "$ZIP_PATH" | grep -c '\._' || true)
if [ "$APPLEDOUBLE_COUNT" -ne 0 ]; then
    echo "ERROR: $APPLEDOUBLE_COUNT AppleDouble (._) files found in $ZIP_PATH"
    unzip -l "$ZIP_PATH" | grep '\._'
    exit 1
fi
echo "==> OK: no AppleDouble files in archive."

# 7. Compute SHA-256 sidecar (standard shasum format: <hash>  <filename>).
echo "==> Computing SHA-256..."
shasum -a 256 "$ZIP_PATH" > "$SHA_PATH"
SHA=$(awk '{print $1}' < "$SHA_PATH")

# 8. Optionally launch to confirm the built app runs.
case "${1:-}" in
    --verify)
        echo "==> Launching to verify..."
        /usr/bin/open -n "$APP_PATH"
        sleep 2
        if pgrep -x "$APP_NAME" >/dev/null; then
            echo "OK: $APP_NAME is running (pid $(pgrep -x "$APP_NAME"))"
            pkill -x "$APP_NAME" 2>/dev/null || true
        else
            echo "FAIL: $APP_NAME did not launch"
            exit 1
        fi
        ;;
esac

# 9. Print summary.
echo ""
echo "==> Release packaged:"
echo "    zip:     $ZIP_PATH  ($(du -h "$ZIP_PATH" | cut -f1))"
echo "    sha256:  $SHA"
echo "    sidecar: $SHA_PATH"
