#!/bin/sh
# Builds and packages the release artifacts, the TUI binary and the
# macOS app, zipped. Both are reproducible builds. See build.zig's
# `strip` and macos/scripts/bundle.sh's -gnone for why, and their commit
# messages for what was verified. .github/workflows/release.yml runs
# this to build the published artifacts. .github/workflows/ci.yml's
# reproducible-build job runs this twice and diffs the output. Both
# jobs exercise the same packaging.
set -eu

version="${1:?usage: package-release.sh <version> <output-dir>}"
out="${2:?usage: package-release.sh <version> <output-dir>}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$out"

(cd "$repo_root" && ./zig/zig-aarch64-macos-0.16.0/zig build -Doptimize=ReleaseSafe)

touch -t 202601010000 "$repo_root/zig-out/bin/ffpw"
tar --numeric-owner --uid 0 --gid 0 -cf - -C "$repo_root/zig-out/bin" ffpw | gzip -n -9 > "$out/ffpw-aarch64-macos.tar.gz"

(cd "$repo_root/macos" && ./scripts/bundle.sh release)
ditto -c -k --keepParent \
    "$repo_root/macos/.build/release/FirefoxPasswordView.app" \
    "$out/FirefoxPasswordView-${version}-macos.zip"
