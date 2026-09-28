#!/usr/bin/env bash
# Builds "Steam Idler.app" for macOS and installs it, using only the Swift
# compiler from Xcode or the Command Line Tools (xcode-select --install).
# No packages, no downloads.
#
#   ./build.sh                  build and install into /Applications
#   ./build.sh ~/Applications   install somewhere else
#
# The build writes straight into the installed copy, so there is only ever one.
# A copy running from that folder is quit first (which stops its games) and
# reopened afterwards; copies running from elsewhere are left alone.
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
src="$root/macos"
dest="${1:-/Applications}"
app="$dest/Steam Idler.app"
bundle_id="com.r33hab.steamidler"
version="1.1.0"
min_macos="13.0"

command -v swiftc >/dev/null || { echo "swiftc not found. Install the Command Line Tools: xcode-select --install" >&2; exit 1; }
mkdir -p "$dest"
[ -w "$dest" ] || { echo "$dest is not writable. Pass another folder, e.g. ./build.sh ~/Applications" >&2; exit 1; }
# Absolute, so it compares equal to the path a running copy reports.
dest="$(cd "$dest" && pwd -P)"
app="$dest/Steam Idler.app"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Universal binaries: both Apple silicon and Intel Macs.
for arch in arm64 x86_64; do
    echo "Compiling SteamIdlerWorker ($arch)..."
    swiftc -swift-version 5 -O -target "$arch-apple-macos$min_macos" \
        -o "$work/SteamIdlerWorker-$arch" "$src/Worker/main.swift"

    echo "Compiling SteamIdler ($arch)..."
    swiftc -swift-version 5 -O -target "$arch-apple-macos$min_macos" -module-name SteamIdler \
        -o "$work/SteamIdler-$arch" "$src"/App/*.swift
done

echo "Drawing the icon..."
swiftc -swift-version 5 -O -o "$work/make-icon" "$src/make-icon.swift"
"$work/make-icon" "$work/SteamIdler.iconset"
iconutil -c icns "$work/SteamIdler.iconset" -o "$work/SteamIdler.icns"

bundle="$work/Steam Idler.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
lipo -create -output "$bundle/Contents/MacOS/SteamIdler" "$work"/SteamIdler-arm64 "$work"/SteamIdler-x86_64
lipo -create -output "$bundle/Contents/MacOS/SteamIdlerWorker" "$work"/SteamIdlerWorker-arm64 "$work"/SteamIdlerWorker-x86_64
cp "$work/SteamIdler.icns" "$bundle/Contents/Resources/SteamIdler.icns"

cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>Steam Idler</string>
	<key>CFBundleDisplayName</key><string>Steam Idler</string>
	<key>CFBundleExecutable</key><string>SteamIdler</string>
	<key>CFBundleIconFile</key><string>SteamIdler</string>
	<key>CFBundleIdentifier</key><string>${bundle_id}</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>${version}</string>
	<key>CFBundleVersion</key><string>${version}</string>
	<key>LSMinimumSystemVersion</key><string>${min_macos}</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc signature, deliberately without the hardened runtime: the worker loads
# Valve's libsteam_api.dylib from the Steam install, which library validation
# would refuse.
codesign --force --sign - "$bundle/Contents/MacOS/SteamIdlerWorker"
codesign --force --sign - "$bundle"

# Only the copy being replaced is quit; one running from anywhere else keeps idling.
running_copy() {
    local pid
    for pid in $(pgrep -x SteamIdler || true); do
        if [ "$(ps -o comm= -p "$pid" 2>/dev/null)" = "$app/Contents/MacOS/SteamIdler" ]; then echo "$pid"; fi
    done
}

was_running=0
pids="$(running_copy)"
if [ -n "$pids" ]; then
    was_running=1
    echo "Quitting the running Steam Idler..."
    kill -TERM $pids || true
    for _ in $(seq 1 50); do [ -n "$(running_copy)" ] || break; sleep 0.1; done
    if [ -n "$(running_copy)" ]; then
        echo "Steam Idler did not quit. Quit it yourself, then run build.sh again." >&2
        exit 1
    fi
fi

rm -rf "$app"
mv "$bundle" "$app"

echo ""
echo "Build complete -> $app"
if [ "$was_running" = 1 ]; then open "$app"; fi
