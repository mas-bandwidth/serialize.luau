# make/fuzz.mk -- this card's targets; the design's Makefile includes make/*.mk.
#
# fuzz runs the differential fuzz tests: TestDifferentialAgainstSerializeGo
# generates 2000 random programs from a fixed seed, writes each with serialize.go
# v2.0.0 and the Luau port via fuzz/driver.luau, and compares write bytes,
# read-back traces (each ending with the end, every refusal with its reason) and
# mutated-read decisions. TestDifferentialNegativeControl sets the test-only
# widenRange flag and asserts the harness catches the planted one-bit-wider int
# range (the negative control must go red without it).

.PHONY: fuzz

fuzz:
	@cd fuzz && $(GO) test -count=1 -timeout 600s -run 'TestDifferential' -v .
