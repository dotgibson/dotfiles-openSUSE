#!/usr/bin/env bash
# dotfiles-openSUSE/bootstrap.sh
# ──────────────────────────────────────────────────────────────────────────────
# Provision an openSUSE box (Tumbleweed or Leap; Workstation or WSL) and wire up
# dotfiles. Idempotent — safe to re-run. This is the OS-NATIVE layer; Core
# (zsh/tmux/nvim/git) is vendored under core/ and symlinked via core/lib/bootstrap-lib.sh.
#
# Run `./bootstrap.sh --help` for usage. That text lives in usage() below rather than
# in this header: the previous `sed -n '2,17p' "$0"` coupled --help to this comment
# block's exact line numbers, so any edit up here silently truncated the help output.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./bootstrap.sh                     # full: zypper packages + extras + symlinks
  ./bootstrap.sh --links-only        # just (re)create symlinks (no zypper)
  ./bootstrap.sh --dry-run           # preview every change; mutate nothing
  ./bootstrap.sh --no-flatpak        # skip the Flathub remote (auto-skipped on WSL)
  ./bootstrap.sh --only zsh,nvim     # link ONLY these Core module groups
  ./bootstrap.sh --skip tmux         # link everything EXCEPT these groups
  ./bootstrap.sh --tolerate-failures # exit 0 even if optional tools failed (for CI)

Module groups (for --only/--skip): zsh nvim tmux git prompt tools
  They affect the WIRING steps only, never package provisioning. Combine with
  --links-only to re-wire a subset of configs without touching zypper.
  --only and --skip are mutually exclusive.

Exit codes:
  0  everything requested succeeded
  1  bad arguments, or a precondition failed (not openSUSE, core/ missing,
     packages.txt unreadable, no way to escalate privileges)
  2  bootstrap completed but one or more OPTIONAL tools failed to install; the
     failure ledger is printed at the end with a retry hint for each

Environment:
  BLIB_SU   privilege escalator; defaults to `sudo`. Set BLIB_SU="" when already
            root (minimal containers often have no sudo), or BLIB_SU=doas.
  BLIB_DRY  set by --dry-run; makes the Core link helpers plan-only.
EOF
}

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
LINKS_ONLY=0
DO_FLATPAK=1
DRY_RUN=0
TOLERATE=0
# --only/--skip are validated by the shared lib (blib_select), which is sourced
# AFTER this loop — so capture the raw values now and apply them below.
ONLY_RAW="" SKIP_RAW="" ONLY_SEEN=0 SKIP_SEEN=0

while [[ $# -gt 0 ]]; do case "$1" in
  --links-only) LINKS_ONLY=1 ;;
  --no-flatpak) DO_FLATPAK=0 ;;
  --dry-run) DRY_RUN=1 ;;
  --tolerate-failures) TOLERATE=1 ;;
  --only) [[ $# -ge 2 ]] || { echo "--only requires module names, e.g. --only zsh,nvim" >&2; exit 1; }; ONLY_RAW="$2"; ONLY_SEEN=1; shift ;;
  --only=*) ONLY_RAW="${1#*=}"; ONLY_SEEN=1 ;;
  --skip) [[ $# -ge 2 ]] || { echo "--skip requires module names, e.g. --skip tmux" >&2; exit 1; }; SKIP_RAW="$2"; SKIP_SEEN=1; shift ;;
  --skip=*) SKIP_RAW="${1#*=}"; SKIP_SEEN=1 ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "unknown arg: $1" >&2
    echo "try: ./bootstrap.sh --help" >&2
    exit 1
    ;;
  esac; shift; done

# --only and --skip describe the same selection from opposite ends; applying both
# leaves the resulting module set undefined at this layer. Reject rather than guess.
if ((ONLY_SEEN && SKIP_SEEN)); then
  echo "--only and --skip are mutually exclusive — pick one" >&2
  exit 1
fi

# ── core/ subtree present? (inline: can't source a lib out of core/ before this) ─
# Validate the SPECIFIC paths we depend on (zsh modules + the two libs sourced
# next) so a missing/partial subtree fails HERE with a precise message, not later
# with a cryptic `source: No such file`.
for _req in core/zsh/loader.zsh core/lib/ux.sh core/lib/bootstrap-lib.sh; do
  if [[ ! -e "$DOTFILES/$_req" ]]; then
    echo "core/ subtree missing or incomplete (need $_req). One-time, run:" >&2
    echo "  git subtree add  --prefix=core <dotfiles-core remote> main --squash   # first time" >&2
    echo "  git subtree pull --prefix=core <dotfiles-core remote> main --squash   # to update" >&2
    exit 1
  fi
done
unset _req

# Shared bash UX palette + provisioning scaffold (vendored under core/lib).
# shellcheck source=core/lib/ux.sh
source "$DOTFILES/core/lib/ux.sh"
# shellcheck source=core/lib/bootstrap-lib.sh
source "$DOTFILES/core/lib/bootstrap-lib.sh"

# --dry-run: BLIB_DRY makes the Core link helpers (blib_link/blib_seed/…) print their
# plan and change nothing. It does NOT cover zypper — package provisioning is gated
# separately in main() so a preview never touches the system.
if ((DRY_RUN)); then export BLIB_DRY=1; fi

# Apply any --only/--skip module selection now the validator (blib_select) exists;
# it aborts on a malformed selector or an unknown group.
if ((ONLY_SEEN)); then blib_select --only "$ONLY_RAW"; fi
if ((SKIP_SEEN)); then blib_select --skip "$SKIP_RAW"; fi

# ── failure ledger ────────────────────────────────────────────────────────────
# Package/tool installs here are deliberately best-effort: one unavailable crate must
# not abort a 5-minute provision. But "best-effort" previously meant `|| true`, so a
# run that lost doggo, carapace, sesh, yq, op AND half of packages.txt still printed
# "bootstrap complete" and exited 0 — the operator had no signal at all. Record every
# soft failure here instead, print them together at the end, and exit 2 so a caller
# (or CI) can tell a clean install from a lossy one.
BOOTSTRAP_FAILED=()
_note_fail() { BOOTSTRAP_FAILED+=("$1"); }

_report_failures() {
  ((${#BOOTSTRAP_FAILED[@]})) || return 0
  printf '\n'
  blib_warn "${#BOOTSTRAP_FAILED[@]} item(s) did not install — the rest of the box is wired and usable:"
  local f
  for f in "${BOOTSTRAP_FAILED[@]}"; do printf '   - %s\n' "$f" >&2; done
  printf '\n' >&2
  if ((TOLERATE)); then
    blib_warn "--tolerate-failures set — exiting 0 anyway"
    return 0
  fi
  blib_warn "re-run ./bootstrap.sh after fixing the above, or run the printed commands by hand"
  return 2
}

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

# Fail fast and precisely if we cannot escalate, rather than dying mid-provision.
_priv_preflight() {
  local su="${BLIB_SU-sudo}"
  [[ -z "$su" ]] && return 0                 # explicitly root
  if command -v "$su" >/dev/null 2>&1; then
    # Prime the credential cache once up front. The cargo builds below can take many
    # minutes, and a sudo timestamp expiring mid-run turns an unattended provision
    # into one silently blocked on a password prompt.
    # Written as an explicit `if` rather than `[[ … ]] && sudo -v || true`: that form is
    # the SC2015 A&&B||C antipattern, where C also runs when A is true.
    if [[ "$su" == sudo ]]; then
      sudo -v 2>/dev/null || true
    fi
    return 0
  fi
  if ((EUID == 0)); then
    echo "'$su' not found, but running as root — re-run with BLIB_SU=\"\" to skip escalation" >&2
    exit 1
  fi
  echo "'$su' not found and not running as root. Install sudo, run as root with BLIB_SU=\"\"," >&2
  echo "or set BLIB_SU to your escalator (e.g. BLIB_SU=doas ./bootstrap.sh)." >&2
  exit 1
}

# ── sanity: confirm we're on openSUSE (matches Tumbleweed AND Leap) ───────────
if ! grep -qi opensuse /etc/os-release 2>/dev/null; then
  echo "This bootstrap targets openSUSE. /etc/os-release doesn't look like openSUSE." >&2
  exit 1
fi

IS_WSL=0
if blib_is_wsl; then IS_WSL=1; fi

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
_dotfiles_go_install() { # <import-path@version> <binary-name>
  [ "$#" -ge 2 ] || return 0
  if command -v "$2" >/dev/null 2>&1; then return 0; fi
  # `go install` defaults to ~/go/bin, which is NOT on the shell PATH (the shell
  # layer prefixes ~/.local/bin and ~/.cargo/bin). Force GOBIN into ~/.local/bin.
  local gobin="$HOME/.local/bin"
  mkdir -p "$gobin" 2>/dev/null || true
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
  if grep -qi tumbleweed /etc/os-release; then
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
  # `yazi-build` is the ONLY crate that installs yazi from crates.io. This block previously
  # asked for `yazi-fs`, which is a library crate (no [[bin]]) and can never produce the
  # `yazi` binary the guard tests for — so the guard stayed false forever and every bootstrap
  # rebuilt the whole yazi workspace (a hundred-plus crates) only to discard it. `yazi-fm` is
  # not the fix either: yazi-cli's build.rs panics on purpose telling you to use
  # `cargo install --force yazi-build`. --force is upstream's own instruction. Dropping the
  # output silencing too: a multi-minute doomed rebuild looked exactly like a hang.
  # (Matches dotfiles-Fedora/bootstrap.sh, which documents this at length.)
  #
  # The guard checks ~/.cargo/bin/yazi as well as PATH, and that second test is what makes
  # --force safe: `provision` runs BEFORE `wire_links`, so ~/.cargo/bin is not on this shell's
  # PATH yet (the zsh layer is what prefixes it). On PATH alone, a box that already built yazi
  # here would fail `command -v` and --force would rebuild it from source on EVERY bootstrap.
  # Same two-part guard dotfiles-Kali already uses.
  if ! command -v yazi >/dev/null && [[ ! -x "$HOME/.cargo/bin/yazi" ]] && command -v cargo >/dev/null; then
    blib_say "yazi (cargo build from source — several minutes, output below)"
    cargo install --force --locked yazi-build ||
      _note_fail "yazi — cargo build failed; retry: cargo install --force --locked yazi-build"
  fi
  # mise — polyglot runtime manager; activated in core/zsh/00-tools.zsh. Runtimes are
  # fetched separately with `mise install` (kept out of bootstrap). No OSS package
  # exists, so mise.run stays the primary path — but its output is no longer discarded.
  if ! command -v mise >/dev/null && [[ ! -x "$HOME/.local/bin/mise" ]]; then
    blib_say "mise (official installer — not packaged on openSUSE)"
    curl -fsSL https://mise.run | sh >/dev/null ||
      _note_fail "mise — installer failed; retry: curl -fsSL https://mise.run | sh"
  fi
  # tree-sitter-cli — NOT in openSUSE repos; nvim-treesitter (main) compiles
  # parsers locally and needs the CLI (>=0.26.1). Build via cargo, or swap to
  # `mise use -g tree-sitter`.
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

  # ── go/vendor tools from the core-doctor set ─────────────────────────────────
  # carapace and sesh are genuinely absent from the openSUSE repos; doggo IS in
  # Tumbleweed's repo-oss, but is go-installed here for the same upstream-latest
  # reason as the block above. Each is presence-guarded and best-effort; a missing
  # Go toolchain is now recorded in the ledger rather than only echoed. sesh REQUIRES
  # the /v2 module path.
  blib_say "go tools (doggo, carapace, sesh)"
  _dotfiles_go_install github.com/mr-karan/doggo/cmd/doggo@latest doggo
  _dotfiles_go_install github.com/carapace-sh/carapace-bin/cmd/carapace@latest carapace
  _dotfiles_go_install github.com/joshmedeski/sesh/v2@latest sesh

  # yq: mikefarah's Go build (jq-for-YAML). Deliberately NOT via _dotfiles_go_install:
  # its `command -v yq` guard would be satisfied by kislyuk's python-yq — a DIFFERENT
  # tool that also ships a `yq` binary — and skip, leaving the wrong yq in place. Guard
  # instead on our own ~/.local/bin/yq plus the mikefarah signature in `yq --version`,
  # and install straight into ~/.local/bin (which the shell layer puts ahead of /usr/bin,
  # so the Go build wins over any distro python-yq). Best-effort; never aborts the run.
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
    if ! _priv rpm --import https://downloads.1password.com/linux/keys/1password.asc; then
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
        _priv zypper --non-interactive install --no-recommends 1password-cli ||
          _note_fail "op — install failed; see https://developer.1password.com/docs/cli/get-started/"
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

wire_links() {
  # The shared symlink surface + the openSUSE OS overlays + the managed .zshrc
  # loader + the default-login-shell switch all live in core/lib/bootstrap-lib.sh.
  blib_link_core "$DOTFILES" "$CONFIG"
  blib_link_os_layer "$DOTFILES" "$CONFIG" opensuse
  # shellcheck disable=SC2119  # no args is intentional — writes the default module set
  blib_write_zshrc_loader
  blib_set_login_shell
  # Core's own tally (N linked · M seeded · K backed up · J skipped), which prefixes
  # "(dry run)" automatically under BLIB_DRY. Replaces a hand-rolled one-liner that
  # reported nothing about what actually changed.
  blib_wire_summary
  blib_ok "symlinks wired$(blib_selected_note)"
}

main() {
  if ((DRY_RUN)); then
    blib_warn "DRY RUN — no packages will be installed and no files will be written"
  fi

  if ((LINKS_ONLY)); then
    # wsl.conf lives in provision(), so a links-only run on WSL leaves systemd off.
    # Core's 55-maint.zsh gates its systemd user timer on /run/systemd/system, so the
    # maintenance timer would silently never install. Say so rather than let it be a
    # mystery months later.
    if ((IS_WSL)) && [[ ! -f /etc/wsl.conf ]]; then
      blib_warn "--links-only skips /etc/wsl.conf; without it WSL has no systemd and Core's maintenance timer won't install. Run a full bootstrap once."
    fi
  elif ((DRY_RUN)); then
    blib_say "(dry run) would provision zypper packages from install/packages.txt, then the upstream/cargo/go tool set"
  else
    _priv_preflight
    provision
  fi

  wire_links

  local rc=0
  _report_failures || rc=$?
  if ((rc == 0)); then
    blib_ok "openSUSE bootstrap complete — open a new shell or: exec zsh"
  else
    blib_warn "openSUSE bootstrap finished WITH FAILURES (see above) — shell is still usable: exec zsh"
  fi
  return "$rc"
}

main "$@"
