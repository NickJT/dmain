#!/bin/sh
# Builds Dmain, the house admin app, wraps it as an app (.build/Dmain.app), and
# installs it as ~/Applications/Dmain.app.
# The app runs the dmain built here, beside its own binary, so both halves of
# the stream always come from one checkout. A bare `swift run` works too, using
# the checkout's zig-out/bin/dmain, but has no Dock icon and its Local Network
# permission is attributed to the terminal rather than to the app.
set -eu
cd "$(dirname "$0")"
here=$PWD
(cd ../dmain && zig build -Doptimize=ReleaseSafe --prefix "$here/.build/dmain")
swift build -c release
bin=$(swift build -c release --show-bin-path)
app=.build/Dmain.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp bundle/Info.plist "$app/Contents/"

# The icon, every size macOS asks for, from bundle/icon.svg.
set_=.build/AppIcon.iconset
rm -rf "$set_"
mkdir -p "$set_"
for px in 16 32 128 256 512; do
  swift bundle/render-icon.swift bundle/icon.svg "$set_/icon_${px}x${px}.png" "$px"
  swift bundle/render-icon.swift bundle/icon.svg "$set_/icon_${px}x${px}@2x.png" "$((px * 2))"
done
iconutil -c icns "$set_" -o "$app/Contents/Resources/AppIcon.icns"
cp "$bin/DmainAdmin" "$app/Contents/MacOS/"
cp .build/dmain/bin/dmain "$app/Contents/MacOS/"
# Ad hoc: runs on this Mac only. Other Macs need a Developer ID and notarisation.
codesign --force --sign - "$app/Contents/MacOS/dmain"
codesign --force --sign - "$app"

# Installed where Spotlight, Launchpad and a Dock icon find it. Replaced whole,
# so nothing from an older build is left inside; a copy that's running carries on
# until it's quit, and the next launch is this build.
installed="$HOME/Applications/Dmain.app"
mkdir -p "$HOME/Applications"
rm -rf "$installed"
ditto "$app" "$installed"
echo "$installed"
