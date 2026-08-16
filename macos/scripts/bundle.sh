#!/bin/sh
# Wraps swift build's plain executable in a minimal .app bundle. Without a
# bundle, LaunchServices never registers the process, so the window cannot
# take keyboard focus and Finder cannot launch it without a terminal.
#
# Defaults to release: Debug disables Swift's whole-module optimization and
# Zig's inlining, which is most of why the app felt sluggish. Pass "debug"
# for a fast dev rebuild instead.
set -eu

config="${1:-release}"
cd "$(dirname "$0")/.."
repo_root="$(cd .. && pwd)"

if [ "$config" = "release" ]; then
    zig_optimize=ReleaseSafe
else
    zig_optimize=Debug
fi
(cd "$repo_root" && ./zig/zig-aarch64-macos-0.16.0/zig build -Doptimize="$zig_optimize")

swift build -c "$config"

app=".build/$config/FirefoxPasswordView.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp ".build/$config/FirefoxPasswordView" "$app/Contents/MacOS/FirefoxPasswordView"
cp "Info.plist" "$app/Contents/Info.plist"
codesign --force --deep --sign - "$app"

echo "$app"
