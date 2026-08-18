#!/bin/sh
# Ends one wine prefix's session and kills every process left holding it.
#
# Usage: scripts/wine-shutdown.sh <prefix directory> [wine binary]
#
# `wineserver -k` kills the server alone. Measured on wine 11.15 under Rosetta
# 2: services.exe, explorer.exe, plugplay.exe, svchost.exe and two
# winedevice.exe keep running after it, each reparented to launchd. They stay
# until the Mac reboots, and a run of scripts/wine-check.sh leaves 8 of them.
#
# Their argv holds a Windows path such as `C:\windows\system32\services.exe`
# and names no prefix, so this script reads each candidate's cwd through lsof
# and kills the ones inside the prefix it was given. A wine program from
# another prefix keeps running.
set -u

prefix="${1:?usage: wine-shutdown.sh <prefix directory> [wine binary]}"
wine="${2:-/Applications/Wine Staging.app/Contents/Resources/wine/bin/wine}"

[ -d "$prefix" ] || exit 0

if [ -x "$wine" ]; then
    WINEPREFIX="$prefix" "$wine"server -k 2>/dev/null || true
fi

# /tmp is a symlink to /private/tmp, and lsof reports the resolved path.
resolved="$(cd "$prefix" 2>/dev/null && pwd -P)" || resolved="$prefix"

for pid in $(ps -eo pid,command | awk '$2 ~ /^C:/ { print $1 }'); do
    cwd="$(lsof -a -d cwd -Fn -p "$pid" 2>/dev/null | sed -n 's/^n//p' | head -1)"
    case "$cwd" in
        "$resolved"/*|"$resolved") kill -9 "$pid" 2>/dev/null || true ;;
    esac
done
