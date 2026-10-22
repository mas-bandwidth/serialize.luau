#!/bin/sh
# tools/revendor/revendor.sh <tag> -- re-vendor the standard and the corpus
# (DESIGN.md, "The vendored standard"): STANDARD.md, IMPLEMENTING.md,
# conformance/ and conformance-controls/ are copied VERBATIM from
# mas-bandwidth/serialize at <tag>, then diffed against the tag's own copy so a
# divergence is visible before it is committed. Remember to move the pin with
# it: SERIALIZE_TAG in ci.yml and DESIGN.md's pin text (make check-ci ties them).
set -eu

tag=${1:?usage: tools/revendor/revendor.sh <tag>}
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/revendor.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$tag" https://github.com/mas-bandwidth/serialize.git "$tmp/serialize"
rm -rf "$root/conformance" "$root/conformance-controls"
cp -R "$tmp/serialize/conformance" "$root/conformance"
cp -R "$tmp/serialize/conformance-controls" "$root/conformance-controls"
cp "$tmp/serialize/STANDARD.md" "$tmp/serialize/IMPLEMENTING.md" "$root/"

diff -ru "$tmp/serialize/conformance" "$root/conformance"
diff -ru "$tmp/serialize/conformance-controls" "$root/conformance-controls"
diff -u "$tmp/serialize/STANDARD.md" "$root/STANDARD.md"
diff -u "$tmp/serialize/IMPLEMENTING.md" "$root/IMPLEMENTING.md"
echo "revendor: STANDARD.md, IMPLEMENTING.md, conformance/ and conformance-controls/ are $tag's"
