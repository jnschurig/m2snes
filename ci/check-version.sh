#!/bin/sh
# ci/check-version.sh <tag> -- the tag is `v` + build.zig.zon's version
# (release Step 14; Feature 5). The release workflow runs it on a `v*` tag
# push and fails the release on a mismatch.
#
# ci/check-version.sh --print -- prints `v` + build.zig.zon's version, the
# name a dry run packages under.
set -eu

[ $# -eq 1 ] || { echo "usage: ci/check-version.sh <tag> | --print" >&2; exit 2; }
zon=$(dirname "$0")/../build.zig.zon
version=$(sed -n 's/^ *\.version = "\([^"]*\)",$/\1/p' "$zon")
[ -n "$version" ] || { echo "check-version: no .version in $zon" >&2; exit 2; }

if [ "$1" = --print ]; then
	echo "v$version"
	exit 0
fi
if [ "$1" != "v$version" ]; then
	echo "check-version: tag $1 is not v$version, build.zig.zon's version" >&2
	exit 1
fi
echo "check-version: ok: $1"
