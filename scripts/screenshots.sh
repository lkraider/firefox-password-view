#!/bin/sh
# Regenerates the README screenshots in docs/images/ from the current source.
#
# Both front ends run against a sandbox HOME built from
# core/testdata/sync-shaped, so the images can only ever show that
# fixture's synthetic credentials. Pointing either front end at a real
# profile would put real hostnames and usernames in a committed PNG.
#
# Every capture targets a CoreGraphics window id. screencapture -R takes
# whatever occupies a screen rectangle, so a window that moves or falls
# behind another one puts the wrong content in the file.
#
# Needs two TCC permissions for the terminal that runs this, both under
# System Settings > Privacy & Security:
#   Screen & System Audio Recording   for screencapture
#   Accessibility                     for the keystrokes that drive the TUI
#
# Usage:
#   scripts/screenshots.sh            both images
#   scripts/screenshots.sh tui        the terminal UI only
#   scripts/screenshots.sh app        the macOS app only
#   FFPW_SKIP_BUILD=1 scripts/screenshots.sh   reuse the existing builds
set -eu

target="${1:-all}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
out_dir="$repo_root/docs/images"
work="$(mktemp -d /tmp/ffpw-shots.XXXXXX)"
sandbox="$work/home"
app_bundle="$repo_root/macos/.build/release/FirefoxPasswordView.app"
tui_bin="$repo_root/zig-out/bin/ffpw"
term_title="ffpw-shot"

close_shot_windows() {
    # Matches both titles, since the capture renames the window to "ffpw".
    osascript >/dev/null 2>&1 <<EOS || true
tell application "Terminal"
  close (every window whose custom title is "$term_title") saving no
  close (every window whose custom title is "ffpw") saving no
end tell
EOS
}

cleanup() {
    pkill -f "$app_bundle/Contents/MacOS/FirefoxPasswordView" 2>/dev/null || true
    pkill -f "$tui_bin" 2>/dev/null || true
    close_shot_windows
    rm -rf "$work"
}
trap cleanup EXIT INT TERM

# --- preflight -------------------------------------------------------------

if ! screencapture -x "$work/probe.png" 2>/dev/null || [ ! -s "$work/probe.png" ]; then
    echo "screencapture produced nothing. Grant Screen & System Audio Recording to this terminal." >&2
    exit 1
fi
rm -f "$work/probe.png"

if ! osascript -e 'tell application "System Events" to count processes' >/dev/null 2>&1; then
    echo "System Events refused. Grant Accessibility to this terminal." >&2
    exit 1
fi

# --- window id helper ------------------------------------------------------
# CGWindowListCopyWindowInfo has no CLI. JXA's ObjC bridge does not resolve
# its signature, so this compiles a Swift one-shot into the work dir.

cat > "$work/winid.swift" <<'SWIFT'
import CoreGraphics
import Foundation

// "<windowNumber>\t<ownerPID>\t<ownerName>\t<windowName>"
let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
    exit(1)
}
for w in list {
    let num = w[kCGWindowNumber as String] as? Int ?? -1
    let pid = w[kCGWindowOwnerPID as String] as? Int ?? -1
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    let name = w[kCGWindowName as String] as? String ?? ""
    print("\(num)\t\(pid)\t\(owner)\t\(name)")
}
SWIFT
swiftc -O -o "$work/winid" "$work/winid.swift"

# window_id_for_pid <pid> -> window number on stdout, empty when absent
window_id_for_pid() {
    "$work/winid" | awk -F'\t' -v p="$1" '$2==p {print $1; exit}'
}

# window_id_for_terminal -> window number of the Terminal window titled $term_title
window_id_for_terminal() {
    "$work/winid" | awk -F'\t' -v t="$term_title" '$3=="Terminal" && index($4, t) {print $1; exit}'
}

# capture <window-id> <output-path>
capture() {
    screencapture -x -o -l "$1" -t png "$2"
    [ -s "$2" ] || { echo "capture of window $1 produced nothing" >&2; exit 1; }
}

# --- sandbox profile -------------------------------------------------------

mkdir -p "$sandbox/Library/Application Support/Firefox/Profiles"
cp -R "$repo_root/core/testdata/sync-shaped" \
      "$sandbox/Library/Application Support/Firefox/Profiles/demo.default-release"
cat > "$sandbox/Library/Application Support/Firefox/profiles.ini" <<'INI'
[Profile0]
Name=default-release
IsRelative=1
Path=Profiles/demo.default-release

[InstallDEMO0000DEMO0000]
Default=Profiles/demo.default-release
Locked=1

[General]
StartWithLastProfile=1
Version=2
INI

mkdir -p "$out_dir"

# --- terminal UI -----------------------------------------------------------

shoot_tui() {
    [ -n "${FFPW_SKIP_BUILD:-}" ] || (cd "$repo_root" && ./zig/zig-aarch64-macos-0.16.0/zig build)
    [ -x "$tui_bin" ] || { echo "missing $tui_bin" >&2; exit 1; }

    # The window is sized before ffpw starts so libvaxis reads the final
    # size once. 88x10 fits the five fixture rows with no blank filler.
    osascript >/dev/null <<EOS
tell application "Terminal"
  activate
  do script ""
  delay 1
  set number of rows of front window to 10
  set number of columns of front window to 88
  set custom title of front window to "$term_title"
  delay 0.5
  do script "clear; HOME=$sandbox $tui_bin" in front window
end tell
EOS
    sleep 3

    # down, enter        reveal row 2
    # down, down, enter  select the chrome://FirefoxAccounts row, ask to confirm
    osascript -e 'tell application "Terminal" to activate' >/dev/null
    sleep 1
    for k in 125 36 125 125 36; do
        osascript -e "tell application \"System Events\" to key code $k" >/dev/null
        sleep 0.4
    done
    sleep 1

    id="$(window_id_for_terminal)"
    [ -n "$id" ] || { echo "no Terminal window titled $term_title" >&2; exit 1; }

    # $term_title exists to find the window. Rename it before the capture so
    # the committed image carries the binary's name. The window id survives.
    osascript >/dev/null <<EOS
tell application "Terminal"
  set custom title of (first window whose custom title is "$term_title") to "ffpw"
end tell
EOS
    sleep 1
    capture "$id" "$out_dir/tui.png"
    echo "wrote $out_dir/tui.png"

    # "q" quits ffpw. Closing the window first makes Terminal ask whether to
    # terminate the running process, and that dialog blocks the script.
    osascript -e 'tell application "Terminal" to activate' >/dev/null
    sleep 0.5
    osascript -e 'tell application "System Events" to keystroke "q"' >/dev/null
    sleep 1
    close_shot_windows
}

# --- macOS app -------------------------------------------------------------

shoot_app() {
    [ -n "${FFPW_SKIP_BUILD:-}" ] || (cd "$repo_root/macos" && ./scripts/bundle.sh release >/dev/null)
    [ -d "$app_bundle" ] || { echo "missing $app_bundle" >&2; exit 1; }

    # .build/release is a symlink to .build/arm64-apple-macosx/release. open
    # resolves it, so the running process reports the physical path and a
    # pgrep pattern built from the symlink matches nothing.
    app_bundle="$(cd "$app_bundle" && pwd -P)"

    # One instance at a time, so window_id_for_pid has a single candidate and
    # the capture cannot pick up somebody else's window. Until b3bb120 a
    # second instance also drew an empty entry list, and that put a
    # screenshot with no rows in docs/images/.
    if pgrep -f "FirefoxPasswordView.app/Contents/MacOS" >/dev/null 2>&1; then
        echo "quitting a running FirefoxPasswordView first"
        pkill -f "FirefoxPasswordView.app/Contents/MacOS" || true
        sleep 2
    fi

    # open, so LaunchServices registers the process. Running
    # Contents/MacOS/FirefoxPasswordView directly leaves it unregistered and
    # its window unable to become key. --env points the app at the fixture.
    open -n --env "HOME=$sandbox" -a "$app_bundle"

    id=""
    pid=""
    i=0
    while [ $i -lt 20 ]; do
        sleep 1
        pid="$(pgrep -f "$app_bundle/Contents/MacOS/FirefoxPasswordView" | head -1)"
        [ -n "$pid" ] && id="$(window_id_for_pid "$pid")"
        [ -n "$id" ] && break
        i=$((i + 1))
    done
    [ -n "$id" ] || { echo "app window never appeared" >&2; exit 1; }

    # The rows populate a frame or two after the window exists.
    sleep 2
    id="$(window_id_for_pid "$pid")"
    capture "$id" "$out_dir/macos-app.png"
    echo "wrote $out_dir/macos-app.png"

    pkill -f "$app_bundle/Contents/MacOS/FirefoxPasswordView" 2>/dev/null || true
}

case "$target" in
    tui) shoot_tui ;;
    app) shoot_app ;;
    all) shoot_tui; shoot_app ;;
    *) echo "usage: screenshots.sh [all|tui|app]" >&2; exit 2 ;;
esac
