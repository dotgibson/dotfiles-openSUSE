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
# dotfiles-core by `make audit`, and guarded here by `make check-core`.

# A real executable path: make execs SHELL directly and does NOT word-split it, so
# `/usr/bin/env bash` would be looked up as a single filename and fail. openSUSE always
# ships /bin/bash.
SHELL       := /bin/bash
CORE_REMOTE ?= https://github.com/dotgibson/dotfiles-core.git

# Repo-owned shell only; core/ is excluded everywhere on purpose.
SH_FILES    := bootstrap.sh
ZSH_FILES   := $(wildcard os/*.zsh)
# Unlike the two above, this is `git ls-files` rather than a literal or a wildcard: it is
# the exact pathspec lint-call.yml's markdown leg uses, so `make lint-md` scans what the
# blocking gate scans. A wildcard would be one directory deep and miss anything under
# .github/, which is the scope defect found across the fleet (dotgibson/dotfiles-core#775).
MD_FILES    := $(shell git ls-files '*.md' ':!:core/**')

.DEFAULT_GOAL := help
.PHONY: help lint lint-sh lint-zsh lint-actions lint-md check-core core-lock bootstrap-dry test capabilities

help: ## Show this help
	@echo "dotfiles-openSUSE — local targets:"
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk -F':.*?## ' '{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  Pre-push gate: make test"

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

check-core: ## Verify vendored core/ matches the commit core.lock pins (mirrors CI's guard / integrity)
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
	vend="$$(git rev-parse 'HEAD:core')"; \
	if ! git rev-parse --verify --quiet "$$sha^{tree}" >/dev/null; then \
	  echo ":: fetching pinned commit from $(CORE_REMOTE) (treeless)"; \
	  git fetch --quiet --depth=1 --filter=tree:0 "$(CORE_REMOTE)" "$$sha" || { \
	    echo "!! could not fetch $$sha — offline? local checks above still passed"; exit 1; }; \
	fi; \
	exp="$$(git rev-parse --verify "$$sha^{tree}")"; \
	if [ "$$vend" = "$$exp" ]; then \
	  echo "   tree matches upstream: $$vend"; echo ":: core integrity OK"; \
	else \
	  echo "!! MISMATCH  vendored=$$vend  expected=$$exp"; \
	  echo "   Fix upstream in dotfiles-core, then 'make sync' there. Never hand-edit core/."; \
	  exit 1; \
	fi

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


bootstrap-dry: ## Preview every symlink bootstrap would create; mutates nothing
	./bootstrap.sh --links-only --dry-run

test: lint check-core ## The pre-push gate: lint + core integrity
	@echo
	@echo ":: all local checks passed"

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

