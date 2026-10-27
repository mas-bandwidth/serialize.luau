#!/bin/sh
# tools/checkci/check-ci.sh -- TEST TestCheckCI (DESIGN.md, (i) THE RUNNER and
# "The vendored standard").
#
# Reads .github/workflows/ci.yml and DESIGN.md only; no network. It fails,
# naming the line, when ci.yml spells an interpreter URL or sha256 (the pin
# lives once, in the Makefile), when the workflow does not run `make dist-luau`,
# `make test` and `make controls`, when a job lacks the fork guard, or when its corpus pin
# differs from DESIGN.md's pin. Its controls are scratch copies of ci.yml, one
# with a pasted sha256 and one without the fork guard: each must fail its scan,
# or this test fails.
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

# guard_gap FILE prints a line when FILE's jobs and fork guards differ in
# count. The repository is PUBLIC and its runners are the fleet's, so every job
# carries the same-repository `if:` and a fork's pull request never reaches them.
guard_gap() {
	jobs=$(grep -cE '^[[:space:]]*runs-on:' "$1" || true)
	guards=$(grep -cE "^[[:space:]]*if:[[:space:]]*github\.event_name != 'pull_request' \|\| github\.event\.pull_request\.head\.repo\.full_name == github\.repository[[:space:]]*$" "$1" || true)
	if [ "$jobs" -ne "$guards" ]; then
		printf '%s:1: %s job(s) but %s fork guard(s); every job needs the same-repository if:\n' "$1" "$jobs" "$guards"
	fi
}

# a_ref LINE extracts the corpus pin from a FILE:LINE record: the first vX.Y.Z
# tag or 40-digit commit sha after the line-number prefix, or empty.
a_ref() {
	printf '%s\n' "$1" | sed 's/^[0-9]*://' | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+|[0-9a-f]{40}' | head -1
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

	gap=$(guard_gap "$ci")
	[ -n "$gap" ] && fail "$gap"

	for target in dist-luau test controls; do
		runs_make "$target" || fail "$ci: ci.yml does not run 'make $target'"
	done

	ci_line=$(grep -nE '^[[:space:]]*SERIALIZE_REF:' "$ci" | head -1)
	ci_ref=$(a_ref "$ci_line")
	design_line=$(grep -nE 'VERBATIM from mas-bandwidth/serialize at (tag|commit)' "$design" | head -1)
	design_ref=$(a_ref "$design_line")
	case "$ci_ref" in
	'')
		fail "$ci: ci.yml does not name a SERIALIZE_REF corpus pin" ;;
	*)
		if [ "$ci_ref" != "$design_ref" ]; then
			fail "$ci:$ci_line: corpus pin $ci_ref differs from DESIGN.md:$design_line corpus pin ${design_ref:-none}"
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
		grep -v 'head.repo.full_name == github.repository' "$ci" >"$ctl/ci-fork.yml"
		fork_out=$(guard_gap "$ctl/ci-fork.yml")
		if [ -n "$fork_out" ]; then
			printf 'control: the scratch ci.yml without the fork guard fails as required:\n%s\n' "$fork_out"
		else
			fail "control: a scratch ci.yml without the fork guard passed the guard scan; it must fail"
		fi
		rm -r "$ctl"
	fi
fi

if [ "$bad" -ne 0 ]; then
	printf -- '--- FAIL TestCheckCI\n'
	exit 1
fi
printf -- '--- PASS TestCheckCI\n'
