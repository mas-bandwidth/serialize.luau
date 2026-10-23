# make/nightly.mk -- this card's targets; the design's Makefile includes make/*.mk.
#
# test-luaurun runs the runner's own unit tests (tools/luaurun/main_test.go):
# the SERIALIZE_CORPUS_DIR override the nightly functional test uses to point
# the runner at mas-bandwidth/serialize main. No network, no real time.

.PHONY: test-luaurun

test-luaurun:
	@cd tools/luaurun && $(GO) test -count=1 .
