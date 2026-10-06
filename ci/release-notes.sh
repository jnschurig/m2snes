#!/bin/sh
# ci/release-notes.sh <version> -- the release notes, on stdout
# (release Step 14; Feature 5), from dist/release-notes.md and the checkout:
#
#   {{version}}   <version>, the tag
#   {{retail}}    pins/cart.txt's retail SHA-1, which release-verify grades
#   {{debug}}     its debug SHA-1
#   {{commit}}    HEAD, 12 digits
#   {{history}}   the pins/history.md lines added since the previous v* tag
#                 reachable from HEAD; nothing when there is none (the first
#                 release)
#   {{verified}}  a placeholder for release-verify's summary line, added
#                 once it has graded the published release
#
# Needs the tags and full history (actions/checkout fetch-depth: 0).
set -eu

[ $# -eq 1 ] || { echo "usage: ci/release-notes.sh <version>" >&2; exit 2; }
version=$1
cd "$(dirname "$0")/.."

pin() {
	v=$(awk -v k="$1" '$1 == k { print $2 }' pins/cart.txt)
	[ -n "$v" ] || { echo "release-notes: no $1 pin in pins/cart.txt" >&2; exit 1; }
	echo "$v"
}
retail=$(pin retail)
debug=$(pin debug)
commit=$(git rev-parse --short=12 HEAD)

prev=$(git tag --merged HEAD --list 'v*' --sort=-v:refname | grep -vx "$version" | head -n 1 || true)
history=$(mktemp)
trap 'rm -f "$history"' EXIT
if [ -n "$prev" ]; then
	# history.md is append-only: its entries now, less those at the previous tag.
	git show "$prev:pins/history.md" | grep '^- ' >"$history.old" || true
	new=$(grep '^- ' pins/history.md | grep -vxF -f "$history.old" || true)
	rm -f "$history.old"
	if [ -n "$new" ]; then
		printf '## Pin changes since %s\n\nFrom `pins/history.md`: the date, each SHA-1 before and after, and why.\n\n%s\n' "$prev" "$new" >"$history"
	else
		printf 'The carts are the same as %s'"'"'s.\n' "$prev" >"$history"
	fi
fi

awk -v version="$version" -v retail="$retail" -v debug="$debug" -v commit="$commit" -v hist="$history" '
$0 == "{{history}}" {
	empty = 1
	while ((getline line < hist) > 0) { print line; empty = 0 }
	if (empty) skip_blank = 1
	next
}
$0 == "{{verified}}" { print "_`zig build release-verify` grades this release on the ROM after it is published; its summary line goes here._"; next }
skip_blank && $0 == "" { skip_blank = 0; next }
{
	skip_blank = 0
	gsub(/\{\{version\}\}/, version)
	gsub(/\{\{retail\}\}/, retail)
	gsub(/\{\{debug\}\}/, debug)
	gsub(/\{\{commit\}\}/, commit)
	print
}
' dist/release-notes.md
