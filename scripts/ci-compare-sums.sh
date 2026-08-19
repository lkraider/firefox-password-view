#!/bin/sh
# Asserts that every build host produced the same exe for one target.
#
# Usage: scripts/ci-compare-sums.sh <target> <host>=<sum> <host>=<sum> ...
#
# ci.yml's compare-sums job runs this once per Windows target. Each build job
# publishes its sum as a job output, and that job needs all three, so the
# comparison reads one number per host for one source tree.
#
# An empty sum fails the run. It means a build job changed and stopped writing
# to GITHUB_OUTPUT, and comparing two empty strings would pass.
set -eu

target="${1:?usage: compare-sums.sh <target> <host>=<sum> ...}"
shift
[ "$#" -ge 2 ] || { echo "give at least two <host>=<sum> pairs" >&2; exit 2; }

first=""
first_host=""
status=0

for pair in "$@"; do
    host="${pair%%=*}"
    sum="${pair#*=}"
    if [ -z "$sum" ]; then
        echo "FAIL  $target: $host recorded no sum"
        status=1
        continue
    fi
    echo "  $host: $sum"
    if [ -z "$first" ]; then
        first="$sum"
        first_host="$host"
        continue
    fi
    if [ "$sum" != "$first" ]; then
        echo "FAIL  $target: $host and $first_host differ"
        status=1
    fi
done

if [ "$status" -ne 0 ]; then
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        echo "- \`$target\`: the hosts above disagree" >> "$GITHUB_STEP_SUMMARY"
    fi
    exit 1
fi

echo "PASS  $target: every host produced $first"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    echo "- \`$target\`: every host produced \`$first\`" >> "$GITHUB_STEP_SUMMARY"
fi
