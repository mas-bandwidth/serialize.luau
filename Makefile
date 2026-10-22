# Makefile — serialize.luau (DESIGN.md, (i) THE RUNNER).
#
# Luau 0.741, pinned, the same pin as schema's Luau leg (schema
# docs/PORT-LUAU.md). To populate dist/ (gitignored), run `make dist-luau`:
#   url:    https://github.com/luau-lang/luau/releases/download/0.741/luau-ubuntu.zip
#   sha256: 134dc762ad26232af83e43f98dec03ff6030dd3a4452f9408b9d50ccea025503
#   unzip into dist/luau-0.741/ (luau, luau-analyze, luau-ast, luau-compile)
#
# make test          analyze src/*.luau, then run every test/*/*_test.luau
# make test T=<name> analyze, then run the files of test/<name>/ only
# make controls      the negative controls of tools/controls/controls.tsv: each
#                    deletes one refusal rule and must fail exactly its
#                    conformance-controls/<name>.expected vectors
#
# A later card adds its own targets in its own make/<card>.mk, included below,
# so no two cards edit this file.

LUAU_VERSION  := 0.741
LUAU_ZIP_URL  := https://github.com/luau-lang/luau/releases/download/$(LUAU_VERSION)/luau-ubuntu.zip
LUAU_ZIP_SHA  := 134dc762ad26232af83e43f98dec03ff6030dd3a4452f9408b9d50ccea025503
LUAU_DIST     := $(CURDIR)/dist/luau-$(LUAU_VERSION)
LUAU         ?= $(LUAU_DIST)/luau
LUAU_ANALYZE ?= $(LUAU_DIST)/luau-analyze
export LUAU LUAU_ANALYZE

GO ?= go
LUAURUN := build/luaurun

.PHONY: all dist-luau toolchain-luau analyze test controls clean
all: test

# dist-luau fetches the pinned release and REFUSES any archive whose sha256 is
# not the pin's: the archive is checked before it is unpacked, so a wrong
# download never reaches dist/.
dist-luau:
	@mkdir -p $(LUAU_DIST) build/dist-luau
	@curl -fsSL -o build/dist-luau/luau-ubuntu.zip $(LUAU_ZIP_URL)
	@got=$$(sha256sum build/dist-luau/luau-ubuntu.zip | cut -d' ' -f1); \
	if [ "$$got" != "$(LUAU_ZIP_SHA)" ]; then \
		echo "dist-luau REFUSES: luau-ubuntu.zip sha256 $$got is not the pin $(LUAU_ZIP_SHA)"; \
		rm -f build/dist-luau/luau-ubuntu.zip; exit 1; fi
	@unzip -o -q build/dist-luau/luau-ubuntu.zip -d $(LUAU_DIST)
	@chmod +x $(LUAU_DIST)/luau $(LUAU_DIST)/luau-analyze $(LUAU_DIST)/luau-ast $(LUAU_DIST)/luau-compile
	@echo "dist-luau: luau $(LUAU_VERSION) at $(LUAU_DIST) sha256 $(LUAU_ZIP_SHA)"

# toolchain-luau refuses, by name, a pin that does not resolve: $(LUAU) and
# $(LUAU_ANALYZE) must both be executables (a path, or a name on PATH).
toolchain-luau:
	@for pin in LUAU=$(LUAU) LUAU_ANALYZE=$(LUAU_ANALYZE); do \
		name=$${pin%%=*}; path=$${pin#*=}; \
		if ! command -v "$$path" >/dev/null 2>&1; then \
			echo "toolchain-luau REFUSES: $$name=$$path does not resolve; run make dist-luau (or set $$name)"; exit 1; fi; \
	done

$(LUAURUN): tools/luaurun/main.go tools/luaurun/go.mod
	@mkdir -p build
	cd tools/luaurun && $(GO) build -o ../../$(LUAURUN) .

# analyze runs luau-analyze over every src file (all are --!strict) and fails
# on any error it reports.
analyze: toolchain-luau
	@$(LUAU_ANALYZE) src/*.luau

# test: the analyzer first, then the runner over test/$(T)/ (or every test
# directory). A missing or empty test/<name>/ fails, naming it: never a skip.
test: analyze $(LUAURUN)
	@./$(LUAURUN) -root $(CURDIR) $(T)

# controls runs every negative control (STANDARD.md, "A gate nobody has seen go
# red"); a control that fails more or fewer vectors than its list is red.
controls: toolchain-luau $(LUAURUN)
	@./$(LUAURUN) -root $(CURDIR) -controls

clean:
	rm -rf build

-include make/*.mk
