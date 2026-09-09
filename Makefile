# =============================================================
# Cordis Agent — SML implementation
# =============================================================
# Targets:
#   make               → build everything
#   make v3            → build single-process supervisor tree
#   make v3m           → build functor-typed services supervisor tree
#   make v4            → build cross-process supervisor tree
#   make test          → run all tests
#   make run-v3        → run v3 demo (Phase 1..9)
#   make run-v3m       → run v3-modular demo (Phase 0..9)
#   make run-v4        → run v4 demo (fork+exec+SIGTERM cascade)
#   make clean         → remove build artifacts
#   make help          → this help
#
# Requires: Poly/ML 5.7+ (both `poly` and `polyc` on PATH),
#           POSIX (Linux / macOS). Windows via WSL only.
# =============================================================

POLY      ?= poly
POLYC     ?= polyc
BIN       := bin
SRC       := src
TESTS     := tests
EXAMPLES  := examples

# `timeout` is GNU coreutils; macOS/BSD host it under `gtimeout` (coreutils)
# or not at all. Use it only when available so `make test-v4` stays portable.
TIMEOUT   := $(shell command -v timeout >/dev/null 2>&1 && echo timeout || \
             (command -v gtimeout >/dev/null 2>&1 && echo gtimeout))
TIMEOUT_W := $(if $(TIMEOUT),$(TIMEOUT) 30,)

# Poly/ML 5.7 in Ubuntu needs libpolyml.so symlink for polyc
LIBPOLY_SO := /usr/lib/x86_64-linux-gnu/libpolyml.so
LIBPOLY_TARGET := /usr/lib/x86_64-linux-gnu/libpolyml.so.9

# ---------- Default ----------
.PHONY: all
all: check-tools $(BIN)/cordis-v3 $(BIN)/cordis-v3m $(BIN)/cordis-v4
	@echo "==> build complete. Try:  make run-v3   or   make run-v3m   or   make run-v4"

# ---------- Preflight ----------
.PHONY: check-tools
check-tools:
	@command -v $(POLY)  >/dev/null 2>&1 || { \
	  echo "ERROR: poly not found (Ubuntu: sudo apt install polyml)"; exit 1; }
	@command -v $(POLYC) >/dev/null 2>&1 || { \
	  echo "ERROR: polyc not found (comes with polyml)"; exit 1; }
	@if [ ! -e $(LIBPOLY_SO) ] && [ -e $(LIBPOLY_TARGET) ]; then \
	  echo "==> creating $(LIBPOLY_SO) symlink (needs sudo)"; \
	  sudo ln -sf $(LIBPOLY_TARGET) $(LIBPOLY_SO); \
	fi

$(BIN):
	@mkdir -p $(BIN)

# ---------- v3: single-process supervisor tree ----------
.PHONY: v3
v3: $(BIN)/cordis-v3

$(BIN)/cordis-v3: $(SRC)/cordis-agent-v3.sml | $(BIN)
	@echo "==> v3 uses --use mode. Wrapper script written."
	@# The script feeds /dev/null to poly's stdin so it exits after
	@# the file finishes (otherwise --use drops into an interactive
	@# REPL that waits forever for input).
	@printf '#!/bin/sh\nexec $(POLY) --use %s "$$@" < /dev/null\n' \
	  "$$(pwd)/$(SRC)/cordis-agent-v3.sml" > $(BIN)/cordis-v3
	@chmod +x $(BIN)/cordis-v3

# ---------- v3m: functor-typed services (single-process) ----------
.PHONY: v3m
v3m: $(BIN)/cordis-v3m

$(BIN)/cordis-v3m: $(SRC)/cordis-agent-v3-modular.sml | $(BIN)
	@echo "==> v3-modular uses --use mode. Wrapper script written."
	@printf '#!/bin/sh\nexec $(POLY) --use %s "$$@" < /dev/null\n' \
	  "$$(pwd)/$(SRC)/cordis-agent-v3-modular.sml" > $(BIN)/cordis-v3m
	@chmod +x $(BIN)/cordis-v3m

# ---------- v4: cross-process supervisor tree ----------
.PHONY: v4
v4: $(BIN)/cordis-v4

$(BIN)/cordis-v4: $(SRC)/cordis-cross-process.sml | $(BIN)
	@echo "==> compiling v4 to native binary via polyc"
	@# NOTE: `poly --use` drops into REPL after loading the file and
	@# waits on stdin -- from make that stdin is the terminal, which
	@# looks like a hang. Redirect stdin from /dev/null so poly gets
	@# EOF immediately and exits after PolyML.export runs.
	@cd $(SRC) && $(POLY) --use cordis-cross-process.sml \
	  < /dev/null > /tmp/cordis-v4-build.log 2>&1 \
	  || { cat /tmp/cordis-v4-build.log; exit 1; }
	@$(POLYC) -o $@ $(SRC)/cordis-cross-process.o 2>/dev/null
	@rm -f $(SRC)/cordis-cross-process.o
	@echo "==> $@ ready"

# ---------- Run ----------
.PHONY: run-v3
run-v3: $(BIN)/cordis-v3
	@$(BIN)/cordis-v3

.PHONY: run-v3m
run-v3m: $(BIN)/cordis-v3m
	@$(BIN)/cordis-v3m

# v3 driven by a real LLM gateway (auth from ANTHROPIC_AUTH_TOKEN, endpoint
# from ANTHROPIC_BASE_URL — see section 6b in src/cordis-agent-v3.sml).
.PHONY: run-v3-llm
run-v3-llm: $(BIN)/cordis-v3
	@echo "==> run-v3 with real LLM (needs ANTHROPIC_AUTH_TOKEN + ANTHROPIC_BASE_URL set)"
	@CORDIS_LLM_REAL=1 $(BIN)/cordis-v3

# v3m driven by a real LLM gateway (same env contract as run-v3-llm; see
# section 10b / 13b in src/cordis-agent-v3-modular.sml).
.PHONY: run-v3m-llm
run-v3m-llm: $(BIN)/cordis-v3m
	@echo "==> run-v3m with real LLM (needs ANTHROPIC_AUTH_TOKEN + ANTHROPIC_BASE_URL set)"
	@CORDIS_LLM_REAL=1 $(BIN)/cordis-v3m

.PHONY: run-v4
run-v4: $(BIN)/cordis-v4
	@$(BIN)/cordis-v4

# ---------- Tests ----------
.PHONY: test
test: test-v3 test-v3m test-v4
	@echo ""
	@echo "==> all tests passed"

.PHONY: test-v3
test-v3: $(BIN)/cordis-v3
	@echo ""
	@echo "==> test-v3: single-process invariants"
	@$(BIN)/cordis-v3 > /tmp/cordis-v3.log 2>&1 || \
	  { echo "  FAIL: v3 crashed"; cat /tmp/cordis-v3.log; exit 1; }
	@sh $(TESTS)/test-v3.sh /tmp/cordis-v3.log

.PHONY: test-v3m
test-v3m: $(BIN)/cordis-v3m
	@echo ""
	@echo "==> test-v3m: functor-typed service invariants"
	@$(BIN)/cordis-v3m > /tmp/cordis-v3m.log 2>&1 || \
	  { echo "  FAIL: v3m crashed"; cat /tmp/cordis-v3m.log; exit 1; }
	@sh $(TESTS)/test-v3m.sh /tmp/cordis-v3m.log

.PHONY: test-v4
test-v4: $(BIN)/cordis-v4
	@echo ""
	@echo "==> test-v4: cross-process invariants"
	@$(TIMEOUT_W) $(BIN)/cordis-v4 > /tmp/cordis-v4.log 2>&1 || \
	  { echo "  FAIL: v4 crashed or timed out"; cat /tmp/cordis-v4.log; exit 1; }
	@sh $(TESTS)/test-v4.sh /tmp/cordis-v4.log

# ---------- Examples ----------
.PHONY: example-hung
example-hung: $(BIN)/cordis-v4
	@echo "==> example: SIGKILL fallback for hung workers"
	@sh $(EXAMPLES)/hung-worker.sh

# ---------- Housekeeping ----------
.PHONY: clean
clean:
	@rm -rf $(BIN)
	@rm -f $(SRC)/*.o
	@rm -f /tmp/cordis-v3.log /tmp/cordis-v3m.log /tmp/cordis-v4.log /tmp/cordis-v4-build.log
	@echo "==> cleaned"

.PHONY: help
help:
	@echo "Cordis Agent — build targets:"
	@echo "  make             build v3 wrapper + v3m wrapper + v4 native binary"
	@echo "  make v3          build v3 REPL wrapper only"
	@echo "  make v3m         build v3-modular (functor-typed) REPL wrapper only"
	@echo "  make v4          build v4 native binary only"
	@echo "  make run-v3      run v3 demo (scripted)"
	@echo "  make run-v3m     run v3-modular demo (scripted)"
	@echo "  make run-v3-llm  run v3 driven by a real LLM gateway (see README)"
	@echo "  make run-v3m-llm run v3-modular driven by a real LLM gateway (see README)"
	@echo "  make run-v4      run v4 demo"
	@echo "  make test        run all assertion-based tests"
	@echo "  make test-v3     v3 tests only"
	@echo "  make test-v3m    v3-modular tests only"
	@echo "  make test-v4     v4 tests only"
	@echo "  make example-hung  SIGKILL fallback demo"
	@echo "  make clean       remove artifacts"

