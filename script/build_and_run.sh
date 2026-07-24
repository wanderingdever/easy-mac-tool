#!/bin/sh
# EasyMacTool build & run entrypoint.
# Usage:
#   ./script/build_and_run.sh           # kill, build, run
#   ./script/build_and_run.sh --debug    # launch under lldb
#   ./script/build_and_run.sh --logs     # stream unified logs after launch
#   ./script/build_and_run.sh --verify   # confirm process exists after launch
set -e

APP_NAME="EasyMacTool"
PROJECT="${PROJECT:-$(dirname "$0")/../EasyMacTool.xcodeproj}"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA="${DERIVED_DATA:-/tmp/EasyMacTool-DD}"

# 1. Stop the running app if present.
echo "==> Stopping $APP_NAME if running..."
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.5

# 2. Build.
echo "==> Building $APP_NAME ($CONFIGURATION)..."
xcodebuild \
    -project "$PROJECT" \
    -scheme "$APP_NAME" \
    -configuration "$CONFIGURATION" \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    build

# Resolve built .app path.
APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: Built app not found at $APP_PATH"
    exit 1
fi

# 3. Verify icon injection ran.
ICON_PATH="$APP_PATH/Contents/Resources/AppIcon.icns"
if [ -f "$ICON_PATH" ]; then
    echo "==> AppIcon.icns present: $(file "$ICON_PATH" | cut -d: -f2-)"
else
    echo "WARNING: AppIcon.icns missing at $ICON_PATH"
fi

# Print Info.plist icon keys for verification.
echo "==> Info.plist icon keys:"
/usr/libexec/PlistBuddy -c "Print :CFBundleIcon" "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "(no CFBundleIcon)"
/usr/libexec/PlistBuddy -c "Print :CFBundleIconName" "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "(no CFBundleIconName)"

# 4. Launch.
case "${1:-}" in
    --debug)
        echo "==> Launching under lldb..."
        lldb -- "$APP_PATH/Contents/MacOS/$APP_NAME"
        ;;
    --logs)
        echo "==> Launching + streaming unified logs..."
        /usr/bin/open -n "$APP_PATH"
        /usr/bin/log stream --predicate 'process == "EasyMacTool"' --info
        ;;
    --verify)
        echo "==> Launching and verifying process..."
        /usr/bin/open -n "$APP_PATH"
        sleep 2
        if pgrep -x "$APP_NAME" >/dev/null; then
            echo "OK: $APP_NAME is running (pid $(pgrep -x "$APP_NAME"))"
        else
            echo "FAIL: $APP_NAME is not running"
            exit 1
        fi
        ;;
    *)
        echo "==> Launching $APP_PATH..."
        /usr/bin/open -n "$APP_PATH"
        echo "OK: launched."
        ;;
esac
