# Makefile — the local gate for dotfiles-openSUSE.
# ──────────────────────────────────────────────────────────────────────────────
# Before this existed there was no way to validate the repo short of running
# ./bootstrap.sh for real against your own machine, and core.lock's own header told
# you to run `make core-lock` — a target that did not exist here. These targets
# mirror what CI actually runs, so local == CI.
#
# That header instruction was itself the bug: dotgibson/dotfiles-core#454 found no such
# target existed anywhere and removed the line, because core.lock is written by
# sync-core.sh in the same commit as the subtree pull and was never meant to have a
# second writer. `core-lock` here is now a redirect rather than a second generator of
# a format Core owns (dotgibson/dotfiles-core#593).
#
# Scope note: this repo owns bootstrap.sh, os/, install/, ssh/, wsl/ and .github/.
# core/ is vendored and is NEVER linted or edited here — it is gated upstream in
# dotfiles-core by `make audit`, and guarded here by `make core-verify`.

# A real executable path: make execs SHELL directly and does NOT word-split it, so
# `/usr/bin/env bash` would be looked up as a single filename and fail. openSUSE always
# ships /bin/bash.
SHELL       := /bin/bash
# A dotfiles-core CHECKOUT — core-verify delegates the vendored-tree comparison to Core's
# own scripts/core-integrity.sh there, the same script CI runs. Defaults to a sibling
# clone, the layout sync-core.sh assumes.
CORE_REPO ?= $(CURDIR)/../dotfiles-core

# Repo-owned shell only; core/ is excluded everywhere on purpose.
SH_FILES    := bootstrap.sh
ZSH_FILES   := $(wildcard os/*.zsh)
# Unlike the two above, this is `git ls-files` rather than a literal or a wildcard: it is
# the exact pathspec lint-call.yml's markdown leg uses, so `make lint-md` scans what the
# blocking gate scans. A wildcard would be one directory deep and miss anything under
# .github/, which is the scope defect found across the fleet (dotgibson/dotfiles-core#775).
MD_FILES    := $(shell git ls-files '*.md' ':!:core/**')

.DEFAULT_GOAL := help
.PHONY: help lint lint-sh lint-zsh lint-actions lint-md check core-verify check-core core-lock dry-run bootstrap-dry packages-check test capabilities

help: ## Show this help
	@echo "dotfiles-openSUSE — local targets:"
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk -F':.*?## ' '{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  Pre-push gate: make check"

lint: lint-sh lint-zsh lint-actions lint-md capabilities ## Run every linter (shellcheck + zsh -n + actionlint + markdownlint)

# `&&` before the ok, not `;`. With a semicolon the echo ran regardless and became the
# line's exit status, so shellcheck could print a screen of findings and this target still
# reported "ok" and exited 0 — a gate that cannot fail. lint-zsh (`|| exit 1`) and
# lint-actions (`&&`) were already correct; this arm was the only one that was not.
lint-sh: ## ShellCheck the repo-owned bash (uses ./.shellcheckrc)
	@if command -v shellcheck >/dev/null 2>&1; then \
	  echo ":: shellcheck $(SH_FILES)"; \
	  shellcheck -x $(SH_FILES) && echo "   ok"; \
	else \
	  echo "!! shellcheck not installed — skipping (zypper in ShellCheck)"; \
	fi
	@echo ":: bash -n $(SH_FILES)"; bash -n $(SH_FILES) && echo "   ok"

lint-zsh: ## Parse-check the zsh OS layer (ShellCheck has no zsh mode)
	@if command -v zsh >/dev/null 2>&1; then \
	  for f in $(ZSH_FILES); do echo ":: zsh -n $$f"; zsh -n "$$f" || exit 1; done; \
	  echo "   ok"; \
	else \
	  echo "!! zsh not installed — skipping"; \
	fi

lint-actions: ## actionlint the workflow callers
	@if command -v actionlint >/dev/null 2>&1; then \
	  echo ":: actionlint .github/workflows"; actionlint && echo "   ok"; \
	else \
	  echo "!! actionlint not installed — skipping (CI still enforces it)"; \
	fi

# Markdown had no local gate at all, while lint-call.yml's markdown leg has been BLOCKING
# since dotgibson/dotfiles-core#592 — a required check nobody could run before pushing, and
# a .markdownlint.jsonc only CI ever read. Skips like its siblings above; the message names
# CI as the remaining gate rather than implying coverage.
lint-md: ## markdownlint the repo-owned docs (ShellCheck and zsh -n never read markdown)
	@if command -v markdownlint-cli2 >/dev/null 2>&1; then \
	  echo ":: markdownlint-cli2 $(words $(MD_FILES)) file(s)"; \
	  markdownlint-cli2 $(MD_FILES) && echo "   ok"; \
	else \
	  echo "!! markdownlint-cli2 not installed — skipping (npm i -g markdownlint-cli2; CI still enforces it)"; \
	fi

core-verify: ## Verify vendored core/ matches the commit core.lock pins (mirrors CI's guard / integrity)
	@# THE TREE COMPARISON IS DELEGATED, and it has to be. This target used to answer it
	@# here: fetch core_sha treeless, then `git rev-parse HEAD:core` vs `$$sha^{tree}`. That
	@# was correct only while a vendored core/ was the WHOLE upstream tree. Since
	@# dotgibson/dotfiles-core#676 the fan-out materializes a FILTERED subset —
	@# `core.manifest` ∪ `core.vendor`, ~0.9 MB of Core instead of 5.6 MB of repo — so the
	@# two hashes can never agree again, and this printed `!! MISMATCH` on a pristine tree.
	@# Verified both ways at core v6.1.0: this said MISMATCH while Core's own
	@# scripts/core-integrity.sh said `pristine`, and CI (core-integrity-call.yml, which runs
	@# that script) was green throughout. A local gate that reds a clean tree is worse than
	@# no local gate: it teaches you to ignore it.
	@#
	@# So the expected tree is computed by the ONE implementation that knows how the fan-out
	@# builds it — Core's script, from a dotfiles-core CHECKOUT, which is also how CI invokes
	@# it. Rebuilding the filter here would be a second implementation to keep in step, which
	@# is the mistake `core-lock` below already explains at length.
	@#
	@# The three checks ABOVE the comparison stay local: they need no network and no Core
	@# checkout, and each catches a different botch (a missing lock, a sync that moved core/
	@# without core.version, a hand-edit sitting uncommitted).
	@set -euo pipefail; \
	test -r core.lock || { echo "!! core.lock missing"; exit 1; }; \
	ver="$$(sed -n 's/^core_version=//p' core.lock)"; \
	sha="$$(sed -n 's/^core_sha=//p' core.lock)"; \
	test -n "$$sha" || { echo "!! core.lock records no core_sha"; exit 1; }; \
	echo ":: core.lock pins $$ver ($${sha:0:12})"; \
	vfile="$$(cat core/core.version 2>/dev/null || echo '')"; \
	if [ "$$vfile" != "$$ver" ]; then \
	  echo "!! core/core.version ($$vfile) != core.lock core_version ($$ver) — botched sync"; exit 1; \
	fi; \
	echo "   core/core.version agrees"; \
	if ! git diff --quiet HEAD -- core/; then \
	  echo "!! core/ has uncommitted local modifications — it is vendored and must not be hand-edited"; \
	  git diff --stat HEAD -- core/; exit 1; \
	fi; \
	echo "   core/ has no local edits"; \
	if [ -x "$(CORE_REPO)/scripts/core-integrity.sh" ]; then \
	  "$(CORE_REPO)/scripts/core-integrity.sh" --self "$(CURDIR)"; \
	else \
	  echo "-- no dotfiles-core checkout at CORE_REPO=$(CORE_REPO) — the tree comparison is SKIPPED"; \
	  echo "   (clone it beside this repo, or: make core-verify CORE_REPO=/path/to/dotfiles-core)"; \
	  echo "   CI still runs it on every PR: .github/workflows/core-integrity.yml"; \
	fi

# This repo's historical spelling for the target above, kept so anything already calling
# it — muscle memory, a local script, the docs' older lines — keeps working. See the
# vocabulary note at `check`.
check-core: core-verify ## (alias) the pre-#691 spelling of core-verify

core-lock: ## Explain why core.lock is NOT regenerated here (it is written by Core's fan-out)
	@echo "core.lock is not regenerated in this repo."
	@echo
	@echo "Its format is owned by scripts/sync-core.sh in dotfiles-core, which stamps it in"
	@echo "the SAME commit as the subtree pull. A second generator here cannot be kept in"
	@echo "step with it (dotgibson/dotfiles-core#593), and this one had a sharper problem:"
	@echo
	@echo "  it resolved core_sha from the TAG matching core/core.version, via ls-remote —"
	@echo "  not from the commit actually vendored in core/. Any tree not sitting exactly on"
	@echo "  a release (an ad-hoc sync, a hand pull, a between-releases fan-out) would get a"
	@echo "  lock naming a commit its own core/ does not contain, which is precisely the"
	@echo "  disagreement 'make check-core' exists to detect."
	@echo
	@echo "It also wrote core_branch=<sha>, duplicating core_sha — the defect Core fixed in"
	@echo "#453 by renaming the field to core_ref, which this never knew about."
	@echo
	@echo "If core/ and core.lock disagree, re-run the fan-out from a dotfiles-core"
	@echo "checkout rather than patching the lock here:"
	@echo
	@echo "    make sync          # in dotfiles-core"
	@echo
	@echo "Then verify this repo with:  make check-core"


# ── the canonical fleet verbs (dotgibson/dotfiles-core#691) ───────────────────
# `check`, `dry-run`, `packages-check` and `core-verify` are four of the seven names every
# repo that vendors Core must answer to (Core's scripts/make-vocabulary.txt; `make
# fleet-vocabulary` there renders the register that checks it). Before that list, "dry run"
# was spelled two ways across nine repos and "verify core" five — only `help` was common to
# every Makefile, so a contributor re-learned the verbs in each repo and no gate noticed.
# The requirement is that the CANONICAL name exists, not that a historical one dies.

dry-run: ## Preview a FULL bootstrap (packages + symlinks); mutates nothing
	@./bootstrap.sh --dry-run

# The old spelling previewed the SYMLINKS only (`--links-only --dry-run`). It now runs the
# full preview, which is a strict superset: `--dry-run` alone skips provisioning with a
# "(dry run) would provision …" line and still plans every link, and neither form writes
# anything or needs root.
bootstrap-dry: dry-run ## (alias) the pre-#691 spelling of dry-run

check: lint core-verify ## The pre-push gate: lint + core integrity + a hermetic --links-only run
	@# What `make test` used to be, plus the third leg the fleet's `check` promises. `lint`
	@# proves the repo-owned shell parses and `core-verify` proves the vendored subtree is
	@# the one core.lock pins; this proves the installer still wires the symlink graph Core's
	@# loader expects — into a throwaway HOME, so it is safe on a live box.
	@#
	@# openSUSE ONLY: bootstrap.sh reads /etc/os-release and refuses anywhere else, by
	@# design. Off openSUSE this fails with that message rather than reporting a green it did
	@# not earn; the container equivalent runs from .github/workflows/bootstrap.yml.
	@#
	@# tpm is pre-created because blib_link_core clones the tmux plugin manager into it on a
	@# first run; this asserts symlinks, not network.
	@tmp=$$(mktemp -d); \
	mkdir -p "$$tmp/.config/tmux/plugins/tpm"; \
	echo ":: bootstrap --links-only into $$tmp"; \
	HOME="$$tmp" ./bootstrap.sh --links-only >/dev/null || { echo "!! bootstrap failed"; rm -rf "$$tmp"; exit 1; }; \
	rc=0; \
	for l in .config/zsh/loader.zsh .config/zsh/80-os.zsh .config/starship.toml \
	         .config/lazygit/config.yml .config/nvim .vimrc .gitconfig; do \
	  test -L "$$tmp/$$l" || { echo "!! MISSING symlink: $$l"; rc=1; }; \
	done; \
	test -e "$$tmp/.config/zsh/loader.zsh" || { echo "!! loader.zsh is dangling"; rc=1; }; \
	test -f "$$tmp/.config/sesh/sesh.toml" || { echo "!! sesh.toml not seeded"; rc=1; }; \
	test -L "$$tmp/.config/sesh/sesh.toml" && { echo "!! sesh.toml must be a copy, not a link"; rc=1; }; \
	grep -q "dotfiles-managed v4" "$$tmp/.zshrc" || { echo "!! ~/.zshrc not managed"; rc=1; }; \
	grep -q "source .*loader.zsh" "$$tmp/.zshrc" || { echo "!! ~/.zshrc does not source the loader"; rc=1; }; \
	rm -rf "$$tmp"; \
	test $$rc -eq 0 || exit 1; \
	echo "   symlink graph OK"
	@echo
	@echo ":: all local checks passed"

# `test` is the fleet's name for THE REPO'S OWN SUITE — a test/ directory CI runs — and
# this repo does not have one yet. Until it does, this stays an alias of the pre-push
# gate so nothing typing `make test` breaks; Core's register reports it as a no-op beside
# a `no-dir` floor, which is the accurate signal and the reason the suite is owed. That is
# the test-floor half of dotgibson/dotfiles-core#691.
test: check ## (alias) the pre-push gate, until this repo owns a test/ suite

packages-check: ## Do all install/packages.txt names still resolve against zypper?
	@# The local half of what bootstrap.yml's packages_check leg asks in a Tumbleweed
	@# container, with the same command and the same --allow-downgrade, for the reason that
	@# workflow records: gcc, gcc-c++ and cargo reach glibc-devel, which pins an exact glibc
	@# and only resolves by downgrading the installed one — without the flag those three
	@# report UNRESOLVED on a container whose glibc has skewed, which is a false accusation
	@# rather than a rename. NOT --force-resolution: that lets the solver answer "do not
	@# install gcc", i.e. a false green.
	@command -v zypper >/dev/null 2>&1 || { echo "!! zypper not found — run this on openSUSE (CI covers it: .github/workflows/bootstrap.yml)"; exit 1; }
	@test "$$(id -u)" = 0 || { echo "!! needs root — zypper resolves against the system database and requires it even for --dry-run"; echo "   try: sudo make packages-check"; exit 1; }
	@set -e; \
	pkgs=$$(sed 's/#.*//' install/packages.txt | tr -d '[:blank:]' | grep -v '^$$'); \
	test -n "$$pkgs" || { echo "!! no packages parsed from install/packages.txt"; exit 1; }; \
	echo ":: resolving $$(echo "$$pkgs" | wc -l) package names (nothing is downloaded or installed)"; \
	rc=0; \
	for p in $$pkgs; do \
	  zypper --non-interactive install --dry-run --allow-downgrade "$$p" >/dev/null 2>&1 || { echo "   UNRESOLVED: $$p"; rc=1; }; \
	done; \
	test $$rc -eq 0 && echo ":: all package names resolve" || \
	  echo "^^ renamed or dropped upstream — fix install/packages.txt, or add a presence-guarded fallback in bootstrap.sh"; \
	exit $$rc

# ── the OS capability declaration (Core v5, #663/#667) ────────────────────────
# ONE definition of the schema gates all seven declaring repos: the validator is
# core/scripts/check-capabilities.sh, vendored with Core, so a schema change arrives
# with the next sync instead of needing seven hand-written greps to be updated in
# step. Core's own `make audit` runs the same script over its shipped example and
# sweeps the fleet for these files; this is the local half of that gate.
#
# The glob is guarded because an unmatched glob stays LITERAL in sh — without the
# test this would "validate" a file named `os/*.capabilities` and pass on nothing,
# which is the failure mode a gate must never have.
capabilities: ## Validate os/*.capabilities against Core's schema
	@rc=0; found=0; \
	for f in os/*.capabilities; do \
	  [ -e "$$f" ] || continue; found=1; \
	  core/scripts/check-capabilities.sh "$$f" --packages install/packages.txt || rc=1; \
	done; \
	if [ "$$found" -eq 0 ]; then echo "!! no os/*.capabilities — this repo must declare one (see core/examples/os.capabilities.example)"; rc=1; fi; \
	exit $$rc

