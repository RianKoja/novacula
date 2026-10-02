HISTORY ?= data/history.csv
CHART   ?= docs/history.svg
METRIC  ?= size
TARGETS ?= targets.txt
DATE    ?= $(shell date -I)
# The release version in lakefile.toml, which release-please bumps on every release.
REV     ?= v$(shell sed -n 's/^version = "\(.*\)"/\1/p' lakefile.toml)

.PHONY: help build fixtures test score track chart history clean

help:
	@echo "make build      build the library and the novacula exe"
	@echo "make test       run the toy selftest"
	@echo "make score MODULE=Fixtures DECL=Fixtures.branchy"
	@echo "make track      append today's metrics for $(TARGETS) to $(HISTORY)"
	@echo "make chart      redraw $(CHART) from $(HISTORY)"
	@echo "make history    show the last rows of $(HISTORY)"
	@echo "make clean      drop build outputs (keeps $(HISTORY))"

build:
	lake build

fixtures:
	lake build Fixtures

test: build fixtures
	lake exe novacula selftest

score: build
	@test -n "$(MODULE)" -a -n "$(DECL)" || { echo "usage: make score MODULE=<Module> DECL=<Decl>"; exit 2; }
	@lake exe novacula score $(MODULE) $(DECL)

# One row per tracked declaration per run. The date and revision are passed in, never read
# from a clock inside the tool, so rerunning an old revision reproduces its rows exactly.
# Re-running on the same date and revision is a no-op, so a daily cron can retry safely.
# FORCE=1 appends anyway.
track: build fixtures
	@mkdir -p $(dir $(HISTORY))
	@test -s $(HISTORY) || lake exe novacula csv-header > $(HISTORY)
	@if [ -z "$(FORCE)" ] && grep -q "^$(DATE),$(REV)," $(HISTORY); then \
	   echo "$(DATE) $(REV) already tracked, nothing to do (FORCE=1 to append anyway)"; exit 0; fi; \
	 before=$$(wc -l < $(HISTORY)); \
	 lake exe novacula csv $(DATE) $(REV) $(TARGETS) >> $(HISTORY); \
	 echo "appended $$(( $$(wc -l < $(HISTORY)) - before )) rows for $(DATE) to $(HISTORY)"
	@$(MAKE) --no-print-directory chart

chart: build
	@mkdir -p $(dir $(CHART))
	@lake exe novacula chart $(HISTORY) $(CHART) $(METRIC)

history:
	@tail -n 15 $(HISTORY)

clean:
	lake clean
