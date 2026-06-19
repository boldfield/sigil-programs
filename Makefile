# sigil-programs — build/test each program against a Sigil toolchain.
#
# Requires `sigil` on PATH (override: make SIGIL=/path/to/bin/sigil).
# CI downloads the pinned Sigil release and runs `make test`.
#
# Add a new program by creating <name>/main.sigil and appending <name>
# to PROGRAMS below — it then gets `make <name>` and `make test-<name>`.

SIGIL ?= sigil
BIN   := bin

PROGRAMS := sjq

.PHONY: all test clean help $(PROGRAMS) $(PROGRAMS:%=test-%)

all: $(PROGRAMS)            ## Build every program

help:                      ## List available targets
	@grep -hE '^[a-zA-Z_%-]+:.*##' $(MAKEFILE_LIST) | sort | sed -E 's/:.*## / - /'

# make <program> — build <program>/main.sigil into bin/<program>
$(PROGRAMS):
	@mkdir -p $(BIN)
	$(SIGIL) $@/main.sigil -o $(BIN)/$@

# make test-<program> — compile + run every entry, then its oracle (if any)
$(PROGRAMS:%=test-%): test-%:
	@for f in $$(grep -rl 'fn main(' $*); do \
	  out="$(BIN)/$$(basename $$f .sigil)"; \
	  echo "  build+run $$f"; \
	  $(SIGIL) "$$f" -o "$$out"; \
	  "$$out" >/dev/null; \
	done
	@if [ -x $*/run-oracle.sh ]; then echo "  oracle $*"; ./$*/run-oracle.sh; fi

test: $(PROGRAMS:%=test-%) ## Build + run all entries and oracles for every program

clean:                     ## Remove build artifacts
	rm -rf $(BIN)
