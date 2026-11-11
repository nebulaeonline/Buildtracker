#!/bin/sh
# POSIX sh; accepts a published executable path, including paths with spaces.
set -eu

fail() { printf '%s\n' "$*" >&2; exit 1; }
[ "$#" -eq 1 ] || fail "Usage: sh tests/smoke.sh <path-to-bt>"
executable=$(cd -P "$(dirname "$1")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$1")")
[ -x "$executable" ] || fail "Executable not found or not executable: $executable"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/bt-tests-XXXXXXXX")
trap 'rm -rf "$test_root"' 0
trap 'exit 1' HUP INT TERM

check() {
    expected=$1
    shift
    actual=$("$executable" --root "$test_root" "$@") || fail "Command failed: $*"
    [ "$actual" = "$expected" ] || fail "Expected '$expected', got '$actual': $*"
}
reject() {
    status=0
    actual=$("$executable" --root "$test_root" "$@" 2>"$test_root/error") || status=$?
    [ "$status" -eq 1 ] && [ -z "$actual" ] && [ -s "$test_root/error" ] ||
        fail "Expected exit 1, empty stdout, and an error on stderr: $*"
}

reject --noinc
reject --reset
help_text=$("$executable" --root "$test_root" --help)
for option in --init --reset --noinc --nolocktimeout --tag --root --help; do
    case "$help_text" in *"$option"*) ;; *) fail "Help missing $option" ;; esac
done
[ ! -e "$test_root/.buildtracker" ] || fail 'Read/help created storage'
check 0 --init
check 1
check 1 --noinc
check 1 --noinc --nolocktimeout
reject --nolocktimeout --nolocktimeout
reject --nolockout
check 50 --reset 50
check 50 --noinc
check 51
check 0 --reset
check 1
check 100 --tag api --init 100
check 101 --tag api
check 200 --tag api --reset 200
check 200 --tag api --noinc
check 201 --tag api
check 0 --reset --tag api
check 1 --tag api
reject --tag missing --reset 10
reject --reset -1
reject --reset 9223372036854775808
reject --reset --noinc
reject --reset --init
reject --reset --reset
check 1 --noinc
reject --tag API --noinc
check 0 --tag "spaces and 'quotes'" --init
check 1 --tag "spaces and 'quotes'"
reject --init -1
reject --init 1 --noinc
reject --tag
reject --unknown
check 9223372036854775807 --tag max --init 9223372036854775807
reject --tag max
check 9223372036854775807 --tag max --noinc
check 0 --init

# Wait for every process before allowing the cleanup trap to remove its files.
pids=''
failed=0
i=1
while [ "$i" -le 24 ]; do
    "$executable" --root "$test_root" >"$test_root/out-$i" 2>"$test_root/err-$i" &
    pids="$pids $!"
    i=$((i + 1))
done
for pid in $pids; do
    wait "$pid" || failed=1
done
if [ "$failed" -ne 0 ]; then
    cat "$test_root"/err-* >&2
    fail 'Concurrent increment failed'
fi
i=1
while [ "$i" -le 24 ]; do
    printf '%s\n' "$i"
    i=$((i + 1))
done >"$test_root/expected"
LC_ALL=C sort -n "$test_root"/out-* >"$test_root/actual"
cmp -s "$test_root/expected" "$test_root/actual" || fail 'Concurrent increments were not unique and consecutive'
check 24 --noinc
mkdir "$test_root/component"
(
    cd "$test_root/component"
    actual=$("$executable" --root .. --noinc)
    [ "$actual" = 24 ] || fail 'Relative root failed'
    actual=$("$executable" --init 5)
    [ "$actual" = 5 ] || fail 'Default root failed'
)
check 24 --noinc
printf '%s\n' 'All integration checks passed.'
