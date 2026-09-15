#!/usr/bin/env bash
# dotfiles-openSUSE/bootstrap.sh
# ──────────────────────────────────────────────────────────────────────────────
# Provision an openSUSE box (Tumbleweed, Leap or the transactional edition — MicroOS /
# Aeon / Kalpa; Workstation or WSL) and wire up dotfiles. Idempotent — safe to re-run. This is the OS-NATIVE layer; Core
# (zsh/tmux/nvim/git) is vendored under core/ and symlinked via core/lib/bootstrap-lib.sh.
#
# THE DRIVER FORM (dotgibson/dotfiles-core#976, #986). The shared half of a bootstrap — the
# flags, the escalator, the sudo keepalive, the Core symlink surface, the OS overlays, the
# managed ~/.zshrc loader, the login shell, the closing report — is core/lib/bootstrap-lib.sh
# :: blib_main, ONE definition instead of a copy per repo. This file declares what it is —
# including the exit-code contract that is this repo's own — defines the hooks that are
# genuinely openSUSE's (the guard, the zypper provisioning, the Leap capability re-link, the
# closing hints, the repo flags), and hands over. `--help` prints both halves.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Read by blib_main in the sourced lib (shellcheck does not follow into it).
# shellcheck disable=SC2034
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
DO_FLATPAK=1

# Neovim version floor. nvim-treesitter's `main` branch (core/nvim, lazy-lock.json) does
# not merely prefer 0.12 — it will not load below it. Named once here because it is
# asserted in two places that must agree: install/packages.txt's `# min:` on the neovim
# entry (the fleet contract core/PORTING-MATRIX.md derives its cell from) and this, which
# _dotfiles_nvim_meets_floor reads; test/check-packages.sh fails if the two drift apart.
# Bump it only when Core's floor actually moves.
NEOVIM_FLOOR="0.12.0"

# ── core/ subtree present? (inline: can't source a lib out of core/ before this) ─
# Validate the SPECIFIC paths we depend on (zsh modules + the two libs sourced
# next) so a missing/partial subtree fails HERE with a precise message, not later
# with a cryptic `source: No such file`.
for _req in core/zsh/loader.zsh core/lib/ux.sh core/lib/bootstrap-lib.sh; do
  if [[ ! -e "$DOTFILES/$_req" ]]; then
    echo "vendored core/ missing or incomplete (need $_req). To populate it:" >&2
    echo "  make sync          # in dotfiles-core — the fan-out that also stamps core.lock" >&2
    echo "If core/ does not exist AT ALL the fan-out skips this repo; do the one-time" >&2
    echo "vendor first, from a RELEASED TAG (never main, or core-integrity reports the" >&2
    echo "fresh tree as TAMPERED), then sync:" >&2
    echo "  git subtree add --prefix=core <dotfiles-core remote> refs/tags/v7 --squash" >&2
    exit 1
  fi
done
unset _req

# Shared bash UX palette + provisioning scaffold (vendored under core/lib).
# shellcheck source=core/lib/ux.sh
source "$DOTFILES/core/lib/ux.sh"
# shellcheck source=core/lib/bootstrap-lib.sh
source "$DOTFILES/core/lib/bootstrap-lib.sh"


# ── what this repo is (read by blib_main) ─────────────────────────────────────
# shellcheck disable=SC2034
BOOTSTRAP_NAME="openSUSE"
# shellcheck disable=SC2034
BOOTSTRAP_OS=opensuse # → blib_link_os_layer: os/opensuse.{zsh,conf,gitconfig,capabilities}
# THE EXIT-CODE CONTRACT, kept: a run that completes but loses an optional tool exits 2,
# always, so a caller (or CI) can tell a clean install from a lossy one — no --strict
# needed. --tolerate-failures waives it (bootstrap_flag flips the default off; the driver
# re-reads it after the parse). Documented in --help and the README; the driver only
# carries it.
# shellcheck disable=SC2034
BOOTSTRAP_STRICT_DEFAULT=1
# shellcheck disable=SC2034
BOOTSTRAP_FAIL_EXIT=2
# shellcheck disable=SC2034
BLIB_STRICT_WHY="this repo exits 2 whenever an optional install did not complete; --tolerate-failures waives it"

# ── hooks (called by blib_main, in its order; shellcheck cannot see that) ─────
# shellcheck disable=SC2329
bootstrap_usage() {
  cat <<'EOF'
bootstrap.sh — provision an openSUSE box (Tumbleweed, Leap or the transactional edition:
MicroOS / Aeon / Kalpa; Workstation or WSL) and wire up dotfiles. Idempotent: safe to re-run.

On the transactional edition packages go into a NEW snapshot and are live after a reboot:
the run ends with "reboot to apply, then re-run once" — the second run builds the cargo/go
tools against the new snapshot's toolchain.

  --no-flatpak          skip the Flathub remote (auto-skipped on WSL)
  --tolerate-failures   exit 0 even if optional tools failed (for CI)

--only and --skip are mutually exclusive here: they describe the same selection from
opposite ends, and applying both leaves the module set undefined at this layer.

Exit codes:
  0  everything requested succeeded
  1  a precondition failed (not openSUSE, core/ missing, packages.txt unreadable,
     no way to escalate privileges)
  2  bootstrap completed but one or more OPTIONAL tools failed to install — the
     failure ledger is printed at the end with a retry hint for each; also the
     driver's code for a usage error (unknown flag), which is told apart by its text

Environment:
  BLIB_SU   privilege escalator. Resolved by Core's blib_resolve_su when unset: root
            runs directly, else sudo, else doas. Set BLIB_SU="" or BLIB_SU=doas to
            override the probe (minimal containers often have no sudo).
  BOOTSTRAP_PROVISIONER=transactional
            CI seam: take the transactional edition's branch on a box that is not one
            (the reusable bootstrap-test.yml's `provisioner:` input exports it into its
            stubbed run). Never needed on a real host — the marker is detected.
  BOOTSTRAP_TOLERATE_FAILURES=1
            the same waiver as --tolerate-failures, for a caller that cannot pass a flag
            (the reusable's stubbed run takes no arguments; its `prep:` can export this).
EOF
}
# shellcheck disable=SC2329
bootstrap_flag() {
  case "$1" in
  --no-flatpak) DO_FLATPAK=0 ;;
  --tolerate-failures) BOOTSTRAP_STRICT_DEFAULT=0 ;;
  *) return 1 ;;
  esac
  return 0
}
# shellcheck disable=SC2329
bootstrap_guard() {
  if [[ -n "${BLIB_ONLY:-}" && -n "${BLIB_SKIP:-}" ]]; then
    echo "--only and --skip are mutually exclusive — pick one" >&2
    exit 1
  fi
  # ── sanity: confirm we're on openSUSE (matches Tumbleweed AND Leap) ─────────
  if ! grep -qi opensuse /etc/os-release 2>/dev/null; then
    echo "This bootstrap targets openSUSE. /etc/os-release doesn't look like openSUSE." >&2
    exit 1
  fi
  # wsl.conf lives in provision(), so a links-only run on WSL leaves systemd off. Core's
  # 55-maint.zsh gates its systemd user timer on /run/systemd/system, so the maintenance
  # timer would silently never install. Say so rather than let it be a mystery later.
  if ((BLIB_LINKS_ONLY)) && ((IS_WSL)) && [[ ! -f /etc/wsl.conf ]]; then
    blib_warn "--links-only skips /etc/wsl.conf; without it WSL has no systemd and Core's maintenance timer won't install. Run a full bootstrap once."
  fi
}

# ── PATH prelude: make the presence guards below tell the TRUTH ───────────────
# bootstrap runs in BASH, before any Core shell exists, so the user-local bindirs the
# installs below WRITE INTO are not on PATH yet — ~/.local/bin, ~/.cargo/bin and GOBIN
# reach PATH only via core/zsh/00-tools.zsh and os/opensuse.zsh, i.e. only inside a Core
# zsh. Every `command -v <tool>` guard in this script is otherwise answered by the PATH
# of whatever shell launched it, and on a fresh box that is bash with none of them.
#
# THIS IS THE #130 BUG, fixed at its root. mise.run drops its binary in ~/.local/bin, so
# a bare `command -v mise` was false for the mise this script had installed moments
# earlier: both arms of the Go fallback missed and the else branch reported "needs a Go
# toolchain" on a box that had one. doggo and sesh went uninstalled and the run exited 2
# on EVERY bootstrap, invisible to CI until a genuinely unstubbed run looked (#130,
# dotgibson/dotfiles-core#742). That was patched with a local `_mise_bin` helper, which
# fixed the one probe it wrapped and left every OTHER off-PATH tool in this script with
# the same blind guard. Core has shipped blib_user_bindirs_on_path for exactly this since
# dotgibson/dotfiles-core#425; adopting it retires the fork (dotgibson/dotfiles-core#748).
#
# It resolves CARGO_HOME and GOBIN/GOPATH rather than hard-coding them, and adds only
# directories that EXIST — blib_main runs it before any hook, and provision() calls it
# AGAIN once the installers have created them. See there.

# ── failure ledger ────────────────────────────────────────────────────────────
# Package/tool installs here are deliberately best-effort: one unavailable crate must not
# abort a 5-minute provision. Every soft failure is recorded via Core's ledger — _note_fail
# is a thin shim over blib_note_fail, which warns at the moment it happens — and the driver
# prints the tally at the end and applies this repo's exit-2 contract (declared above).
_note_fail() { blib_note_fail "$@"; }

# ── privilege escalation ──────────────────────────────────────────────────────
# Honor Core's documented BLIB_SU contract (core/lib/bootstrap-lib.sh) instead of
# hardcoding `sudo`: BLIB_SU="" means "already root, run directly" and BLIB_SU=doas
# covers a doas-only box. Minimal openSUSE containers frequently ship no sudo at all,
# where the old bare `sudo zypper refresh` aborted under `set -e` before anything was
# provisioned. Deliberately a local helper rather than Core's _blib_priv: that symbol
# is underscore-private and could change on any subtree pull — the ENV CONTRACT is the
# supported surface, so this mirrors its semantics without depending on the internal.
_priv() {
  local su="${BLIB_SU-sudo}"
  if [[ -n "$su" ]]; then "$su" "$@"; else "$@"; fi
}


IS_WSL=0
if blib_is_wsl; then IS_WSL=1; fi

# ── transactional edition? (MicroOS, Aeon, Kalpa) ─────────────────────────────
# The root is read-only and transactional-update is the only installer: `zypper in` is
# refused outright ("Transactional system detected", rc 5 — measured on MicroOS 20260911,
# whose os-release says ID=opensuse-microos with ID_LIKE carrying opensuse-tumbleweed, so
# the guard above and the Tumbleweed probe below both pass). Test the HOST, not the ID:
# the verb exists and /usr cannot be written. Everything the transactional edition changes
# hangs off this flag: the declaration it links, how packages are installed (into a new
# snapshot, live after a reboot), and the closing line that says so.
IS_TRANSACTIONAL=0
if command -v transactional-update >/dev/null 2>&1 && [[ ! -w /usr ]]; then IS_TRANSACTIONAL=1; fi
# CI's seam (R6): a container's /usr is writable and has no transactional-update, so the
# stubbed-provision leg could never reach the snapshot path; BOOTSTRAP_PROVISIONER=transactional
# forces it, with transactional-update shimmed.
[[ "${BOOTSTRAP_PROVISIONER:-}" == transactional ]] && IS_TRANSACTIONAL=1
TU_STAGED=0 # packages transacted into the next snapshot this run — the closing hint keys on it
# CI's other seam, and why it exists next to this one: the reusable's provision-stub job runs
# `./bootstrap.sh` with no arguments and fails on any non-zero exit, and under its shims the
# carapace block cannot resolve a release URL (the curl stub answers nothing), which this
# repo's exit-2 contract turns into a red leg (dotfiles-core NON-MUTABLE-HOST-PROPOSAL R6,
# measured). `prep:` is the one thing the job evaluates in the same shell as the run, so the
# transactional leg exports this there. Identical in effect to --tolerate-failures; the leg's
# real assertion is the reusable's own grep for the "reboot to apply" closing line.
[[ "${BOOTSTRAP_TOLERATE_FAILURES:-0}" == 1 ]] && BOOTSTRAP_STRICT_DEFAULT=0

# ── zypper with retry ─────────────────────────────────────────────────────────
# openSUSE's OSS mirror (cdn.opensuse.org) intermittently times out (curl error 28).
# .github/workflows/bootstrap.yml already documents this and wraps its CI prep in a
# 5x backoff loop — but the script humans actually run had no retry at all, so a
# transient timeout aborted the whole bootstrap under `set -e` BEFORE any symlink was
# wired, leaving a half-provisioned box. Same loop shape as the CI prep.
zypper_retry() { # <zypper args...>
  local i rc=0
  for i in 1 2 3 4 5; do
    rc=0
    _priv zypper "$@" && return 0 || rc=$?
    # Informational codes are success, not something to retry (see zypper_install).
    case $rc in 102 | 103 | 106) return 0 ;; esac
    # Permanent failures must NOT burn the backoff budget. 104 (capability not found)
    # is the common one — an unavailable package is exactly what the package-by-package
    # fallback exists to handle, and retrying it 5x would add ~100s of sleep before
    # reaching that fallback. 2/3 are argument errors, 5 is a privilege problem and
    # 107 an RPM script failure; none get better by waiting.
    case $rc in 2 | 3 | 5 | 104 | 107) return "$rc" ;; esac
    ((i == 5)) && break
    blib_warn "zypper attempt $i failed (rc=$rc; mirror timeout?), retrying in $((i * 10))s..."
    sleep $((i * 10))
  done
  return "$rc"
}

# ── resilient install: zypper aborts the WHOLE transaction on one unknown pkg
# (exit 104 = capability not found). Bulk first, then per-package. ──────────────
zypper_install() {
  local -a pkgs=("$@")
  local rc=0
  if ((IS_TRANSACTIONAL)); then
    # One snapshot, not one per package: transactional-update takes ~20 s per transaction
    # (measured) and, like zypper, aborts the whole install on one unknown name. The
    # read-only repo cache answers `zypper se` on the running system, so drop the unknown
    # names FIRST and transact once. Its options go BEFORE the command (-n here, not
    # --non-interactive after `pkg in`), and `pkg in` passes the rest to zypper install.
    # --continue on EVERY call: without it each transaction starts from the BOOTED
    # snapshot and silently discards the pending one — measured: 47 packages went into
    # snapshot 3, the next call opened snapshot 4 from snapshot 2, and the reboot booted
    # 4 with none of them.
    local -a avail=() p
    for p in "${pkgs[@]}"; do
      # already installed → nothing to transact (a re-run otherwise re-transacts the whole
      # list into three more snapshots — measured on iteration 2, snapshots 6–8)
      rpm -q "$p" >/dev/null 2>&1 && continue
      zypper --non-interactive --quiet se --match-exact --type package "$p" >/dev/null 2>&1 && avail+=("$p") || {
        echo "   skipped (unavailable on this box?): $p"
        _note_fail "package '$p' — not available; check with: zypper se --provides $p"
      }
    done
    ((${#avail[@]})) || return 0
    _priv transactional-update -n --no-selfupdate --continue pkg in --no-recommends "${avail[@]}" || rc=$?
    case $rc in
    0 | 102 | 103 | 106) TU_STAGED=$((TU_STAGED + ${#avail[@]})); return 0 ;;
    *) _note_fail "transactional-update pkg in failed (rc=$rc) — retry later: ${BLIB_SU-sudo} transactional-update -n --continue pkg in ${avail[*]}"; return 0 ;;
    esac
  fi
  zypper_retry --non-interactive install --no-recommends "${pkgs[@]}" || rc=$?
  # zypper's exit codes are not a simple 0/non-0: 102 (reboot needed), 103 (zypper
  # itself needs restarting) and 106 (a repo was unavailable but the install
  # succeeded) all mean the transaction WORKED. Treating them as failure sent a
  # perfectly good bulk install into the package-by-package fallback and reinstalled
  # the entire list one at a time — slow, and it printed a misleading "hit a snag".
  case $rc in 0 | 102 | 103 | 106) return 0 ;; esac

  blib_say "bulk install hit a snag (rc=$rc) — retrying package-by-package"
  local p prc
  for p in "${pkgs[@]}"; do
    prc=0
    _priv zypper --non-interactive install --no-recommends "$p" || prc=$?
    case $prc in 0 | 102 | 103 | 106) continue ;; esac
    echo "   skipped (unavailable on this box?): $p"
    _note_fail "package '$p' — not available; check with: zypper se --provides $p"
  done
}

# Best-effort `go install` for tools not packaged on openSUSE. Presence-guarded
# (skips if the binary already exists), tolerant of a missing Go toolchain, and
# never aborts the run — but every failure is now recorded in the ledger.
# ── neovim version floor ──────────────────────────────────────────────────────
# _dotfiles_nvim_meets_floor <floor> — true when the nvim that will actually RUN clears
# <floor>. PATH-only on purpose: there is no cargo/user-local neovim to also probe (no
# crate ships the binary), and the PATH prelude already puts mise shims and ~/.local/bin
# ahead of /usr/bin, so whatever `command -v nvim` resolves to IS what Core's config
# loads — including a `mise use -g neovim@0.12` that an operator installed to get past
# Leap 16.0's 0.11.3. An nvim whose --version cannot be run or parsed counts as NOT
# meeting the floor: fail loud, the same default Alpine's twin of this helper takes.
#
# The comparison is `zypper versioncmp`, the RPM comparator zypper itself uses, rather
# than a hand-rolled field compare: bootstrap only runs on openSUSE (the /etc/os-release
# check above), so zypper is a given. zypper(8): exit 0 = equal, 11 = VERSION1 newer,
# 12 = VERSION2 newer. Dev builds print "NVIM v0.12.0-dev-1234+gabc123"; the RPM
# comparator reads that as 0.12.0 with a release, which is at the floor, not below it.
_dotfiles_nvim_meets_floor() { # <floor>
  local floor="$1" cand out ver
  cand="$(command -v nvim 2>/dev/null)" || return 1
  [[ -n "$cand" && -x "$cand" ]] || return 1
  out="$("$cand" --version 2>/dev/null)" || return 1
  # First line is "NVIM v0.12.5"; take its last field and drop the leading "v".
  out="${out%%$'\n'*}"
  ver="${out##* }"
  ver="${ver#v}"
  [[ "$ver" =~ ^[0-9] ]] || return 1
  zypper --non-interactive versioncmp "$ver" "$floor" >/dev/null 2>&1
  case $? in 0 | 11) return 0 ;; esac
  return 1
}

_dotfiles_go_install() { # <import-path@version> <binary-name>
  [ "$#" -ge 2 ] || return 0
  if command -v "$2" >/dev/null 2>&1; then return 0; fi
  # `go install` defaults to ~/go/bin, which is NOT on the shell PATH (the shell
  # layer prefixes ~/.local/bin and ~/.cargo/bin). Force GOBIN into ~/.local/bin.
  local gobin="$HOME/.local/bin"
  mkdir -p "$gobin" 2>/dev/null || true
  # A BARE `command -v mise` again, and it is correct now: blib_user_bindirs_on_path has
  # put ~/.local/bin on this script's PATH, so it sees the mise provision() installed.
  # This used to route through a local `_mise_bin` fork of that logic, which had to be
  # written twice and was wrong in one of the copies.
  if command -v go >/dev/null 2>&1; then
    GOBIN="$gobin" go install "$1" >/dev/null 2>&1 ||
      _note_fail "$2 — go install failed; retry: GOBIN=$gobin go install $1"
  elif command -v mise >/dev/null 2>&1; then
    GOBIN="$gobin" mise exec go@latest -- go install "$1" >/dev/null 2>&1 ||
      _note_fail "$2 — go install failed; retry: GOBIN=$gobin go install $1"
  else
    _note_fail "$2 — needs a Go toolchain; install Go then: GOBIN=$gobin go install $1"
  fi
  return 0
}

# _render_placeholder <text> <placeholder> <value> — substitute every occurrence of
# PLACEHOLDER in TEXT with VALUE, treating VALUE as strictly literal.
#
# Built from ${var%%…} / ${var#…} only. Those take a PATTERN but have no replacement
# string, so there is nowhere for &, \ or / to acquire meaning — which is the failure
# mode every other substitution tool here has (see the caller in the WSL block).
_render_placeholder() {
  local text="$1" ph="$2" val="$3" out=""
  while [[ "$text" == *"$ph"* ]]; do
    out+="${text%%"$ph"*}$val"
    text="${text#*"$ph"}"
  done
  printf '%s' "$out$text"
}

provision() {
  blib_say "zypper refresh (metadata)"
  zypper_retry --non-interactive --gpg-auto-import-keys refresh

  # Upgrades are USER-driven (see README): Tumbleweed = `zdup` (zypper dup),
  # Leap = `zup` (zypper up). bootstrap only refreshes metadata so a re-run stays
  # fast and never triggers a surprise rolling upgrade mid-setup.
  if ((IS_TRANSACTIONAL)); then
    # A Tumbleweed base (ID_LIKE says so), so `dup` — but `zypper dup` is refused here
    # ("Transactional system detected"); the snapshot verb stages it and a reboot applies.
    blib_say "detected the transactional edition — system upgrades use 'sudo transactional-update dup' (staged; reboot to apply)"
  elif grep -qi tumbleweed /etc/os-release; then
    blib_say "detected Tumbleweed — system upgrades use 'zdup' (zypper dup)"
  else
    blib_say "detected Leap — system upgrades use 'zup' (zypper up)"
  fi
  # Packman (codecs) is intentionally NOT auto-added: the repo URL differs
  # Tumbleweed-vs-Leap and it isn't needed for the CLI stack. See the README.

  blib_say "zypper packages (from install/packages.txt)"
  local pkgfile="$DOTFILES/install/packages.txt"
  # A missing or unreadable packages.txt used to be INDISTINGUISHABLE from an empty
  # one: blib_read_pkgs runs inside a process substitution, so its exit status is
  # discarded and mapfile just yields an empty array. A fresh clone that lost the file
  # provisioned nothing and reported "lists no packages — skipping" as if that were
  # intended. Make the missing-file case a hard precondition failure.
  if [[ ! -r "$pkgfile" ]]; then
    echo "install/packages.txt is missing or unreadable at: $pkgfile" >&2
    echo "The clone is incomplete — re-clone, or restore the file from git." >&2
    exit 1
  fi
  local -a pkgs=()
  mapfile -t pkgs < <(blib_read_pkgs "$pkgfile")
  # A genuinely empty (all-comment/blank) file is a legitimate, if odd, state: warn
  # and carry on rather than running zypper with no args.
  if ((${#pkgs[@]})); then
    zypper_install "${pkgs[@]}"
    blib_ok "zypper packages requested: ${#pkgs[@]}"
  else
    blib_warn "install/packages.txt lists no packages — skipping zypper install"
  fi

  # ── upstream installers: FALLBACK ONLY ───────────────────────────────────────
  # starship and atuin are now in install/packages.txt (Tumbleweed's repo-oss ships
  # both first-class — PORTING-MATRIX.md footnote 18), so on a healthy box the zypper
  # pass above satisfies these guards and no remote script is ever executed. The
  # installers remain for Leap and for a box where the package was unavailable.
  #
  # These are unpinned `curl | sh` — remote code executed as the invoking user. Keeping
  # them off the happy path is the point of the package-first ordering; the stderr
  # silencing is deliberately gone, because a failed or hijacked installer must not
  # look identical to a successful one.
  if ! command -v starship >/dev/null; then
    blib_say "starship not packaged here — falling back to the official installer"
    curl -fsSL https://starship.rs/install.sh | sh -s -- -y >/dev/null ||
      _note_fail "starship — installer failed; retry: curl -fsSL https://starship.rs/install.sh | sh -s -- -y"
  fi
  if ! command -v atuin >/dev/null; then
    blib_say "atuin not packaged here — falling back to the official installer"
    curl -fsSL https://setup.atuin.sh | sh >/dev/null ||
      _note_fail "atuin — installer failed; retry: curl -fsSL https://setup.atuin.sh | sh"
  fi
  # yazi is PACKAGED (install/packages.txt) — the cargo path that used to live here was
  # broken in a way that hid itself for as long as it existed.
  #
  # `cargo install --locked yazi-build` SUCCEEDS, so it never tripped the failure ledger,
  # but yazi-build is not the file manager: it is the workspace's xtask build-task runner,
  # and the only binary it ships is literally named `yazi-build`
  # (`cargo install` records bins:["yazi-build"]; running it prints "Yazi build tasks —
  # Usage: cargo xtask build|dist|install"). So `command -v yazi` and `-x ~/.cargo/bin/yazi`
  # were both false forever, exactly as they had been for the earlier `yazi-fs` attempt the
  # old comment here described — every bootstrap rebuilt a hundred-plus crates, produced no
  # `yazi` command, and exited 0 reporting success. Verified on a live box: ~/.cargo/bin held
  # `yazi-build` and no `yazi`.
  #
  # openSUSE packages yazi first-class (Tumbleweed OSS 26.5.6 vs crates.io 26.8.15), so
  # packaged-first — the policy already used for starship/atuin — is both correct and an
  # enormous saving. Deliberately no cargo fallback: upstream's crates.io story here is a
  # moving target that has now produced two silently-wrong invocations, so an unverified
  # build command must not run automatically. Record it instead and let the operator decide.
  # The message states the condition actually TESTED, not an inferred cause: the guard
  # knows only that yazi is not on PATH and not at ~/.cargo/bin/yazi. A yazi installed
  # somewhere else entirely would trip this, and blaming zypper would then send the
  # operator down the wrong path.
  if ((IS_TRANSACTIONAL)) && ((TU_STAGED)) && ! command -v yazi >/dev/null; then
    blib_say "yazi is in the next snapshot — live after the reboot"
  elif ! command -v yazi >/dev/null && [[ ! -x "$HOME/.cargo/bin/yazi" ]]; then
    _note_fail "yazi — not on PATH and not at ~/.cargo/bin/yazi. Preferred fix: sudo zypper in yazi (it is packaged, and in install/packages.txt). Upstream alternative: cargo install --locked yazi-fm yazi-cli, which yields 'yazi' + 'ya'"
  fi
  # mise — polyglot runtime manager; activated in core/zsh/00-tools.zsh. Runtimes are
  # fetched separately with `mise install` (kept out of bootstrap). No OSS package
  # exists, so mise.run stays the primary path — but its output is no longer discarded.
  if ! command -v mise >/dev/null && [[ ! -x "$HOME/.local/bin/mise" ]]; then
    blib_say "mise (official installer — not packaged on openSUSE)"
    curl -fsSL https://mise.run | sh >/dev/null ||
      _note_fail "mise — installer failed; retry: curl -fsSL https://mise.run | sh"
  fi
  # Re-run the PATH prelude: the helper adds only directories that already EXIST, and
  # ~/.local/bin is the one mise.run may have just created. Without this second call the
  # `command -v mise` fallbacks below are blind to it again — which is the whole bug.
  # Idempotent by construction.
  blib_user_bindirs_on_path
  # neovim — VERSION-checked, warn-only, and placed AFTER the mise block and the PATH
  # re-run so a mise-installed nvim is what gets probed. The zypper pass above installs
  # `neovim` on every target and only two of the three clear nvim-treesitter's floor:
  # Leap 16.0 ships 0.11.3 (install/packages.txt has the table). Warn rather than fix,
  # deliberately: there is no packaging lever on 16.0 (no newer build in OSS or
  # Backports), and pulling a runtime through mise unasked is not bootstrap's call —
  # point at the two real fixes and let the operator choose. The one thing this must
  # NOT do is stay silent: a `zypper in neovim` that succeeds and leaves nvim-treesitter
  # unable to load is exactly the invisible failure #178 reported.
  if ! _dotfiles_nvim_meets_floor "$NEOVIM_FLOOR"; then
    blib_warn "neovim is absent or below nvim-treesitter's >=$NEOVIM_FLOOR floor (Leap 16.0 ships 0.11.3) — nvim-treesitter will not load. Fix: move this box to Leap 16.1+ or Tumbleweed, or install a newer nvim (mise use -g neovim@0.12)"
  fi
  # tree-sitter CLI — nvim-treesitter (main) compiles parsers locally and needs the
  # CLI (>=0.26.1). This used to read "NOT in openSUSE repos", and that was wrong: the
  # CLI ships in the BASE `tree-sitter` package (0.26.8 on Tumbleweed and Leap 16.x),
  # which is in install/packages.txt as of #113. What openSUSE has no package of is the
  # name this block was named for — `tree-sitter-cli` is the Arch/Alpine split name, and
  # searching for it is how the repo concluded "unpackaged" and cargo-built it for so
  # long. So cargo is now the FALLBACK: the guard below sees the packaged binary on
  # PATH and skips. Swap to `mise use -g tree-sitter` if you want it newer.
  if ! command -v tree-sitter >/dev/null && command -v cargo >/dev/null; then
    blib_say "tree-sitter-cli (cargo)"
    cargo install --locked tree-sitter-cli >/dev/null 2>&1 ||
      _note_fail "tree-sitter-cli — build failed; retry: cargo install --locked tree-sitter-cli (or mise use -g tree-sitter)"
  fi
  # viddy (watch replacement; Core aliases watch->viddy, HAVE_VIDDY-guarded) is a Rust
  # CLI. Tumbleweed's repo-oss does package it, but we cargo-build for the upstream-latest
  # version — the guard below skips this if a package already put it on PATH.
  if ! command -v viddy >/dev/null && command -v cargo >/dev/null; then
    blib_say "viddy (cargo — watch replacement)"
    cargo install --locked viddy >/dev/null 2>&1 ||
      _note_fail "viddy — cargo build failed; retry: cargo install --locked viddy"
  fi

  # tealdeer (the `tldr` client) — PACKAGED on Tumbleweed (install/packages.txt), but gone
  # from Leap 16.0/16.1's primary repos; there it ships only in the `utilities` OBS repo,
  # which bootstrap deliberately does not add (same call as Packman — see provision's
  # header). So cargo is the automatic Leap path. Guard on `tldr`, NOT on `tealdeer`:
  # the crate is `tealdeer` and the binary it installs is `tldr`, and a guard naming the
  # wrong one is exactly the failure the yazi block above autopsies — it would never be
  # satisfied, so a packaged tldr would get rebuilt from source on every single run.
  if ! command -v tldr >/dev/null && command -v cargo >/dev/null; then
    blib_say "tealdeer (cargo — tldr; not in Leap's primary repos)"
    cargo install --locked tealdeer >/dev/null 2>&1 ||
      _note_fail "tealdeer — cargo build failed; retry: cargo install --locked tealdeer (on Leap 16.0 ONLY you can instead add the utilities OBS repo: zypper ar https://download.opensuse.org/repositories/utilities/16.0/ utilities — that repo has no 16.1 build, so on 16.1 cargo is the only route)"
  fi

  # ── go/vendor tools from the core-doctor set ─────────────────────────────────
  # sesh is genuinely absent from the openSUSE repos; doggo IS in Tumbleweed's
  # repo-oss, but is go-installed here for the same upstream-latest reason as the
  # block above. Each is presence-guarded and best-effort; a missing Go toolchain is
  # now recorded in the ledger rather than only echoed. sesh REQUIRES the /v2 module
  # path. carapace used to be in this list and CANNOT be — see the block below.
  blib_say "go tools (doggo, sesh)"
  _dotfiles_go_install github.com/mr-karan/doggo/cmd/doggo@latest doggo
  _dotfiles_go_install github.com/joshmedeski/sesh/v2@latest sesh

  # carapace: upstream's official RPM, NOT `go install`.
  #
  # `go install github.com/carapace-sh/carapace-bin/cmd/carapace@latest` cannot work, and
  # not for any version — two independent blockers, both properties of how the module is
  # built rather than a break to wait out (core/PORTING-MATRIX.md's carapace footnote ²⁷,
  # vendored in this tree, carries the full story and the evidence):
  #   1. Its go.mod carries `replace` directives (spf13/pflag → carapace-pflag,
  #      kevinburke/ssh_config → carapace-sh/ssh_config), and `go install pkg@version`
  #      refuses any module that does, because a replace would make the build differ from
  #      building it as the main module.
  #   2. The generated sources (pkg/{actions,conditions}/*_generated.go) are not committed;
  #      cmd/carapace/main.go's `go:generate` lines produce them. So even a plain
  #      `go build` on a clone fails until generation has run.
  # Checked across the whole tag history: 184 of 184 tags (v0.0.3 2020-08-31 → v1.7.3
  # 2026-06-30) carry a `replace`, and 0 commit the generated sources. So pinning an older
  # @version does NOT help — that is the tempting next move, and it fails identically.
  # The old call therefore failed on EVERY bootstrap, invisibly: _dotfiles_go_install sends
  # the explanation to /dev/null and downgrades the failure to a ledger note, so the run
  # just never produced a carapace and nobody saw why.
  #
  # Upstream publishes an official .rpm per release, which lands in /usr/bin. Two flags are
  # needed and they are not the same flag: upstream signs nothing (there is no `signs:`
  # stanza in its .goreleaser.yml), so `--no-gpg-checks` covers the GPG check failure and
  # `--allow-unsigned-rpm` covers the specific "plain rpm given on the command line is
  # unsigned" refusal. Without them `zypper -n` simply aborts. dnf4 needs neither, which is
  # why dotfiles-Fedora's otherwise-identical block looks simpler than this one.
  #
  # Be exact about what this does and does not buy: installing from a release URL does NOT
  # add a repo, so NOTHING upgrades carapace afterwards. Not `zypper dup`, not `up`, not
  # maint, and not a later bootstrap either — the `command -v carapace` guard below skips
  # the whole block once the binary exists. Upstream ships no zypper repo and openSUSE does
  # not package it, so there is no upgrade source to point at; updating is a deliberate
  # manual step, and `carapace --version` is how you would know you are behind. That is the
  # real cost, and it is still the right route: `go install` cannot work at all, so the
  # choice is a manually-updated binary or no carapace.
  #
  # Resolve the newest asset for THIS arch with grep/cut (no jq dependency) rather than
  # pinning a version that would rot. Mirrors dotfiles-Fedora/bootstrap.sh — port fixes both
  # ways. A future change wanting a real trust anchor would pin the version and verify a
  # SHA-256 recorded in THIS tree (the scripts/tool-versions.env shape); upstream's own
  # checksums.txt is unsigned and same-origin, so it catches corruption, not compromise.
  if ! command -v carapace >/dev/null; then
    blib_say "carapace (upstream RPM — go install is impossible, see above)"
    local _cara_arch=""
    case "$(uname -m)" in
    x86_64) _cara_arch=amd64 ;;
    aarch64) _cara_arch=arm64 ;;
    esac
    if [[ -z "$_cara_arch" ]]; then
      _note_fail "carapace: no upstream RPM for $(uname -m) — skipping; see github.com/carapace-sh/carapace-bin/releases"
    else
      local _cara_url=""
      _cara_url="$(curl -fsSL --max-time 30 \
        https://api.github.com/repos/carapace-sh/carapace-bin/releases/latest 2>/dev/null |
        grep -o "\"browser_download_url\": *\"[^\"]*linux_${_cara_arch}\.rpm\"" |
        cut -d'"' -f4 | head -1)" || true
      if [[ -n "$_cara_url" ]]; then
        if ((IS_TRANSACTIONAL)); then
          # a global zypper option (--no-gpg-checks) cannot ride `pkg in`; `run` executes
          # the whole zypper command inside the new snapshot instead
          if _priv transactional-update -n --no-selfupdate --continue run zypper --non-interactive --no-gpg-checks install --allow-unsigned-rpm "$_cara_url" >/dev/null; then
            TU_STAGED=$((TU_STAGED + 1))
          else
            _note_fail "carapace: RPM transaction failed — retry later: ${BLIB_SU-sudo} transactional-update -n --continue run zypper -n --no-gpg-checks install --allow-unsigned-rpm $_cara_url"
          fi
        else
          _priv zypper --non-interactive --no-gpg-checks install --allow-unsigned-rpm "$_cara_url" >/dev/null ||
            _note_fail "carapace: RPM install failed — retry later: ${BLIB_SU-sudo} zypper -n --no-gpg-checks install --allow-unsigned-rpm $_cara_url"
        fi
      else
        _note_fail "carapace: could not resolve the latest linux_${_cara_arch} RPM (offline? API rate-limited?) — see github.com/carapace-sh/carapace-bin/releases"
      fi
    fi
  fi

  # yq: mikefarah's Go build (jq-for-YAML). PACKAGED as of #113 — repo-oss `yq` is the
  # Go build itself (4.53.3 on Tumbleweed and Leap 16.x), and kislyuk's Python yq ships
  # under its own name (`python313-yq`), so install/packages.txt carries `yq` and this
  # block is now the FALLBACK for a box where zypper skipped the name.
  # It stays hand-rolled rather than going through _dotfiles_go_install because that
  # helper's `command -v yq` guard cannot tell the two tools apart: on a distro where
  # the wrong yq is what `yq` resolves to, it would skip and leave it in place. The
  # signature guard below is what makes this correct either way — it matches the
  # mikefarah string in `yq --version`, so the packaged Go build satisfies it and this
  # is a clean no-op, while a foreign `yq` on PATH does not and gets overridden from
  # ~/.local/bin (which the shell layer puts ahead of /usr/bin). Never aborts the run.
  if [ ! -x "$HOME/.local/bin/yq" ] && ! yq --version 2>/dev/null | grep -qi mikefarah; then
    local yqbin="$HOME/.local/bin"
    local yqpath="github.com/mikefarah/yq/v4@latest"
    mkdir -p "$yqbin" 2>/dev/null || true
    blib_say "yq (mikefarah Go build)"
    if command -v go >/dev/null 2>&1; then
      GOBIN="$yqbin" go install "$yqpath" >/dev/null 2>&1 ||
        _note_fail "yq — go install failed; retry: GOBIN=$yqbin go install $yqpath"
    elif command -v mise >/dev/null 2>&1; then
      GOBIN="$yqbin" mise exec go@latest -- go install "$yqpath" >/dev/null 2>&1 ||
        _note_fail "yq — go install failed; retry: GOBIN=$yqbin go install $yqpath"
    else
      _note_fail "yq — needs a Go toolchain; install Go then: GOBIN=$yqbin go install $yqpath"
    fi
  fi

  # op (1Password CLI) — from 1Password's official signed rpm repo.
  #
  # The explicit `rpm --import` of 1Password's pinned key is the ONLY thing that makes
  # the repo's --gpgcheck meaningful. It used to be `|| true`, and the refresh that
  # followed carried --gpg-auto-import-keys — so a FAILED key import fell through to a
  # step that imported whatever key the repo happened to serve, unverified. That is
  # exactly the case where auto-import must not run. Now the import gates the block,
  # and the refresh no longer auto-imports.
  if ! command -v op >/dev/null 2>&1; then
    blib_say "op (1Password CLI, official signed repo)"
    # The rpmdb is read-only on the running snapshot ("can't create transaction lock on
    # /usr/lib/sysimage/rpm/.rpm.lock" — measured); import inside the pending snapshot.
    local -a _op_import=(rpm --import https://downloads.1password.com/linux/keys/1password.asc)
    ((IS_TRANSACTIONAL)) && _op_import=(transactional-update -n --no-selfupdate --continue run "${_op_import[@]}")
    if ! _priv "${_op_import[@]}"; then
      _note_fail "op — 1Password signing key import failed; repo NOT added (refusing to trust an unverified key). See https://developer.1password.com/docs/cli/get-started/"
    else
      # NOTE: $basearch stays LITERAL — zypper expands it itself, so it MUST be
      # single-quoted here. Suppression is inline rather than in .shellcheckrc because
      # it is a fact about this one line, not a global truth (Core's CONTRIBUTING.md
      # makes the same call for its intentional SC2016s).
      # shellcheck disable=SC2016
      _priv zypper --non-interactive addrepo --refresh --gpgcheck \
        'https://downloads.1password.com/linux/rpm/stable/$basearch' 1password || true
      if zypper_retry --non-interactive refresh 1password; then
        if ((IS_TRANSACTIONAL)); then
          if _priv transactional-update -n --no-selfupdate --continue pkg in --no-recommends 1password-cli; then
            TU_STAGED=$((TU_STAGED + 1))
          else
            _note_fail "op — transaction failed; see https://developer.1password.com/docs/cli/get-started/"
          fi
        else
          _priv zypper --non-interactive install --no-recommends 1password-cli ||
            _note_fail "op — install failed; see https://developer.1password.com/docs/cli/get-started/"
        fi
      else
        _note_fail "op — 1password repo refresh failed; see https://developer.1password.com/docs/cli/get-started/"
      fi
    fi
  fi

  # ── WSL: install /etc/wsl.conf (systemd + default user + interop) ───────────
  if ((IS_WSL)); then
    blib_say "installing /etc/wsl.conf (systemd + default user)"
    local user rendered backup
    user="$(id -un)"
    # Render via _render_placeholder. EVERY obvious approach here is wrong for a
    # username containing metacharacters, because they all give the REPLACEMENT string
    # its own syntax:
    #   sed s/__WSL_USER__/$u/      — & means the match, / ends the expression
    #   awk gsub(/…/, u)            — & means the match, \ escapes
    #   ${text//__WSL_USER__/$u}    — bash >= 5.2 also expands & to the match
    # Verified experimentally; the bash one in particular is a 5.2 behaviour change, so
    # it is silently version-dependent. _render_placeholder uses only prefix/suffix
    # removal, which has no replacement syntax at all, so the value is always literal.
    rendered="$(_render_placeholder "$(<"$DOTFILES/wsl/wsl.conf")" '__WSL_USER__' "$user")"
    # Every other file this bootstrap touches goes through blib_link/blib_seed, which
    # back up first. This path used to `tee` straight over /etc/wsl.conf, destroying
    # any hand-tuned [network]/[boot]/mount settings with no backup and no diff.
    # Compared in pure bash rather than with diff/cmp: those come from diffutils, which
    # is NOT in install/packages.txt and is absent from minimal openSUSE images (the
    # exact fresh-machine case this path exists for). Both sides go through $(<…), which
    # strips trailing newlines identically, so the comparison is apples-to-apples.
    if [[ -f /etc/wsl.conf ]] && [[ "$(</etc/wsl.conf)" != "$rendered" ]]; then
      backup="/etc/wsl.conf.pre-dotfiles.$(date +%Y%m%d%H%M%S)"
      blib_warn "existing /etc/wsl.conf differs — backing up to $backup"
      _priv cp -a /etc/wsl.conf "$backup"
    fi
    printf '%s\n' "$rendered" | _priv tee /etc/wsl.conf >/dev/null
    blib_ok "wsl.conf written — run 'wsl.exe --shutdown' from Windows, then reopen, to apply"
  fi

  if ((DO_FLATPAK)) && ! ((IS_WSL)); then
    blib_say "Flathub"
    if command -v flatpak >/dev/null 2>&1; then
      flatpak remote-add --if-not-exists flathub \
        https://flathub.org/repo/flathub.flatpakrepo >/dev/null 2>&1 ||
        _note_fail "flathub — remote-add failed; retry: flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo"
    else
      blib_warn "flatpak not installed — skipping Flathub remote"
    fi
  fi
}

# The driver never fakes bootstrap_provision under --dry-run; this report-only hook says
# what a full run would do instead.
# shellcheck disable=SC2329
bootstrap_check() {
  [[ "${BLIB_DRY:-0}" != 0 ]] || return 0
  if ((IS_TRANSACTIONAL)); then
    blib_say "(dry run) transactional edition: would transactional-update pkg in the packages from install/packages.txt into a NEW snapshot (live after a reboot), then the upstream/cargo/go tool set"
  else
    blib_say "(dry run) would provision zypper packages from install/packages.txt, then the upstream/cargo/go tool set"
  fi
}

# shellcheck disable=SC2329
bootstrap_provision() { provision; }

# shellcheck disable=SC2329
bootstrap_wire_pre_loader() {
  # ── the capability declaration's TIER ────────────────────────────────────────
  # blib_link_os_layer has just linked os/opensuse.capabilities, which is TUMBLEWEED's.
  # This repo serves Leap too, and the two upgrade with different verbs — `dup` vs `up`,
  # the mistake that half-updates a box and the reason Core carried a
  # `grep -qi tumbleweed /etc/os-release` probe inside a portable module at all.
  #
  # A declaration is DATA and cannot probe, so the choice is made HERE, by the same test
  # this script already runs above to decide which upgrade alias to advertise. That probe
  # is correct in an OS repo and wrong in Core; this is where it belongs.
  #
  # Relink rather than branch the call above: blib_link_os_layer owns the default name,
  # and overriding one destination afterwards keeps this repo out of Core's contract.
  # blib_link honours BLIB_DRY, so --dry-run reports "would relink" and changes nothing.
  if ! grep -qi tumbleweed /etc/os-release 2>/dev/null; then
    blib_say "Leap detected — using the Leap capability declaration (zypper up, unattended upgrades permitted)"
    blib_link "$DOTFILES/os/opensuse.leap.capabilities" "$CONFIG/zsh/os.capabilities"
  fi
  # The transactional edition is a Tumbleweed base (its ID_LIKE says so), so the branch
  # above keeps the `dup` declaration — and this one replaces it with the snapshot verbs.
  if ((IS_TRANSACTIONAL)); then
    blib_say "transactional edition detected — using the transactional-update capability declaration (staged install/upgrade, reboot applies)"
    blib_link "$DOTFILES/os/opensuse.microos.capabilities" "$CONFIG/zsh/os.capabilities"
  fi
}

# What only this repo knows at the end: the two hints under a non-empty tally. The driver
# prints the tally, the "finished WITH the misses above" line, and applies the exit code.
# shellcheck disable=SC2329
bootstrap_closing() {
  if ((TU_STAGED)); then
    # PKG_APPLY's value, printed and never run — the operator reboots. No leading space
    # when the escalator is empty (root): "${BLIB_SU-sudo} x" would print "( x)".
    local _su="${BLIB_SU-sudo}"
    blib_warn "$TU_STAGED package(s) transacted into the next snapshot — reboot to apply (${_su:+$_su }systemctl reboot), then re-run ./bootstrap.sh once so the cargo/go tools build against the new snapshot's toolchain"
  fi
  if (($1)); then
    blib_warn "the rest of the box is wired and usable"
    if ((BOOTSTRAP_STRICT_DEFAULT)); then
      blib_warn "re-run ./bootstrap.sh after fixing the above, or run the printed commands by hand"
    else
      blib_warn "--tolerate-failures set — exiting 0 anyway"
    fi
  fi
  return 0
}

blib_main "$@"
