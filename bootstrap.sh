#!/usr/bin/env bash
# dotfiles-openSUSE/bootstrap.sh
# ──────────────────────────────────────────────────────────────────────────────
# Provision an openSUSE box (Tumbleweed or Leap; Workstation or WSL) and wire up
# dotfiles. Idempotent — safe to re-run. This is the OS-NATIVE layer; Core
# (zsh/tmux/nvim/git) is vendored under core/ and symlinked via core/lib/bootstrap-lib.sh.
#
# Usage:
#   ./bootstrap.sh                 # full: zypper packages + extras + symlinks
#   ./bootstrap.sh --links-only    # just (re)create symlinks
#   ./bootstrap.sh --no-flatpak    # skip Flathub/GUI apps (recommended on WSL)
#   ./bootstrap.sh --only zsh,nvim # link ONLY these Core module groups
#   ./bootstrap.sh --skip tmux     # link everything EXCEPT these groups
#
# Module groups (for --only/--skip): zsh nvim tmux git prompt tools — they affect
# the wiring steps only, never package provisioning; combine with --links-only to
# re-wire a subset of configs without touching zypper.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
LINKS_ONLY=0
DO_FLATPAK=1
# --only/--skip are validated by the shared lib (blib_select), which is sourced
# AFTER this loop — so capture the raw values now and apply them below.
ONLY_RAW="" SKIP_RAW="" ONLY_SEEN=0 SKIP_SEEN=0

while [[ $# -gt 0 ]]; do case "$1" in
  --links-only) LINKS_ONLY=1 ;;
  --no-flatpak) DO_FLATPAK=0 ;;
  --only) [[ $# -ge 2 ]] || { echo "--only requires module names, e.g. --only zsh,nvim" >&2; exit 1; }; ONLY_RAW="$2"; ONLY_SEEN=1; shift ;;
  --only=*) ONLY_RAW="${1#*=}"; ONLY_SEEN=1 ;;
  --skip) [[ $# -ge 2 ]] || { echo "--skip requires module names, e.g. --skip tmux" >&2; exit 1; }; SKIP_RAW="$2"; SKIP_SEEN=1; shift ;;
  --skip=*) SKIP_RAW="${1#*=}"; SKIP_SEEN=1 ;;
  -h | --help)
    sed -n '2,17p' "$0"
    exit 0
    ;;
  *)
    echo "unknown arg: $1" >&2
    exit 1
    ;;
  esac; shift; done

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

# Apply any --only/--skip module selection now the validator (blib_select) exists;
# it aborts on a malformed selector or an unknown group.
if ((ONLY_SEEN)); then blib_select --only "$ONLY_RAW"; fi
if ((SKIP_SEEN)); then blib_select --skip "$SKIP_RAW"; fi

# ── sanity: confirm we're on openSUSE (matches Tumbleweed AND Leap) ───────────
if ! grep -qi opensuse /etc/os-release 2>/dev/null; then
  echo "This bootstrap targets openSUSE. /etc/os-release doesn't look like openSUSE." >&2
  exit 1
fi

IS_WSL=0
if blib_is_wsl; then IS_WSL=1; fi

# ── resilient install: zypper aborts the WHOLE transaction on one unknown pkg
# (exit 104 = capability not found). Bulk first, then per-package. ──────────────
zypper_install() {
  local -a pkgs=("$@")
  if sudo zypper --non-interactive install --no-recommends "${pkgs[@]}"; then return 0; fi
  blib_say "bulk install hit a snag — retrying package-by-package"
  local p
  for p in "${pkgs[@]}"; do
    sudo zypper --non-interactive install --no-recommends "$p" ||
      echo "   skipped (unavailable on this box?): $p"
  done
}

# Best-effort `go install` for tools not packaged on openSUSE. Presence-guarded
# (skips if the binary already exists), tolerant of a missing Go toolchain, and
# never aborts the run.
_dotfiles_go_install() { # <import-path@version> <binary-name>
  [ "$#" -ge 2 ] || return 0
  if command -v "$2" >/dev/null 2>&1; then return 0; fi
  # `go install` defaults to ~/go/bin, which is NOT on the shell PATH (the shell
  # layer prefixes ~/.local/bin and ~/.cargo/bin). Force GOBIN into ~/.local/bin.
  local gobin="$HOME/.local/bin"
  mkdir -p "$gobin" 2>/dev/null || true
  if command -v go >/dev/null 2>&1; then
    GOBIN="$gobin" go install "$1" >/dev/null 2>&1 ||
      echo "   $2: go install failed — retry later: GOBIN=$gobin go install $1"
  elif command -v mise >/dev/null 2>&1; then
    GOBIN="$gobin" mise exec go@latest -- go install "$1" >/dev/null 2>&1 ||
      echo "   $2: go install failed — retry later: GOBIN=$gobin go install $1"
  else
    echo "   $2: needs Go — install later with: GOBIN=$gobin go install $1"
  fi
  return 0
}

provision() {
  blib_say "zypper refresh (metadata)"
  sudo zypper --non-interactive --gpg-auto-import-keys refresh

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
  local -a pkgs=()
  mapfile -t pkgs < <(blib_read_pkgs "$DOTFILES/install/packages.txt")
  # Guard the empty case: an all-comment/blank packages.txt yields a zero-length
  # array. zypper_install wraps `zypper install` in `if …; then` (errexit-exempt),
  # so an empty list wouldn't abort — but it WOULD run zypper with no args, trip
  # the "bulk install hit a snag" per-package fallback, and then log a misleading
  # "0 requested" success. Skip the install instead and carry on.
  if ((${#pkgs[@]})); then
    zypper_install "${pkgs[@]}"
    blib_ok "zypper packages requested: ${#pkgs[@]}"
  else
    blib_warn "install/packages.txt lists no packages — skipping zypper install"
  fi

  # Upstream installs, presence-guarded: Tumbleweed packages starship/atuin/yazi/viddy,
  # but we take the upstream-latest build here to match the other repos. Each check
  # below short-circuits if the binary is already on PATH, so packaging one is harmless.
  if ! command -v starship >/dev/null; then
    blib_say "starship (official installer)"
    curl -fsSL https://starship.rs/install.sh | sh -s -- -y >/dev/null || true
  fi
  if ! command -v atuin >/dev/null; then
    blib_say "atuin (official installer)"
    curl -fsSL https://setup.atuin.sh | sh >/dev/null 2>&1 || true
  fi
  if ! command -v yazi >/dev/null && command -v cargo >/dev/null; then
    blib_say "yazi (cargo)"
    cargo install --locked yazi-fs yazi-cli >/dev/null 2>&1 || true
  fi
  # mise — polyglot runtime manager; activated in core/zsh/00-tools.zsh. Runtimes are
  # fetched separately with `mise install` (kept out of bootstrap).
  if ! command -v mise >/dev/null && [[ ! -x "$HOME/.local/bin/mise" ]]; then
    blib_say "mise (official installer)"
    curl -fsSL https://mise.run | sh >/dev/null 2>&1 || true
  fi
  # tree-sitter-cli — NOT in openSUSE repos; nvim-treesitter (main) compiles
  # parsers locally and needs the CLI (>=0.26.1). Build via cargo, or swap to
  # `mise use -g tree-sitter`.
  if ! command -v tree-sitter >/dev/null && command -v cargo >/dev/null; then
    blib_say "tree-sitter-cli (cargo)"
    cargo install --locked tree-sitter-cli >/dev/null 2>&1 ||
      echo "   tree-sitter-cli build failed; do it later: cargo install tree-sitter-cli (or mise use -g tree-sitter)"
  fi
  # viddy (watch replacement; Core aliases watch->viddy, HAVE_VIDDY-guarded) is a Rust
  # CLI. Tumbleweed's repo-oss does package it, but we cargo-build for the upstream-latest
  # version — the guard below skips this if a package already put it on PATH.
  if ! command -v viddy >/dev/null && command -v cargo >/dev/null; then
    blib_say "viddy (cargo — watch replacement)"
    cargo install --locked viddy >/dev/null 2>&1 || true
  fi

  # ── go/vendor tools from the core-doctor set ─────────────────────────────────
  # carapace and sesh are genuinely absent from the openSUSE repos; doggo IS in
  # Tumbleweed's repo-oss, but is go-installed here for the same upstream-latest
  # reason as the block above. Each is presence-guarded and best-effort; a missing
  # Go toolchain just logs a hint. sesh REQUIRES the /v2 module path.
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
    mkdir -p "$yqbin" 2>/dev/null || true
    blib_say "yq (mikefarah Go build)"
    if command -v go >/dev/null 2>&1; then
      GOBIN="$yqbin" go install github.com/mikefarah/yq/v4@latest >/dev/null 2>&1 ||
        echo "   yq: go install failed — retry later: GOBIN=$yqbin go install github.com/mikefarah/yq/v4@latest"
    elif command -v mise >/dev/null 2>&1; then
      GOBIN="$yqbin" mise exec go@latest -- go install github.com/mikefarah/yq/v4@latest >/dev/null 2>&1 ||
        echo "   yq: go install failed — retry later: GOBIN=$yqbin go install github.com/mikefarah/yq/v4@latest"
    else
      echo "   yq: needs Go — install later with: GOBIN=$yqbin go install github.com/mikefarah/yq/v4@latest"
    fi
  fi

  # op (1Password CLI) — from 1Password's official signed rpm repo. Guarded on the
  # binary; every step is `|| true`-tolerant so a repo/network hiccup never aborts.
  if ! command -v op >/dev/null 2>&1; then
    blib_say "op (1Password CLI, official signed repo)"
    sudo rpm --import https://downloads.1password.com/linux/keys/1password.asc || true
    # NOTE: $basearch stays LITERAL — zypper expands it, so single-quote it here.
    sudo zypper --non-interactive addrepo --refresh --gpgcheck \
      'https://downloads.1password.com/linux/rpm/stable/$basearch' 1password || true
    sudo zypper --non-interactive --gpg-auto-import-keys refresh 1password || true
    sudo zypper --non-interactive install --no-recommends 1password-cli ||
      echo "   op: install failed — see https://developer.1password.com/docs/cli/get-started/"
  fi

  # ── WSL: install /etc/wsl.conf (systemd + default user + interop) ───────────
  if ((IS_WSL)); then
    blib_say "installing /etc/wsl.conf (systemd + default user)"
    local user
    user="$(id -un)"
    sed "s/__WSL_USER__/$user/" "$DOTFILES/wsl/wsl.conf" | sudo tee /etc/wsl.conf >/dev/null
    blib_ok "wsl.conf written — run 'wsl.exe --shutdown' from Windows, then reopen, to apply"
  fi

  if ((DO_FLATPAK)) && ! ((IS_WSL)); then
    blib_say "Flathub"
    flatpak remote-add --if-not-exists flathub \
      https://flathub.org/repo/flathub.flatpakrepo >/dev/null 2>&1 || true
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
  blib_ok "symlinks wired$(blib_selected_note)"
}

((LINKS_ONLY)) || provision
wire_links
blib_ok "openSUSE bootstrap complete — open a new shell or: exec zsh"
