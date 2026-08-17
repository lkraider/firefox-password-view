#!/bin/sh
# Builds and packages the release artifacts: the TUI binary, the macOS app,
# and the Windows app for both architectures. Every one is a reproducible
# build. See build.zig's `strip` and macos/scripts/bundle.sh's -gnone for why,
# and their commit messages for what was verified.
# .github/workflows/release.yml runs this to build the published artifacts.
# .github/workflows/ci.yml's reproducible-build job runs this twice and diffs
# the output. Both jobs exercise the same packaging.
set -eu

version="${1:?usage: package-release.sh <version> <output-dir>}"
out="${2:?usage: package-release.sh <version> <output-dir>}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
zig="$repo_root/zig/zig-aarch64-macos-0.16.0/zig"
mkdir -p "$out"
out="$(cd "$out" && pwd)"

(cd "$repo_root" && "$zig" build -Doptimize=ReleaseSafe)

touch -t 202601010000 "$repo_root/zig-out/bin/ffpw"
tar --numeric-owner --uid 0 --gid 0 -cf - -C "$repo_root/zig-out/bin" ffpw | gzip -n -9 > "$out/ffpw-aarch64-macos.tar.gz"

(cd "$repo_root/macos" && ./scripts/bundle.sh release)
ditto -c -k --keepParent \
    "$repo_root/macos/.build/release/FirefoxPasswordView.app" \
    "$out/FirefoxPasswordView-${version}-macos.zip"

# The Windows builds come last, because each one overwrites zig-out and the
# macOS app links zig-out/lib/libffpw.a.
#
# UTM on Apple Silicon runs Windows 11 on ARM64, so the arm64 build is the one
# that runs natively in the test VM. That same VM runs the x86_64 build under
# Windows' x64 emulation, so one VM verifies both artifacts.
#
# -X drops the extra attributes zip stores per entry, and the touch above
# fixes the entry's mtime. Two runs then write the same bytes.
for pair in "x86_64-windows-gnu x86_64" "aarch64-windows-gnu arm64"; do
    set -- $pair
    (cd "$repo_root" && "$zig" build -Dtarget="$1" -Doptimize=ReleaseSmall)
    touch -t 202601010000 "$repo_root/zig-out/bin/FirefoxPasswordView.exe"
    rm -f "$out/FirefoxPasswordView-${version}-windows-$2.zip"
    (cd "$repo_root/zig-out/bin" && zip -X -q -9 \
        "$out/FirefoxPasswordView-${version}-windows-$2.zip" FirefoxPasswordView.exe)
done
