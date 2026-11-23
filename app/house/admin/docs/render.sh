#!/bin/sh
# Renders each screen in mocks.html to a PNG beside it, with headless Chrome.
# One argument renders into that directory instead, to look before committing.
set -eu
cd "$(dirname "$0")"
out=${1:-.}
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
for id in attention power-on charts config services hub-console; do
    "$chrome" --headless=new --hide-scrollbars --force-device-scale-factor=2 \
        --window-size=1100,700 --screenshot="$out/$id.png" \
        "file://$PWD/mocks.html#$id" 2>/dev/null
    echo "$out/$id.png"
done
