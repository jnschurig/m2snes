#!/bin/sh
# ci/package.sh <bin-dir> <version> <out-dir> -- the release archives
# (release Step 14; Feature 5).
#
# <bin-dir> holds one `m2snes-<target>/` directory per target, as CI's `build`
# job uploads them. Each target becomes <out-dir>/m2snes-<version>-<target>
# .tar.gz (.zip for Windows), holding a directory of the same name with the
# binary, LICENSE, THIRD-PARTY-NOTICES and dist/README.txt. Then
# <out-dir>/SHA256SUMS over the archives. Archives are not reproducible (tar
# and zip carry times); `release-verify` compares the binaries inside them.
set -eu

[ $# -eq 3 ] || { echo "usage: ci/package.sh <bin-dir> <version> <out-dir>" >&2; exit 2; }
bin=$1 version=$2 out=$3
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$out"
out=$(cd "$out" && pwd)
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

n=0
for dir in "$bin"/m2snes-*/; do
	[ -d "$dir" ] || continue
	target=${dir%/}
	target=${target##*/m2snes-}
	name=m2snes-$version-$target
	mkdir "$stage/$name"
	case $target in
	*windows*) exe=m2snes.exe ;;
	*) exe=m2snes ;;
	esac
	[ -f "$dir/$exe" ] || { echo "package: no $exe in $dir" >&2; exit 1; }
	cp "$dir/$exe" "$stage/$name/$exe"
	cp "$root/LICENSE" "$root/THIRD-PARTY-NOTICES" "$root/dist/README.txt" "$stage/$name/"
	chmod 755 "$stage/$name/$exe"
	chmod 644 "$stage/$name/LICENSE" "$stage/$name/THIRD-PARTY-NOTICES" "$stage/$name/README.txt"
	case $target in
	*windows*) (cd "$stage" && zip -qrX "$out/$name.zip" "$name") ;;
	*) (cd "$stage" && tar -czf "$out/$name.tar.gz" "$name") ;;
	esac
	n=$((n + 1))
done
[ $n -gt 0 ] || { echo "package: no m2snes-<target>/ directories in $bin" >&2; exit 1; }

cd "$out"
if command -v sha256sum >/dev/null 2>&1; then
	sha256sum m2snes-* >SHA256SUMS
else
	shasum -a 256 m2snes-* >SHA256SUMS
fi
echo "package: $n archives and SHA256SUMS in $out"
cat SHA256SUMS
