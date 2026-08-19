#!/bin/sh
# Regenerates the README screenshots in docs/images/ from the current source.
#
# Every front end runs against a sandbox profile built from
# core/testdata/sync-shaped, so the images can only ever show that
# fixture's synthetic credentials. Pointing a front end at a profile on
# this machine would put its hostnames and usernames in a committed PNG.
#
# The Windows app runs under wine, and wine's comctl32 draws its own
# theme. The controls and the text match a Windows 11 run. The colours and
# the corner radii come from wine.
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
#   scripts/docs-screenshots.sh            all three images
#   scripts/docs-screenshots.sh tui        the terminal UI only
#   scripts/docs-screenshots.sh app        the macOS app only
#   scripts/docs-screenshots.sh win        the Windows app only, under wine
#   FFPW_SKIP_BUILD=1 scripts/docs-screenshots.sh   reuse the existing builds
#   FFPW_WINE=/path/to/wine scripts/docs-screenshots.sh win
set -eu

target="${1:-all}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
out_dir="$repo_root/docs/images"
work="$(mktemp -d /tmp/ffpw-shots.XXXXXX)"
sandbox="$work/home"
app_bundle="$repo_root/macos/.build/release/FirefoxPasswordView.app"
win_exe="$repo_root/zig-out/bin/FirefoxPasswordView.exe"
wine="${FFPW_WINE:-/Applications/Wine Staging.app/Contents/Resources/wine/bin/wine}"
# Screen points, title bar included. Holds the menu bar, the search box, the
# five fixture rows and the status bar.
win_height=270
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
    pkill -f "FirefoxPasswordView.exe" 2>/dev/null || true
    # wineboot starts 8 helper processes for the prefix below, and they outlive
    # both the exe and the prefix directory.
    "$repo_root/scripts/wine-shutdown.sh" "$work/wine" "$wine" 2>/dev/null || true
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
# scripts/wine-check.sh compiles the same file. See its header for what the
# columns hold.

swiftc -O -o "$work/window-list" "$repo_root/scripts/docs-window-list.swift"

# window_id_for_pid <pid> -> window number on stdout, empty when absent
window_id_for_pid() {
    "$work/window-list" | awk -F'\t' -v p="$1" '$2==p {print $1; exit}'
}

# window_bounds_for_pid <pid> -> "x y w h" on stdout, empty when absent
window_bounds_for_pid() {
    "$work/window-list" | awk -F'\t' -v p="$1" '$2==p {print $5, $6, $7, $8; exit}'
}

# window_id_for_terminal -> window number of the Terminal window titled $term_title
window_id_for_terminal() {
    "$work/window-list" | awk -F'\t' -v t="$term_title" '$3=="Terminal" && index($4, t) {print $1; exit}'
}

# capture <window-id> <output-path>
capture() {
    screencapture -x -o -l "$1" -t png "$2"
    [ -s "$2" ] || { echo "capture of window $1 produced nothing" >&2; exit 1; }
}

# --- title bar trim --------------------------------------------------------
# wine draws the Win32 controls inside a Cocoa window, and that window wears
# a macOS title bar. shoot_win cuts the bar off so the image starts at the
# menu bar the app itself draws.
#
# The bar is dark and the menu bar under it is light, so the cut row is the
# first one whose left edge reads above 200 in all three channels. Reading
# the boundary keeps this correct on a 1x display and on a 2x one. sips
# crops around the centre, so the crop itself uses CoreGraphics.

cat > "$work/trimtop.swift" <<'SWIFT'
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// trimtop <in.png> <out.png>
let args = CommandLine.arguments
guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
else { exit(1) }

let w = image.width, h = image.height
var pixels = [UInt8](repeating: 0, count: w * h * 4)
guard let ctx = CGContext(
    data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { exit(1) }
ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

// A title bar taller than a quarter of the window means the scan found
// something else. This exits 1 there. A cropped-up image would reach the
// README with the fault invisible.
let limit = h / 4
var cut = -1
for y in 0..<limit {
    let i = (y * w + 8) * 4
    if pixels[i] > 200 && pixels[i + 1] > 200 && pixels[i + 2] > 200 {
        cut = y
        break
    }
}
guard cut >= 0 else {
    FileHandle.standardError.write("no light row in the top \(limit) rows\n".data(using: .utf8)!)
    exit(1)
}

let rect = CGRect(x: 0, y: cut, width: w, height: h - cut)
guard let cropped = image.cropping(to: rect),
      let dst = CGImageDestinationCreateWithURL(
          URL(fileURLWithPath: args[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)
else { exit(1) }
CGImageDestinationAddImage(dst, cropped, nil)
guard CGImageDestinationFinalize(dst) else { exit(1) }
print("trimmed \(cut) rows")
SWIFT
swiftc -O -o "$work/trimtop" "$work/trimtop.swift"

# --- mouse helper ----------------------------------------------------------
# shoot_win pulls the bottom edge up, so the image ends near the last row.
# scripts/wine-check.sh compiles the same file for its right-clicks.

swiftc -O -o "$work/input" "$repo_root/scripts/wine-input.swift"

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

# --- Windows app -----------------------------------------------------------

shoot_win() {
    [ -x "$wine" ] || { echo "no wine at $wine. Set FFPW_WINE." >&2; exit 1; }
    # The wine build on this Mac is x86_64, and Rosetta 2 runs it. The
    # aarch64-windows-gnu exe needs the ARM64 Windows VM.
    [ -n "${FFPW_SKIP_BUILD:-}" ] || (cd "$repo_root" && \
        ./zig/zig-aarch64-macos-0.16.0/zig build win \
        -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe -Doracle=false)
    [ -x "$win_exe" ] || { echo "missing $win_exe" >&2; exit 1; }

    WINEPREFIX="$work/wine"
    export WINEPREFIX
    WINEDEBUG=-all
    export WINEDEBUG
    "$wine"boot --init >/dev/null 2>&1

    # The app reads %APPDATA%\Mozilla\Firefox. wine maps that to this path
    # under the prefix it just created.
    appdata="$WINEPREFIX/drive_c/users/$(id -un)/AppData/Roaming"
    firefox_dir="$appdata/Mozilla/Firefox"
    mkdir -p "$firefox_dir/Profiles"
    cp -R "$repo_root/core/testdata/sync-shaped" \
          "$firefox_dir/Profiles/demo.default-release"
    cat > "$firefox_dir/profiles.ini" <<'INI'
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

    "$wine" "$win_exe" >"$work/wine.log" 2>&1 &

    id=""
    pid=""
    i=0
    while [ $i -lt 25 ]; do
        sleep 1
        pid="$(pgrep -f 'FirefoxPasswordView.exe' | head -1)"
        [ -n "$pid" ] && id="$(window_id_for_pid "$pid")"
        [ -n "$id" ] && break
        i=$((i + 1))
    done
    [ -n "$id" ] || { echo "wine window never appeared" >&2; sed -n '1,20p' "$work/wine.log" >&2; exit 1; }

    osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $pid) to true" >/dev/null
    sleep 1

    # main.zig asks for a 900x600 window. Five fixture rows leave most of
    # that empty, so the bottom edge comes up to $win_height points first.
    set -- $(window_bounds_for_pid "$pid")
    [ $# -eq 4 ] || { echo "no bounds for pid $pid" >&2; exit 1; }
    "$work/input" drag "$(($1 + $3 - 2))" "$(($2 + $4 - 2))" \
                          "$(($1 + $3 - 2))" "$(($2 + win_height))"
    sleep 1

    # tab            leave the search box for the list
    # down, down     select row 2, the row the TUI image reveals
    # enter          reveal it
    for k in 48 125 125 36; do
        osascript -e "tell application \"System Events\" to key code $k" >/dev/null
        sleep 0.4
    done
    sleep 1

    id="$(window_id_for_pid "$pid")"
    capture "$id" "$work/win-raw.png"
    "$work/trimtop" "$work/win-raw.png" "$out_dir/windows-app.png"
    echo "wrote $out_dir/windows-app.png"

    pkill -f "FirefoxPasswordView.exe" 2>/dev/null || true
}

case "$target" in
    tui) shoot_tui ;;
    app) shoot_app ;;
    win) shoot_win ;;
    all) shoot_tui; shoot_app; shoot_win ;;
    *) echo "usage: screenshots.sh [all|tui|app|win]" >&2; exit 2 ;;
esac
