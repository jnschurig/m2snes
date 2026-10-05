#!/bin/sh
# ci/dependabot-scope.sh < paths -- a Dependabot PR touches only .github/.
#
# Reads the PR's changed paths, one per line (both sides of a rename), and
# fails on any outside .github/. Such a PR may be merged in the web UI, past
# the hooks, only because action pins carry no ROM data. An empty list fails:
# it means the list could not be read, not that nothing changed.
set -eu

n=0
bad=0
while IFS= read -r path || [ -n "$path" ]; do
	[ -n "$path" ] || continue
	n=$((n + 1))
	case $path in
	.github/*) ;;
	*)
		echo "dependabot-scope: outside .github/: $path" >&2
		bad=1
		;;
	esac
done

if [ "$n" -eq 0 ]; then
	echo "dependabot-scope: no changed paths read" >&2
	exit 1
fi
[ "$bad" -eq 0 ] || exit 1
echo "dependabot-scope: ok, $n paths, all under .github/"
