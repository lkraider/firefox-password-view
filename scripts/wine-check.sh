#!/bin/sh
# Asserts the Windows app's behaviour under wine and exits non-zero on a
# failure. scripts/docs-screenshots.sh writes images. This script reads results.
#
# Every check launches zig-out/bin/FirefoxPasswordView.exe against a copy of
# core/testdata/sync-shaped, drives it with synthetic input, and reads the
# result off the macOS pasteboard with pbpaste. sync-shaped gives every row a
# different password, so pbpaste says which row acted.
#
# escape-hides and alt-mnemonic have no clipboard signal. Both compare two
# captures of the same window through scripts/wine-pixdiff.swift.
#
# Row order in the list, and the password each row holds:
#   0  https://example.com              fixture-pass-1
#   1  https://sub.example.org          fixture-pass-2
#   2  http://plain.example.net         fixture-pass-3
#   3  chrome://FirefoxAccounts         a JSON object, behind a confirmation
#   4  moz-extension://...              fixture-ext-pass
#
# The wine build on this Mac is x86_64 under Rosetta 2. It cannot load the
# aarch64-windows-gnu exe, so this script builds and runs the x86_64 one.
#
# Needs two TCC permissions for the terminal that runs this, both under
# System Settings > Privacy & Security:
#   Screen & System Audio Recording   for screencapture and the window list
#   Accessibility                     for the synthetic input
#
# CI runs no wine. This script is local.
#
# Usage:
#   scripts/wine-check.sh              every check
#   scripts/wine-check.sh copy-from-list escape-hides   the named checks
#   FFPW_SKIP_BUILD=1 scripts/wine-check.sh             reuse the existing exe
#   FFPW_KEEP=1 scripts/wine-check.sh                   keep the work dir
#   FFPW_WINE=/path/to/wine scripts/wine-check.sh
#
# A failing run keeps its work directory and names the path. It holds every
# capture the run took and the wine log.
set -eu

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/ffpw-winecheck.XXXXXX)"
win_exe="$repo_root/zig-out/bin/FirefoxPasswordView.exe"
wine="${FFPW_WINE:-/Applications/Wine Staging.app/Contents/Resources/wine/bin/wine}"

failures=0
skips=0

cleanup() {
    pkill -f "FirefoxPasswordView.exe" 2>/dev/null || true
    # wineboot starts 8 helper processes for the prefix below, and they outlive
    # both the exe and the prefix directory.
    "$repo_root/scripts/wine-shutdown.sh" "$work/wine" "$wine" 2>/dev/null || true
    if [ "$failures" -gt 0 ] || [ -n "${FFPW_KEEP:-}" ]; then
        echo "artifacts and wine.log stay in $work"
    else
        rm -rf "$work"
    fi
}
trap cleanup EXIT INT TERM

# --- preflight -------------------------------------------------------------

[ -x "$wine" ] || { echo "no wine at $wine. Set FFPW_WINE." >&2; exit 1; }

if ! screencapture -x "$work/probe.png" 2>/dev/null || [ ! -s "$work/probe.png" ]; then
    echo "screencapture produced nothing. Grant Screen & System Audio Recording to this terminal." >&2
    exit 1
fi
rm -f "$work/probe.png"

if ! osascript -e 'tell application "System Events" to count processes' >/dev/null 2>&1; then
    echo "System Events refused. Grant Accessibility to this terminal." >&2
    exit 1
fi

[ -n "${FFPW_SKIP_BUILD:-}" ] || (cd "$repo_root" && \
    ./zig/zig-aarch64-macos-0.16.0/zig build win \
    -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe -Doracle=false)
[ -x "$win_exe" ] || { echo "missing $win_exe" >&2; exit 1; }

swiftc -O -o "$work/window-list" "$repo_root/scripts/docs-window-list.swift"
swiftc -O -o "$work/input" "$repo_root/scripts/wine-input.swift"
swiftc -O -o "$work/pixdiff" "$repo_root/scripts/wine-pixdiff.swift"

# --- window helpers --------------------------------------------------------

window_id_for_pid() {
    "$work/window-list" | awk -F'\t' -v p="$1" '$2==p {print $1; exit}'
}

window_bounds_for_pid() {
    "$work/window-list" | awk -F'\t' -v p="$1" '$2==p {print $5, $6, $7, $8; exit}'
}

# --- wine prefix -----------------------------------------------------------
# One prefix serves every check. Each check launches and kills its own exe.

WINEPREFIX="$work/wine"
export WINEPREFIX
WINEDEBUG="${WINEDEBUG:--all}"
export WINEDEBUG
echo "bootstrapping the wine prefix"
"$wine"boot --init >/dev/null 2>&1

appdata="$WINEPREFIX/drive_c/users/$(id -un)/AppData/Roaming"
firefox_dir="$appdata/Mozilla/Firefox"
mkdir -p "$firefox_dir/Profiles"
cp -R "$repo_root/core/testdata/sync-shaped" \
      "$firefox_dir/Profiles/demo.default-release"

# write_profiles_ini <Name= value>
write_profiles_ini() {
    cat > "$firefox_dir/profiles.ini" <<INI
[Profile0]
Name=$1
IsRelative=1
Path=Profiles/demo.default-release

[InstallDEMO0000DEMO0000]
Default=Profiles/demo.default-release
Locked=1

[General]
StartWithLastProfile=1
Version=2
INI
}
write_profiles_ini "default-release"

# --- app lifecycle ---------------------------------------------------------

app_pid=""

# launch -> sets $app_pid, or returns 1 within 25 seconds when no window
# appears. Measured on this Mac: the window shows up 2 to 3 seconds in, so the
# poll runs at 0.2 seconds and every check starts as soon as it can.
launch() {
    "$wine" "$win_exe" >"$work/wine.log" 2>&1 &
    app_pid=""
    id=""
    i=0
    while [ $i -lt 125 ]; do
        sleep 0.2
        app_pid="$(pgrep -f 'FirefoxPasswordView.exe' | head -1)"
        [ -n "$app_pid" ] && id="$(window_id_for_pid "$app_pid")"
        [ -n "$id" ] && break
        i=$((i + 1))
    done
    [ -n "$id" ] || return 1

    osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $app_pid) to true" >/dev/null
    # The rows populate a frame or two after the window exists.
    sleep 1
    return 0
}

quit_app() {
    pkill -f "FirefoxPasswordView.exe" 2>/dev/null || true
    sleep 0.3
    app_pid=""
}

# key <keycode> [modifiers...]
# macinput already waits 60 ms after each of the two events it posts.
key() {
    "$work/input" key "$@"
    sleep 0.2
}

# type_text <string>
type_text() {
    osascript -e "tell application \"System Events\" to keystroke \"$1\"" >/dev/null
    sleep 0.4
}

# Where a list row sits, in screen points below the window's top edge. wine
# draws the Win32 client area inside a Cocoa window that wears a macOS title
# bar, so the window bounds start at that bar.
#
# Measured on this Mac from a capture of the 900x600 window at the default
# DPI: the macOS title bar, the app's menu bar, margin 8, the 24-point search
# box, margin 8 and the column header put row 0's text at 113 points, and the
# rows sit 14 points apart. A capture on a 2x display reports 226 and 28
# pixels for the same two numbers.
first_row_y=113
row_h=14

# point_for_row <row index, 0-based> -> "x y" inside that row's Site column
point_for_row() {
    set -- $(window_bounds_for_pid "$app_pid") "$1"
    echo "$(($1 + 120)) $(($2 + first_row_y + row_h * $5))"
}

# addColumns in win/src/main.zig gives the three columns 380, 250 and 200
# points, and layout() leaves an 8-point margin at the client's left edge.
password_column_x=638
password_column_w=200

# shoot <output name> -> captures the app window into $work/<name>.png
shoot() {
    id="$(window_id_for_pid "$app_pid")"
    screencapture -x -o -l "$id" -t png "$work/$1.png"
    [ -s "$work/$1.png" ] || { echo "capture of window $id produced nothing" >&2; exit 1; }
}

# cell_diff <a> <b> <row index> -> pixels that differ in that row's password
# cell. Two captures of an idle window differ in about 5000 of 2119392 pixels
# below the threshold pixdiff applies, so a whole-window hash reports a change
# that no user sees.
cell_diff() {
    set -- "$1" "$2" "$3" $(window_bounds_for_pid "$app_pid")
    "$work/pixdiff" "$work/$1.png" "$work/$2.png" "$6" \
        "$password_column_x" "$((first_row_y + row_h * $3 - 7))" \
        "$password_column_w" "$row_h"
}

# window_diff <a> <b> -> pixels that differ anywhere in the window
window_diff() {
    set -- "$1" "$2" $(window_bounds_for_pid "$app_pid")
    "$work/pixdiff" "$work/$1.png" "$work/$2.png" "$5" 0 0 "$5" "$6"
}

clear_pasteboard() {
    printf '' | pbcopy
}

# --- result reporting ------------------------------------------------------

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1: $2"; failures=$((failures + 1)); }
skip() { echo "SKIP  $1: $2"; skips=$((skips + 1)); }

# --- the checks ------------------------------------------------------------

# Runs first. It proves the wine-to-NSPasteboard bridge works, so a later
# pbpaste result means something. wine's Mac driver bridges the Win32
# clipboard to NSPasteboard in dlls/winemac.drv/clipboard.c. pbpaste reads
# plain text alone, so the four registered privacy formats never appear there.
check_copy_from_list() {
    name=copy-from-list
    clear_pasteboard
    launch || { fail "$name" "no window appeared"; return; }
    key 48          # Tab, from the search box to the list
    key 125         # Down, select row 0
    key 8 ctrl      # Ctrl+C
    sleep 0.5
    got="$(pbpaste)"
    quit_app
    case "$got" in
        fixture-pass-*) pass "$name" ;;
        *) fail "$name" "pbpaste holds '$got'. Rerun with WINEDEBUG=+clipboard and read the format negotiation." ;;
    esac
}

# A row is selected before the focus returns to the search box. Without that
# selection copySelected returns early and the clipboard stays empty, and the
# check then passes over a bug it was written to catch.
check_copy_from_search() {
    name=copy-from-search
    clear_pasteboard
    launch || { fail "$name" "no window appeared"; return; }
    key 48          # Tab, from the search box to the list
    key 125         # Down, select row 0
    key 3 ctrl      # Ctrl+F, back to the search box with its text selected
    type_text "example"
    # Home then Shift+End. The EDIT control's Ctrl+A select-all is a late
    # addition and wine's coverage of it is unverified.
    key 115
    key 119 shift
    key 8 ctrl
    sleep 0.5
    got="$(pbpaste)"
    quit_app
    case "$got" in
        example) pass "$name" ;;
        fixture-pass-*) fail "$name" "Ctrl+C in the search box copied a password: '$got'" ;;
        *) fail "$name" "pbpaste holds '$got'" ;;
    esac
}

check_copy_from_row_menu() {
    name=copy-from-row-menu
    clear_pasteboard
    launch || { fail "$name" "no window appeared"; return; }
    key 48
    key 125
    set -- $(point_for_row 0)
    "$work/input" rclick "$1" "$2"
    sleep 1
    # The popup draws under the cursor. Down twice reaches Copy password, and
    # Return picks it.
    key 125
    key 125
    key 36
    sleep 0.5
    got="$(pbpaste)"
    quit_app
    case "$got" in
        fixture-pass-*) pass "$name" ;;
        *) fail "$name" "pbpaste holds '$got'" ;;
    esac
}

# Decides one open item. showRowMenu acts on whatever selectedRow returns. A
# pass means comctl32 moved the selection on WM_RBUTTONDOWN. A failure means
# showRowMenu has to send LVM_SUBITEMHITTEST for the cursor point and select
# that row before it calls TrackPopupMenu.
#
# Row 2 carries fixture-pass-3. Row 3 is the Firefox Accounts row and raises a
# confirmation message box, so this check leaves it alone.
check_rclick_unselected() {
    name=rclick-unselected
    clear_pasteboard
    launch || { fail "$name" "no window appeared"; return; }
    key 48
    key 125         # row 0 is selected
    set -- $(point_for_row 2)
    "$work/input" rclick "$1" "$2"
    # TrackPopupMenu runs its own message loop. A Ctrl+C that arrives while it
    # is up reaches the popup, so this waits for the popup to close before it
    # sends one.
    sleep 1
    key 53          # Escape closes the popup
    sleep 1
    key 8 ctrl
    sleep 0.5
    got="$(pbpaste)"
    quit_app
    case "$got" in
        fixture-pass-3) pass "$name" ;;
        fixture-pass-1) fail "$name" "the right-click left row 0 selected. showRowMenu needs LVM_SUBITEMHITTEST." ;;
        *) fail "$name" "pbpaste holds '$got'" ;;
    esac
}

# IsDialogMessageW reads WS_TABSTOP on both children. Fix F put an Alt test
# ahead of that call, and this check covers the regression.
check_tab_moves_focus() {
    name=tab-moves-focus
    clear_pasteboard
    launch || { fail "$name" "no window appeared"; return; }
    key 48
    key 125
    key 8 ctrl
    sleep 0.5
    got="$(pbpaste)"
    quit_app
    case "$got" in
        fixture-pass-*) pass "$name" ;;
        *) fail "$name" "Tab never left the search box. pbpaste holds '$got'." ;;
    esac
}

# Escape is bound to IDM_EDIT_HIDE. This check reads pixels: it captures row
# 0's password cell masked, revealed and masked again.
check_escape_hides() {
    name=escape-hides
    launch || { fail "$name" "no window appeared"; return; }
    key 48
    key 125
    shoot masked
    key 36          # Return reveals the row
    sleep 0.5
    shoot revealed
    key 53          # Escape masks it again
    sleep 0.5
    shoot remasked

    revealed_diff="$(cell_diff masked revealed 0)"
    remasked_diff="$(cell_diff masked remasked 0)"
    quit_app

    if [ "$revealed_diff" -eq 0 ]; then
        fail "$name" "Return changed no pixel in the password cell, so the row never revealed"
    elif [ "$remasked_diff" -eq 0 ]; then
        pass "$name"
    else
        fail "$name" "$remasked_diff pixels of the password cell differ after Escape. Compare $work/masked.png and $work/remasked.png."
    fi
}

# core/src/profiles.zig caps neither the Name= value nor the resolved path.
# buildProfileMenu converts that name into a 512-unit buffer. Before fix B the
# conversion panicked and the window vanished with no message.
check_long_profile_name() {
    name=long-profile-name
    long="$(printf 'A%.0s' $(seq 1 600))"
    write_profiles_ini "$long"
    launch || { fail "$name" "no window appeared. Read $work/wine.log."; write_profiles_ini "default-release"; return; }
    sleep 5
    if pgrep -f 'FirefoxPasswordView.exe' >/dev/null 2>&1; then
        pass "$name"
    else
        fail "$name" "the process exited within 5 seconds. Read $work/wine.log."
    fi
    quit_app
    write_profiles_ini "default-release"
}

# One attempt. docs/DESIGN.md records that Option+P under wine typed a literal
# p, so the modifier never reached wine. A second failure reports SKIP with
# that reason. Fix F removed the code path that could have broken the
# mnemonics, so a SKIP costs nothing.
check_alt_mnemonic() {
    name=alt-mnemonic
    launch || { fail "$name" "no window appeared"; return; }
    shoot before-alt
    key 35 alt      # Option+P, the &Profile mnemonic
    sleep 0.5
    shoot after-alt

    # The search box tells the two outcomes apart. A character landing there
    # also empties the list, and that redraw covers the area the popup would
    # have covered. Measured on this Mac: 684 pixels of the search box and
    # 2596 of the popup area changed, and no popup drew.
    set -- $(window_bounds_for_pid "$app_pid")
    typed="$("$work/pixdiff" "$work/before-alt.png" "$work/after-alt.png" "$3" 8 54 800 24)"
    popup="$("$work/pixdiff" "$work/before-alt.png" "$work/after-alt.png" "$3" 60 88 200 70)"
    quit_app

    if [ "$typed" -gt 0 ]; then
        skip "$name" "Option+P typed a literal character into the search box. The modifier reaches wine as a character, so the mnemonics still need a Windows machine."
    elif [ "$popup" -gt 500 ]; then
        pass "$name"
    else
        skip "$name" "Option+P changed $popup pixels below the Profile menu item. No popup drew."
    fi
}

# --- run -------------------------------------------------------------------

all_checks="copy-from-list copy-from-search copy-from-row-menu rclick-unselected tab-moves-focus escape-hides long-profile-name alt-mnemonic"

run_check() {
    case "$1" in
        copy-from-list) check_copy_from_list ;;
        copy-from-search) check_copy_from_search ;;
        copy-from-row-menu) check_copy_from_row_menu ;;
        rclick-unselected) check_rclick_unselected ;;
        tab-moves-focus) check_tab_moves_focus ;;
        escape-hides) check_escape_hides ;;
        long-profile-name) check_long_profile_name ;;
        alt-mnemonic) check_alt_mnemonic ;;
        *) echo "unknown check $1" >&2; exit 2 ;;
    esac
}

if [ $# -eq 0 ]; then
    set -- $all_checks
fi
for c in "$@"; do
    run_check "$c"
done

echo
echo "$failures failed, $skips skipped"
[ "$failures" -eq 0 ]
