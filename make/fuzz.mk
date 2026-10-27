# make/fuzz.mk -- this card's targets; the design's Makefile includes make/*.mk.
#
# fuzz runs the differential fuzz tests: TestDifferentialAgainstSerializeGo
# generates 2000 random programs from a fixed seed, writes each with serialize.go
# v2.0.0 and the Luau port via fuzz/driver.luau, and compares write bytes,
# read-back traces (each ending with the end, every refusal with its reason) and
# mutated-read decisions. TestDifferentialNegativeControl sets the test-only
# widenRange flag and asserts the harness catches the planted one-bit-wider int
# range (the negative control must go red without it).
#
# fuzz-neg is the negative control of the whole differential: it runs
# TestDifferentialAgainstSerializeGo with -widen-int (the Go writer one bit wider
# on every ranged int) and is green only when that run goes red on a write
# mismatch, logs its reproduction command and writes the failing programs (the
# nightly run's upload). A differential that stays green under -widen-int is
# red here.
#
# fuzz-extended is the nightly run (.github/workflows/nightly-fuzz.yml): the
# same differential, generating batches until FUZZ_DURATION has passed, from
# FUZZ_SEED (required; the workflow draws a fresh one each run and logs it).
# Every disagreeing program is written to FUZZ_FAILURES as a driver input. The
# test logs the reproduction command:
#   cd fuzz && go test -count=1 -run TestDifferentialAgainstSerializeGo -v . -args -seed S -programs N

FUZZ_DURATION ?= 3600s
FUZZ_SEED     ?=
FUZZ_FAILURES ?= $(CURDIR)/build/fuzz-failures
FUZZ_NEG_LOG  := $(CURDIR)/build/fuzz-neg.log
FUZZ_NEG_DIR  := $(CURDIR)/build/fuzz-neg-failures

.PHONY: fuzz fuzz-neg fuzz-extended

fuzz:
	@cd fuzz && $(GO) test -count=1 -timeout 600s -run 'TestDifferential' -v .

fuzz-neg:
	@mkdir -p build && rm -rf $(FUZZ_NEG_DIR)
	@if (cd fuzz && $(GO) test -count=1 -timeout 600s -run 'TestDifferentialAgainstSerializeGo' -v . -args -widen-int -programs 200 -failures $(FUZZ_NEG_DIR)) >$(FUZZ_NEG_LOG) 2>&1; then \
		cat $(FUZZ_NEG_LOG); \
		echo "fuzz-neg REFUSES: the differential stayed green with -widen-int; the control must go red"; exit 1; fi
	@if ! grep -m 3 'write mismatch' $(FUZZ_NEG_LOG); then \
		cat $(FUZZ_NEG_LOG); \
		echo "fuzz-neg REFUSES: the differential went red with -widen-int but not on a write mismatch"; exit 1; fi
	@if ! grep -m 1 'reproduce: ' $(FUZZ_NEG_LOG); then \
		echo "fuzz-neg REFUSES: the red run logged no reproduction command"; exit 1; fi
	@if ! ls $(FUZZ_NEG_DIR)/*.in >/dev/null 2>&1; then \
		echo "fuzz-neg REFUSES: the red run wrote no failing program to $(FUZZ_NEG_DIR)"; exit 1; fi
	@echo "fuzz-neg: $$(ls $(FUZZ_NEG_DIR)/*.in | wc -l) failing programs written, e.g. $$(ls $(FUZZ_NEG_DIR)/*.in | head -1)"
	@echo "fuzz-neg: the differential goes red under -widen-int, as required"

fuzz-extended:
	@if [ -z "$(FUZZ_SEED)" ]; then echo "fuzz-extended REFUSES: FUZZ_SEED is empty; pass a seed so a failure reproduces"; exit 1; fi
	@cd fuzz && $(GO) test -count=1 -timeout 0 -run 'TestDifferentialAgainstSerializeGo' -v . -args -seed $(FUZZ_SEED) -duration $(FUZZ_DURATION) -failures $(FUZZ_FAILURES)
