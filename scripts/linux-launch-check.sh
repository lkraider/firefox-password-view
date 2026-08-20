#!/bin/sh
# Drives the keywise paths that run without a terminal. Exits non-zero on a
# failure.
# ci.yml's two Linux jobs run this after the ReleaseSafe build.
#
# The copy path needs a `y` press. libvaxis reads keys from /dev/tty, so a
# pipe on stdin reaches nothing. Driving that path needs a pty writer.
#
# The roots below repeat core/src/profiles.zig's home_relative_dirs. Case 4
# reads the error message. That message prints home_relative_dirs. An edit to
# either list fails this script.
set -eu

keywise="${1:-zig-out/bin/keywise}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$repo_root/core/testdata/two-profiles"

[ -x "$keywise" ] || { echo "FAIL  no executable at $keywise" >&2; exit 1; }
keywise="$(cd "$(dirname "$keywise")" && pwd)/$(basename "$keywise")"

roots=".mozilla/firefox snap/firefox/common/.mozilla/firefox .var/app/org.mozilla.firefox/.mozilla/firefox"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failures=0
mark=0

fail() {
    echo "FAIL  $1"
    failures=$((failures + 1))
}

begin() {
    mark="$failures"
}

finish() {
    [ "$failures" -eq "$mark" ] && echo "PASS  $1"
    return 0
}

plant() {
    mkdir -p "$1"
    cp -R "$fixture/." "$1/"
}

# 1. Each root on its own.
begin
for rel in $roots; do
    home="$tmp/single"
    rm -rf "$home"
    plant "$home/$rel"

    out="$tmp/out"
    err="$tmp/err"
    HOME="$home" "$keywise" --list-profiles > "$out" 2> "$err" \
        || fail "--list-profiles exited non-zero for $rel"

    grep -q '^default	' "$out" || fail "$rel: no 'default' row on stdout"
    grep -q '^default-release	' "$out" || fail "$rel: no 'default-release' row on stdout"
    grep -qx "$home/$rel" "$err" || fail "$rel: stderr named $(cat "$err") instead"
done
finish "each root resolves on its own"

# 2. Two roots populated. The order in home_relative_dirs decides.
begin
home="$tmp/both"
plant "$home/.mozilla/firefox"
plant "$home/snap/firefox/common/.mozilla/firefox"
HOME="$home" "$keywise" --list-profiles > "$tmp/out" 2> "$tmp/err" \
    || fail "--list-profiles exited non-zero with two roots"
grep -qx "$home/.mozilla/firefox" "$tmp/err" || fail "two roots: took $(cat "$tmp/err")"
finish "the first populated root wins"

# 3. --profile must not trigger the walk. main resolved the root before it read
# --profile once. That made a populated root a precondition for every run.
# Reaching the UI needs a pty, so this reads stderr instead.
begin
bare="$tmp/no-firefox"
mkdir -p "$bare"
HOME="$bare" "$keywise" --profile "$fixture/Profiles/real.default-release" \
    > "$tmp/out" 2> "$tmp/err" || true
if grep -q "found no profiles.ini" "$tmp/err"; then
    fail "--profile walked the roots: $(cat "$tmp/err")"
fi
finish "--profile opens a directory with no root present"

# 4. An empty HOME. The message names every path the walk tried.
begin
empty="$tmp/empty"
mkdir -p "$empty"
if HOME="$empty" "$keywise" > "$tmp/out" 2> "$tmp/err"; then
    fail "an empty HOME exited 0"
fi
for rel in $roots; do
    grep -q "$empty/$rel" "$tmp/err" || fail "the error message omits $rel"
done
finish "the error names every path searched"

# 5. --help.
begin
"$keywise" --help > "$tmp/out" 2>&1 || fail "--help exited non-zero"
grep -q -- "--profile" "$tmp/out" || fail "--help omits --profile"
finish "--help prints the usage text"

[ "$failures" -eq 0 ] || { echo "$failures checks failed"; exit 1; }
echo "PASS  every case"
