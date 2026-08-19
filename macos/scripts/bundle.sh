#!/bin/sh
# Wraps swift build's plain executable in a minimal .app bundle. A plain
# executable launches outside LaunchServices. The window opens, but it
# cannot take keyboard focus from the terminal that launched it.
# Wrapping it in a bundle registers the process with LaunchServices, so
# Finder can launch it too.
#
# Defaults to release. Debug disables Swift's whole-module optimization
# and Zig's inlining. Those two optimizations are why filtering and
# reveal felt sluggish in Debug. Pass "debug" for a fast dev rebuild.
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

# swiftc/ld embeds something debug-info-derived into the binary that
# varies build to build, the same class of issue -fstrip fixes on the
# Zig side. -gnone strips that. Verified: two clean rebuilds of
# identical source are byte-identical, even after the ad-hoc codesign
# below.
swift build -c "$config" -Xswiftc -gnone

app=".build/$config/FirefoxPasswordView.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp ".build/$config/FirefoxPasswordView" "$app/Contents/MacOS/FirefoxPasswordView"
cp "Info.plist" "$app/Contents/Info.plist"
# Info.plist's CFBundleIconFile names this file. scripts/make-icon.swift
# draws it, and the committed .icns is what a build copies.
cp "Icon.icns" "$app/Contents/Resources/Icon.icns"
codesign --force --deep --sign - "$app"

# A fixed mtime on every file. The app's contents are already
# byte-identical across rebuilds by this point. Fixing every file's
# mtime removes timestamps as the last remaining source of variance
# between two zips of the same bundle.
#
# The trailing Z makes touch read the stamp as UTC. `touch -t` read it as
# local time, so the instant it wrote moved with the host's zone.
# scripts/release-package.sh stamps its own archive members with this value.
/usr/bin/find "$app" -exec touch -d 2026-01-01T00:00:00Z {} +

echo "$app"
