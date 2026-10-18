#!/bin/sh
# tools/checkci/check-ci.sh -- TEST TestCheckCI (DESIGN.md, (i) THE RUNNER and
# "The vendored standard").
#
# Reads .github/workflows/ci.yml and DESIGN.md only; no network. It fails,
# naming the line, when ci.yml spells an interpreter URL or sha256 (the pin
# lives once, in the Makefile), when the workflow does not run `make dist-luau`
# and `make test`, or when its corpus tag differs from DESIGN.md's pin. Its own
# control is a scratch copy of ci.yml with a pasted sha256: that copy must fail
# the pin scan, or this test fails.
set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
ci="$root/.github/workflows/ci.yml"
design="$root/DESIGN.md"
tmpbase=${TMPDIR:-${RUNNER_TEMP:-/tmp}}

bad=0
fail() {
	printf '%s\n' "$*"
	bad=1
}

# scan_pin FILE prints every non-comment line that spells the interpreter pin
# (its URL, its archive name, or any 64-digit hex sha256), prefixed FILE:LINE.
scan_pin() {
	f=$1
	grep -nE 'luau-lang/luau|luau-ubuntu\.zip|[0-9A-Fa-f]{64}' "$f" |
		grep -vE '^[0-9]+:[[:space:]]*#' |
		sed "s|^|$f:|"
}

# runs_make NAME is true when a non-comment ci.yml line invokes `make NAME`.
runs_make() {
	grep -nE "make[[:space:]]+$1([[:space:]]|$)" "$ci" |
		grep -vE '^[0-9]+:[[:space:]]*#' >/dev/null
}

# a_tag LINE extracts the first vX.Y.Z from a FILE:LINE record, or empty.
a_tag() {
	printf '%s\n' "$1" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

printf 'RUN TestCheckCI\n'

if [ ! -f "$ci" ]; then
	fail "$ci: ci.yml is missing"
else
	while IFS= read -r spelled; do
		[ -n "$spelled" ] && fail "$spelled: the interpreter pin is spelled in ci.yml; it belongs only in the Makefile"
	done <<EOF
$(scan_pin "$ci")
EOF

	for target in dist-luau test; do
		runs_make "$target" || fail "$ci: ci.yml does not run 'make $target'"
	done

	ci_line=$(grep -nE '^[[:space:]]*SERIALIZE_TAG:' "$ci" | head -1)
	ci_tag=$(a_tag "$ci_line")
	design_line=$(grep -nE 'VERBATIM from mas-bandwidth/serialize at tag' "$design" | head -1)
	design_tag=$(a_tag "$design_line")
	case "$ci_tag" in
	'')
		fail "$ci: ci.yml does not name a SERIALIZE_TAG corpus pin" ;;
	*)
		if [ "$ci_tag" != "$design_tag" ]; then
			fail "$ci:$ci_line: corpus tag $ci_tag differs from DESIGN.md:$design_line corpus pin ${design_tag:-none}"
		fi ;;
	esac

	# The control: the same scan over a scratch copy that pastes a sha256 must
	# fail. A scan that cannot catch that copy proves nothing about ci.yml.
	ctl=$(mktemp -d "$tmpbase/checkci.XXXXXX") || fail "control: cannot make a scratch directory under $tmpbase"
	if [ -n "${ctl:-}" ]; then
		cp "$ci" "$ctl/ci.yml"
		printf '      - run: echo 134dc762ad26232af83e43f98dec03ff6030dd3a4452f9408b9d50ccea025503\n' >>"$ctl/ci.yml"
		ctl_out=$(scan_pin "$ctl/ci.yml")
		if [ -n "$ctl_out" ]; then
			printf 'control: the scratch ci.yml fails as required:\n%s\n' "$ctl_out"
		else
			fail "control: a scratch ci.yml with a pasted sha256 passed the pin scan; it must fail"
		fi
		rm -r "$ctl"
	fi
fi

if [ "$bad" -ne 0 ]; then
	printf -- '--- FAIL TestCheckCI\n'
	exit 1
fi
printf -- '--- PASS TestCheckCI\n'
