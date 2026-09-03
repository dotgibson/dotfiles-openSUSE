# Makefile — the local gate for dotfiles-openSUSE.
# ──────────────────────────────────────────────────────────────────────────────
# Before this existed there was no way to validate the repo short of running
# ./bootstrap.sh for real against your own machine, and core.lock's own header told
# you to run `make core-lock` — a target that did not exist here. These targets
# mirror what CI actually runs, so local == CI — and where a check cannot be reproduced
# from a bare checkout it says so and defers to CI rather than answering a different
# question: `check`'s hermetic run needs an openSUSE host, and `core-verify`'s tree
# comparison needs a dotfiles-core clone (it runs Core's own script, the same one CI's
# `guard / integrity` runs). Neither degrades silently.
#
# That header instruction was itself the bug: dotgibson/dotfiles-core#454 found no such
# target existed anywhere and removed the line, because core.lock is written by
# sync-core.sh in the same commit as the subtree pull and was never meant to have a
# second writer. `core-lock` here is now a redirect rather than a second generator of
# a format Core owns (dotgibson/dotfiles-core#593).
#
# Scope note: this repo owns bootstrap.sh, os/, install/, ssh/, wsl/, test/ and
# .github/. core/ is vendored and is NEVER linted or edited here — it is gated upstream
# in dotfiles-core by `make audit`, and guarded here by `make core-verify`.
#
# THE VERB NAMES ARE NOT LOCAL CHOICES (dotgibson/dotfiles-core#691). Core declares one
# `make` vocabulary for every repo that vendors it — help, lint, check, dry-run,
# packages-check, core-verify, test — in scripts/make-vocabulary.txt, because nine repos
# had grown nine dialects: "dry run" was spelled two ways across the fleet and "verify
# core" five, so a contributor moving between repos re-learned the verbs each time. Two
# targets here were renamed to the canonical spelling and KEPT THEIR OLD NAMES AS
# ALIASES (bootstrap-dry, check-core), because the requirement is that the canonical
# name resolves — not that muscle memory dies. `make fleet-vocabulary` in a Core checkout
# beside this one renders the verb x repo register.

# A real executable path: make execs SHELL directly and does NOT word-split it, so
# `/usr/bin/env bash` would be looked up as a single filename and fail. openSUSE always
# ships /bin/bash.
SHELL       := /bin/bash
CORE_REMOTE ?= https://github.com/dotgibson/dotfiles-core.git
# The dotfiles-core checkout `core-verify` compares against. Empty = auto-resolve; see the
# comment on that target for why the comparison is delegated rather than done here.
CORE_REF    ?=

# Repo-owned shell only; core/ is excluded everywhere on purpose.
# `git ls-files`, not the literal `bootstrap.sh` this used to be: that spelling was
# correct only while bootstrap.sh WAS the repo's entire shell surface, and it stopped
# being true the moment test/ arrived — the CI gate lints `git ls-files '*.sh'
# ':!:core/**'`, so a literal here silently lints less than the blocking gate does,
# which is the one direction this Makefile must never drift in.
#
# THE GIT LIST CAN COME BACK EMPTY, and that must not be silent. GitHub's "Download ZIP"
# ships no .git, and a host may have no git at all; either way the pathspec yields
# nothing. An empty list is not a quiet no-op here — `bash -n` with NO OPERANDS reads
# STDIN, so `make lint-sh` would sit there waiting for input, looking like a slow gate
# rather than a broken one (verified: it blocks until stdin closes). `shellcheck` and
# `markdownlint-cli2` both exit non-zero on an empty argument list, so this hazard is
# `bash -n`'s alone.
#
# So the git list is the PRIMARY and a wildcard is the fallback, and lint-sh says which
# one it used. The wildcard is deliberately NOT presented as equivalent: it can only see
# the directories named here, so it drifts from the CI pathspec the moment a .sh lands
# somewhere new — it keeps a no-git checkout linting rather than making the "local == CI"
# promise the git form makes.
# `command -v git` first, not just `2>/dev/null` on the ls-files: the shell prints its
# own `git: command not found` to ITS stderr, which the command's redirect does not
# cover, so a no-git host leaked that line out of $(shell …) on every make invocation.
SH_FILES_GIT := $(shell command -v git >/dev/null 2>&1 && git ls-files '*.sh' ':!:core/**' 2>/dev/null)
SH_FILES     := $(if $(SH_FILES_GIT),$(SH_FILES_GIT),$(wildcard *.sh test/*.sh))
ZSH_FILES   := $(wildcard os/*.zsh)
# Unlike the two above, this is `git ls-files` rather than a literal or a wildcard: it is
# the exact pathspec lint-call.yml's markdown leg uses, so `make lint-md` scans what the
# blocking gate scans. A wildcard would be one directory deep and miss anything under
# .github/, which is the scope defect found across the fleet (dotgibson/dotfiles-core#775).
# Guarded the same way as SH_FILES_GIT above, and for the same reason: unguarded, this
# leaked `git: command not found` / `fatal: not a git repository` out of every single
# make invocation on a no-git host or a ZIP download — including `make help`. An empty
# MD_FILES needs no fallback, though: markdownlint-cli2 exits non-zero on an empty
# argument list, so lint-md already fails loudly instead of passing on nothing.
MD_FILES    := $(shell command -v git >/dev/null 2>&1 && git ls-files '*.md' ':!:core/**' 2>/dev/null)

.DEFAULT_GOAL := help
# `test` MUST stay .PHONY now that test/ exists: a target whose name is also a
# directory is "up to date" without it, and `make test` would run nothing at all.
.PHONY: help lint lint-sh lint-zsh lint-actions lint-md check core-verify check-core \
        core-lock dry-run bootstrap-dry packages-check suite test capabilities

help: ## Show this help
	@echo "dotfiles-openSUSE — local targets:"
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk -F':.*?## ' '{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  Pre-push gate: make test"
	@echo "  Canonical fleet verbs: help lint check dry-run packages-check core-verify test"

lint: lint-sh lint-zsh lint-actions lint-md capabilities ## Run every linter (shellcheck + zsh -n + actionlint + markdownlint)

# `&&` before the ok, not `;`. With a semicolon the echo ran regardless and became the
# line's exit status, so shellcheck could print a screen of findings and this target still
# reported "ok" and exited 0 — a gate that cannot fail. lint-zsh (`|| exit 1`) and
# lint-actions (`&&`) were already correct; this arm was the only one that was not.
lint-sh: ## ShellCheck the repo-owned bash (uses ./.shellcheckrc)
	@test -n "$(SH_FILES)" || { \
	  echo "!! no repo-owned *.sh found — neither 'git ls-files' nor the wildcard fallback"; \
	  echo "   matched anything. Refusing to report a pass on nothing; fix the checkout"; \
	  echo "   (this is a git repo with bootstrap.sh tracked in it) rather than this gate."; \
	  exit 1; \
	}
	@test -n "$(SH_FILES_GIT)" || echo "!! no git file list here (no .git, or no git on PATH) — using a wildcard, which is NOT the CI pathspec"
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

# THE TREE COMPARISON IS DELEGATED TO CORE, and that is a correction, not a preference.
#
# This target used to answer the question itself: compare `git rev-parse HEAD:core` against
# `git rev-parse "$core_sha^{tree}"`. That is the whole ROOT tree of the pinned Core commit
# (294 files) versus this repo's vendored subtree (185), and since dotgibson/dotfiles-core#676
# a commit carrying `core.vendor` is vendored as `core.manifest` ∪ `core.vendor` — not as its
# whole tree. So the two could never be equal, and the target reported
#
#     !! MISMATCH  vendored=2b5665e4afe6  expected=f416232f9abe
#
# on a PRISTINE tree, on every clean checkout, for everyone. It was not a slow or partial
# gate; it was a confident false accusation of tampering, and it took `make test` — the
# documented pre-push gate — red with it.
#
# WHY NOT REBUILD THE FILTERED TREE HERE. Because "pristine" would then have two
# definitions, which is strictly worse than the second `core.lock` generator that
# `core-lock` below exists to refuse. Core's core_vendor_tree (scripts/lib/core-vendor.sh)
# is ~55 lines carrying four separate hard-won corrections — resolve to the repo root first
# or `update-index --index-info` reads its paths against the cwd prefix and silently returns
# git's EMPTY tree with status 0; GIT_INDEX_FILE must be absolute or the index lands inside
# the repo; `mktemp -d` plus `$dir/index`, never a bare mktemp, because git errors on a
# zero-length index; and an empty tree from a non-empty keeplist must be rejected as the
# signature of a filter that matched nothing. Its own comments record that a vendored copy
# run as `core/scripts/core-integrity.sh --self` hit the first of those and "reported every
# repo TAMPERED against an empty expectation". Re-deriving that in a make recipe, `$$` and
# all, is how this repo would earn those four bugs a second time.
#
# So the comparison runs Core's script — literally the same file CI runs
# (core-integrity-call.yml checks out dotfiles-core at full depth and calls
# `scripts/core-integrity.sh --self`), which makes local == CI by construction rather than
# by agreement.
#
# WHAT THAT COSTS: a sibling dotfiles-core checkout. The old self-contained form needed
# none — it fetched the pinned commit treeless from CORE_REMOTE — but that independence was
# only ever apparent, since what it computed offline was wrong. A check that needs a clone
# and says so beats one that runs anywhere and lies. The three LOCAL invariants below still
# need neither clone nor network, and they catch the two failures a human actually causes:
# a hand-edit under core/, and a botched sync. Absent the clone the tree comparison SKIPS
# with a notice naming CI, exactly as lint-actions and lint-md do for a missing tool — a
# missing local reference is a fact about this machine, not a finding about the repo.
#
# CORE_REF points at that checkout. Empty (the default) auto-resolves: beside this
# directory, then beside the MAIN checkout, which is what finds it from a git worktree
# (`../dotfiles-core` from .claude/worktrees/<name> resolves inside the worktrees dir, and
# worktrees are routine here). The main checkout is `git rev-parse --git-common-dir` (which
# is `<main>/.git`, NOT the per-worktree `--git-dir` of `.git/worktrees/<name>`) with two
# levels stripped — resolved to an absolute path FIRST via `cd … && pwd`, because git may
# return that dir relative, and a lexical `/../../` on a relative `.git` would climb out of
# the wrong directory.
core-verify: ## Verify vendored core/ matches the commit core.lock pins (mirrors CI's guard / integrity)
	@set -uo pipefail; \
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
	ref="$(CORE_REF)"; \
	if [ -z "$$ref" ]; then \
	  gcd="$$(git rev-parse --git-common-dir 2>/dev/null)"; \
	  [ -n "$$gcd" ] && gcd="$$(cd "$$gcd" 2>/dev/null && pwd)"; \
	  for c in "$(CURDIR)/../dotfiles-core" $${gcd:+"$$gcd/../../dotfiles-core"}; do \
	    if [ -x "$$c/scripts/core-integrity.sh" ]; then ref="$$(cd "$$c" && pwd)"; break; fi; \
	  done; \
	fi; \
	if [ -z "$$ref" ] || [ ! -x "$$ref/scripts/core-integrity.sh" ]; then \
	  echo "!! no dotfiles-core checkout found — skipping the tree comparison (CI still enforces it)"; \
	  echo "   The pinned core_sha only resolves in Core's own object store, so the comparison"; \
	  echo "   needs one:  git clone $(CORE_REMOTE) ../dotfiles-core"; \
	  echo "   Elsewhere already?  make core-verify CORE_REF=/path/to/dotfiles-core"; \
	  exit 0; \
	fi; \
	echo ":: reference: $$ref"; \
	if ! git -C "$$ref" cat-file -e "$$sha" 2>/dev/null; then \
	  echo ":: locked core_sha is not in that clone yet — fetching (a stale reference reports"; \
	  echo "   UNVERIFIABLE, which reads like tampering but only means 'fetch Core')"; \
	  git -C "$$ref" fetch --quiet "$(CORE_REMOTE)" "$$sha" 2>/dev/null || \
	    git -C "$$ref" fetch --quiet origin 2>/dev/null || true; \
	fi; \
	"$$ref/scripts/core-integrity.sh" --self "$(CURDIR)"

# The historical spelling. Core's vocabulary needs `core-verify` to RESOLVE here, not
# this name to die — SECURITY.md, CONTRIBUTING.md and .env.example all said `check-core`
# for a year, and so did every shell history in the fleet's five dialects for this one
# verb (core-verify / verify-core / check-core / core-check / core-advisory).
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
	@echo "  disagreement 'make core-verify' exists to detect."
	@echo
	@echo "It also wrote core_branch=<sha>, duplicating core_sha — the defect Core fixed in"
	@echo "#453 by renaming the field to core_ref, which this never knew about."
	@echo
	@echo "If core/ and core.lock disagree, re-run the fan-out from a dotfiles-core"
	@echo "checkout rather than patching the lock here:"
	@echo
	@echo "    make sync          # in dotfiles-core"
	@echo
	@echo "Then verify this repo with:  make core-verify"


# The canonical spelling is `dry-run`, and the meaning Core's vocabulary gives it is
# "preview a FULL install, touching nothing" — so this drops the `--links-only` the old
# `bootstrap-dry` passed. Nothing is lost: `--dry-run` still previews every symlink
# (BLIB_DRY makes the Core link helpers plan-only), and it additionally reports the
# provision step that --links-only returns before ever reaching. Both flags mutate
# nothing either way; the only difference is one more line of plan.
dry-run: ## Preview the FULL bootstrap plan (packages + symlinks); mutates nothing
	./bootstrap.sh --dry-run

bootstrap-dry: dry-run ## (alias) the pre-#691 spelling of dry-run

packages-check: ## Do all install/packages.txt names resolve against zypper? (installs nothing)
	@./test/check-packages.sh install/packages.txt

# `check` is the vocabulary's "lint plus a hermetic --links-only bootstrap run", and the
# hermetic half is the only local gate that executes wire_links at all — `make lint` only
# ever parses it. It runs against a throwaway HOME, so nothing on this machine is touched.
#
# XDG_CONFIG_HOME IS UNSET, not just HOME overridden. bootstrap.sh resolves
# CONFIG=${XDG_CONFIG_HOME:-$HOME/.config}, so on a box that exports it — which is most
# of them, since Core's own shell layer does — a HOME-only override sends every symlink
# into the REAL config tree and the "hermetic" run rewires the machine it was meant to
# leave alone.
#
# BLIB_SU=true makes the privileged steps no-ops. The login-shell step (chsh + appending
# /etc/shells) is the one thing wire_links does that reaches outside $HOME, and it is
# neither what this target is asserting nor something a check may do to the host.
check: lint ## lint + a hermetic --links-only run against a throwaway HOME
	@if ! grep -qi opensuse /etc/os-release 2>/dev/null; then \
	  echo "!! not openSUSE — skipping the hermetic --links-only run (bootstrap.sh refuses to"; \
	  echo "   run off-distro by design; CI still enforces it in .github/workflows/bootstrap.yml)"; \
	  exit 0; \
	fi; \
	set -u; \
	tmp=$$(mktemp -d) || exit 1; \
	trap 'rm -rf "$$tmp"' EXIT; \
	mkdir -p "$$tmp/.config/tmux/plugins/tpm"; \
	echo ":: bootstrap --links-only into $$tmp"; \
	env -u XDG_CONFIG_HOME HOME="$$tmp" BLIB_SU=true ./bootstrap.sh --links-only >"$$tmp/.log" 2>&1 || { \
	  echo "!! bootstrap --links-only failed:"; sed 's/^/   | /' "$$tmp/.log"; exit 1; }; \
	rc=0; \
	for l in .config/zsh/loader.zsh .config/zsh/80-os.zsh .config/zsh/os.capabilities \
	         .config/starship.toml .config/lazygit/config.yml .config/nvim .vimrc \
	         .gitconfig .config/tmux/os.conf .config/git/os.gitconfig; do \
	  test -L "$$tmp/$$l" || { echo "MISSING symlink: $$l"; rc=1; }; \
	done; \
	test -e "$$tmp/.config/zsh/loader.zsh" || { echo "loader.zsh is dangling"; rc=1; }; \
	grep -q "dotfiles-managed v4" "$$tmp/.zshrc" || { echo "~/.zshrc not managed"; rc=1; }; \
	grep -q "source .*loader.zsh" "$$tmp/.zshrc" || { echo "~/.zshrc does not source the loader"; rc=1; }; \
	want=os/opensuse.capabilities; \
	grep -qi tumbleweed /etc/os-release || want=os/opensuse.leap.capabilities; \
	got=$$(readlink "$$tmp/.config/zsh/os.capabilities" 2>/dev/null); \
	case "$$got" in \
	*/$$want) ;; \
	*) echo "os.capabilities -> $${got:-nothing}, expected .../$$want for this flavor"; rc=1 ;; \
	esac; \
	test $$rc -eq 0 && echo ":: symlink graph OK" || exit 1

# The repo's own suite, and nothing else — no linters, no network, no privileges. `make
# test` below is the pre-push gate that also runs it; CI runs THIS target, so the gate's
# two other legs (lint.yml, core-integrity.yml) are not paid for twice per PR.
#
# The glob is guarded because an unmatched glob stays LITERAL in sh — without the test
# this would "run" a file named `test/*.sh` and pass on nothing, which is the failure
# mode a gate must never have (same reasoning as `capabilities` below).
suite: ## Run the repo's own suite (test/*.sh) — no linters, no network
	@rc=0; found=0; \
	for t in test/*.sh; do \
	  [ -f "$$t" ] || continue; found=1; \
	  echo ":: $$t"; \
	  bash "$$t" || rc=1; \
	done; \
	if [ "$$found" -eq 0 ]; then echo "!! no test/*.sh — the suite is empty"; exit 1; fi; \
	exit $$rc

test: lint core-verify suite ## The pre-push gate: lint + core integrity + the repo suite
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

