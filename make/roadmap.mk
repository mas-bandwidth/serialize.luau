# make/roadmap.mk -- regenerate ROADMAP.md from docs/roadmap.sexp with the roadmap tool
# (ROADMAP_TOOL names the built binary).

ROADMAP_TOOL ?= roadmap

.PHONY: roadmap

roadmap:
	$(ROADMAP_TOOL) --file docs/roadmap.sexp --out ROADMAP.md
