# make/roadmap.mk -- regenerate ROADMAP.md from docs/roadmap.sexp with the roadmap tool
# (ROADMAP_TOOL names the built binary).

ROADMAP_TOOL ?= roadmap

# roadmap-check refuses documentation, bench or test files that carry a private
# machine path, a bench host name, an internal sprint branch, an internal
# document name or an internal project name.
ROADMAP_CHECK_FILES := DESIGN.md ROADMAP.md docs/roadmap.sexp Makefile bench test
ROADMAP_CHECK_PATTERN := '/Volumes/|/Users/|/home/[A-Za-z0-9._-]+/|(^|[^A-Za-z0-9])amd-[0-9]+|sprint/|nova-|the[[:space:]]+studio|host[[:space:]]+space|AUDIT[-_ ]*LEDGER|PORT[-_ ]*LUAU|V[i]rtual[[:space:]]+Go|space[[:space:]]+[Gg]ame|[Ll][Ee][Gg][Oo]'

.PHONY: roadmap roadmap-check

# make test runs the check first.
test: roadmap-check

roadmap:
	$(ROADMAP_TOOL) --file docs/roadmap.sexp --out ROADMAP.md

roadmap-check:
	@bad=$$(grep -RInE $(ROADMAP_CHECK_PATTERN) $(ROADMAP_CHECK_FILES) || true); \
	if [ -n "$$bad" ]; then \
		echo "roadmap-check REFUSES: private or machine-specific references:"; \
		printf '%s\n' "$$bad"; \
		exit 1; \
	fi
	@echo "roadmap-check: documentation uses generic references"
