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

# -gnone: without it, two clean rebuilds of identical source produce a
# different binary (verified: swiftc/ld embeds something debug-info-derived
# that varies build to build, the same class of issue -fstrip fixes on the
# Zig side). With -gnone, two rebuilds are byte-identical, even after the
# ad-hoc codesign below.
swift build -c "$config" -Xswiftc -gnone

app=".build/$config/FirefoxPasswordView.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp ".build/$config/FirefoxPasswordView" "$app/Contents/MacOS/FirefoxPasswordView"
cp "Info.plist" "$app/Contents/Info.plist"
codesign --force --deep --sign - "$app"

# A fixed mtime on every file, since the app's contents are already
# byte-identical across rebuilds by this point: without this, a zip made
# from this bundle would still vary run to run purely from timestamps.
/usr/bin/find "$app" -exec touch -t 202601010000 {} +

echo "$app"
