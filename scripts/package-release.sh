#!/bin/sh
# Builds and packages the release artifacts: the TUI binary, the macOS app,
# and the Windows app for both architectures. Every one is a reproducible
# build. See build.zig's `strip` and macos/scripts/bundle.sh's -gnone for why,
# and their commit messages for what was verified.
# .github/workflows/release.yml runs this to build the published artifacts.
# .github/workflows/ci.yml's reproducible-build job runs this twice and diffs
# the output. Both jobs exercise the same packaging.
#
# The cross builds start first and run beside the macOS chain. Each one
# gets its own cache directory and its own install prefix, so it reads no
# artifact of the others and leaves zig-out to the macOS build. Measured on a
# development Mac: an exe from a build with these flags has the same SHA-256 as
# an exe from a build without them.
set -eu

version="${1:?usage: package-release.sh <version> <output-dir>}"
out="${2:?usage: package-release.sh <version> <output-dir>}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
zig="$repo_root/zig/zig-aarch64-macos-0.16.0/zig"
mkdir -p "$out"
out="$(cd "$out" && pwd)"

# ReleaseSafe keeps the bounds, alignment and overflow checks. sqlitedb.zig
# reads every offset in key4.db out of the file itself, and logins.json and
# the SDR blobs arrive the same way. A bad offset panics under these checks.
# ReleaseSmall drops the checks and writes a Windows zip 81 KB smaller.
cross_jobs=""
for pair in "x86_64-windows-gnu win-x86_64" "aarch64-windows-gnu win-arm64" \
            "x86_64-linux-musl linux-x86_64" "aarch64-linux-musl linux-arm64"; do
    set -- $pair
    (cd "$repo_root" && "$zig" build -Dtarget="$1" -Doptimize=ReleaseSafe \
        --cache-dir ".zig-cache-$2" -p "out-$2") > "$repo_root/build-$2.log" 2>&1 &
    cross_jobs="$cross_jobs $!:$2"
done

(cd "$repo_root" && "$zig" build -Doptimize=ReleaseSafe)

touch -t 202601010000 "$repo_root/zig-out/bin/ffpw"
tar --numeric-owner --uid 0 --gid 0 -cf - -C "$repo_root/zig-out/bin" ffpw | gzip -n -9 > "$out/ffpw-aarch64-macos.tar.gz"

(cd "$repo_root/macos" && ./scripts/bundle.sh release)
ditto -c -k --keepParent \
    "$repo_root/macos/.build/release/FirefoxPasswordView.app" \
    "$out/FirefoxPasswordView-${version}-macos.zip"

status=0
for job in $cross_jobs; do
    wait "${job%%:*}" || status=1
    echo "--- ${job#*:}"
    cat "$repo_root/build-${job#*:}.log"
done
[ "$status" -eq 0 ] || exit 1

# -X drops the extra attributes zip stores per entry, and the touch below fixes
# the entry's mtime. Two runs then write the same bytes.
for arch in x86_64 arm64; do
    exe="$repo_root/out-win-$arch/bin/FirefoxPasswordView.exe"
    touch -t 202601010000 "$exe"
    rm -f "$out/FirefoxPasswordView-${version}-windows-$arch.zip"
    (cd "$(dirname "$exe")" && zip -X -q -9 \
        "$out/FirefoxPasswordView-${version}-windows-$arch.zip" FirefoxPasswordView.exe)
done

# tui_mod links no C library, so the musl target writes a static binary. It
# runs on any distro.
for pair in "linux-x86_64 x86_64" "linux-arm64 aarch64"; do
    set -- $pair
    bin="$repo_root/out-$1/bin/ffpw"
    touch -t 202601010000 "$bin"
    tar --numeric-owner --uid 0 --gid 0 -cf - -C "$(dirname "$bin")" ffpw \
        | gzip -n -9 > "$out/ffpw-$2-linux.tar.gz"
done
