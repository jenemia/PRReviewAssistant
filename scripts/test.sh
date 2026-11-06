#!/bin/zsh
# Runs the whole test suite and fails unless at least one test actually ran.
# Extra arguments are passed to `swift test` (for example: --filter GitHubReleaseTests).
set -uo pipefail

cd "${0:A:h:h}"

# With Command Line Tools only, SwiftPM does not pass the Testing framework path to
# the test runner it generates. The runner's `canImport(Testing)` is then false, so it
# exits 0 without running anything. Package.swift settings do not reach that runner.
developer_dir="$(xcode-select -p)"
if [[ "$developer_dir" == */CommandLineTools ]]; then
    set -- -Xswiftc -F -Xswiftc "$developer_dir/Library/Developer/Frameworks" "$@"
fi

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

swift test "$@" 2>&1 | tee "$log"
test_status=$?
if [[ $test_status -ne 0 ]]; then
    exit "$test_status"
fi

executed="$(sed -nE 's/.*Test run with ([0-9]+) tests?.*/\1/p' "$log" | tail -n 1)"
if [[ -z "$executed" || "$executed" -eq 0 ]]; then
    echo "error: swift test exited 0 but ran no tests." >&2
    exit 1
fi
