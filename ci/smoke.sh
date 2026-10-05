#!/bin/sh
# ci/smoke.sh <m2snes binary> -- the release binary on a machine with no Zig,
# no mise and no checkout (release Step 8; CI's native smoke run, Feature 1).
#
# From a temp dir outside any checkout, with PATH cut to the system dirs:
# --version and --help exit 0 and say what they should; a 256 KiB file of
# zeros (no ROM byte in it) is refused by relative and by absolute path, with
# exit 1, and nothing is left beside it or in the working directory. POSIX sh,
# so Git Bash on Windows runs it.
set -eu

[ $# -eq 1 ] || { echo "usage: ci/smoke.sh <m2snes binary>" >&2; exit 2; }
case $1 in
/*) bin=$1 ;;
*) bin=$PWD/$1 ;;
esac
[ -f "$bin" ] || { echo "smoke: no binary at $bin" >&2; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
if command -v git >/dev/null 2>&1 && git -C "$tmp" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	echo "smoke: $tmp is inside a git checkout" >&2
	exit 1
fi
mkdir "$tmp/rom" "$tmp/work"
cd "$tmp/work"

sys_path=/usr/bin:/bin
if PATH=$sys_path command -v zig >/dev/null 2>&1; then
	echo "smoke: zig is on the cut-down PATH ($sys_path)" >&2
	exit 1
fi

fail=0
say() { printf '%-5s %s\n' "$1" "$2"; }

# run <name> <expected exit> <expected start of stdout, or a stderr needle> <args...>
run() {
	name=$1 want=$2 needle=$3
	shift 3
	set +e
	PATH=$sys_path "$bin" "$@" >"$tmp/out" 2>"$tmp/err"
	got=$?
	set -e
	if [ "$got" -ne "$want" ]; then
		say FAIL "$name: exit $got, not $want"
		cat "$tmp/out" "$tmp/err"
		fail=1
		return
	fi
	if [ "$want" -eq 0 ]; then
		case $(head -n 1 "$tmp/out") in
		"$needle"*) ;;
		*)
			say FAIL "$name: stdout does not start with \"$needle\""
			cat "$tmp/out"
			fail=1
			return
			;;
		esac
	elif ! grep -q "$needle" "$tmp/err"; then
		say FAIL "$name: the message does not say \"$needle\""
		cat "$tmp/err"
		fail=1
		return
	fi
	say ok "$name"
}

# left <dir> <expected listing>: what is in a dir after a refusal.
left() {
	have=$(ls -A "$1" | tr '\n' ' ')
	if [ "$have" != "$2" ]; then
		say FAIL "a refusal left \"$have\" in $1, not \"$2\""
		fail=1
	fi
}

run "--version" 0 "m2snes " --version
run "--help" 0 "usage: m2snes" --help

# Output appended to a log keeps the log: a positional stdout writer would
# write from offset 0 over it.
printf 'line one\nline two\n' >"$tmp/log"
PATH=$sys_path "$bin" --version >>"$tmp/log"
if [ "$(head -n 2 "$tmp/log" | tr '\n' ' ')" = "line one line two " ] && [ "$(wc -l <"$tmp/log")" -eq 3 ]; then
	say ok "--version >> log appends"
else
	say FAIL "--version >> log did not append:"
	cat "$tmp/log"
	fail=1
fi

dd if=/dev/zero of="$tmp/rom/in.gb" bs=1024 count=256 2>/dev/null
run "refusal, relative path" 1 "not a Game Boy ROM" ../rom/in.gb
left "$tmp/rom" "in.gb "
left "$tmp/work" ""
run "refusal, absolute path" 1 "not a Game Boy ROM" "$tmp/rom/in.gb"
left "$tmp/rom" "in.gb "
left "$tmp/work" ""

[ $fail -eq 0 ] && say ok "smoke: $bin"
exit $fail
