#!/bin/zsh
# Builds "Notch Island.app" into ./build and (with --install) copies it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Notch Island.app"

swift build -c release
mkdir -p build
clang -fobjc-arc -O2 -framework Foundation -dynamiclib \
    Adapter/NowPlayingAdapter.m -o build/NowPlayingAdapter.dylib

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/NotchIsland" "$APP/Contents/MacOS/NotchIsland"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp build/NowPlayingAdapter.dylib Adapter/adapter.pl Resources/AppIcon.icns "$APP/Contents/Resources/"

# Signing: put a code-signing identity (name or SHA-1 from
# `security find-identity -v -p codesigning`) in .signing-identity (git-ignored)
# so macOS keeps your Accessibility / Calendar permissions across rebuilds.
# Without it the app is signed ad-hoc, which works but resets permissions
# every build.
IDENTITY="-"
if [[ -f .signing-identity ]]; then IDENTITY="$(tr -d '[:space:]' < .signing-identity)"; fi
codesign --force --sign "$IDENTITY" "$APP/Contents/Resources/NowPlayingAdapter.dylib"
codesign --force --sign "$IDENTITY" "$APP"
[[ "$IDENTITY" == "-" ]] && echo "Signed ad-hoc" || echo "Signed with $IDENTITY"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x NotchIsland 2>/dev/null || true
    mkdir -p ~/Applications
    rm -rf ~/Applications/"Notch Island.app"
    cp -R "$APP" ~/Applications/
    open ~/Applications/"Notch Island.app"
    echo "Installed and launched ~/Applications/Notch Island.app"
fi
