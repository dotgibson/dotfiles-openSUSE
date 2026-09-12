# dotfiles-openSUSE/os/opensuse.zsh
# ──────────────────────────────────────────────────────────────────────────────
# The openSUSE OS-native shell layer. Symlinked to ~/.config/zsh/80-os.zsh and
# loaded AFTER Core (tools/aliases/functions). openSUSE-specific only.
# Works on Tumbleweed + Leap, Desktop (Wayland/X11) AND WSL.
#
# NOTE: clipboard logic lives in Core's cross-OS `clip`/`clip-paste` scripts,
# which zsh, tmux, and nvim all share. This layer just points the pbcopy/pbpaste
# muscle-memory names at them.
# ──────────────────────────────────────────────────────────────────────────────
[[ $- == *i* ]] || return 0

# ── PATH: user-local bins first (Core's `clip` scripts + cargo tools land here)
[[ -d "$HOME/.local/bin" && ":$PATH:" != *":$HOME/.local/bin:"* ]] && export PATH="$HOME/.local/bin${PATH:+:$PATH}"
[[ -d "$HOME/.cargo/bin" && ":$PATH:" != *":$HOME/.cargo/bin:"* ]] && export PATH="$HOME/.cargo/bin${PATH:+:$PATH}"

# ── Clipboard: delegate to Core's cross-OS scripts (single implementation) ────
command -v clip       >/dev/null && alias pbcopy='clip'
command -v clip-paste >/dev/null && alias pbpaste='clip-paste'

# ── tool completions / shell hooks: Core's, not this layer's ─────────────────
# The direnv hook and the gh/uv/ty completions used to be (re)generated here, in a
# seven-repo copy of one block. They are Core's since dotfiles-core#449: the direnv hook
# runs from core/zsh/00-tools.zsh (band 00, beside the other per-directory hook inits)
# and the three completions are cached there into an fpath dir and re-asserted by
# core/zsh/45-plugins.zsh after carapace. The reusable lint workflow fails an OS layer
# that grows the block back, so nothing OS-specific is left to say about them here.

# ── conveniences ──────────────────────────────────────────────────────────────
alias dotsync='cd "$HOME/dotfiles-openSUSE"'            # jump to this repo
command -v op >/dev/null 2>&1 && alias opsignin='eval "$(op signin)"'
alias localip='ip -brief -4 addr show scope global'     # iface + LAN IP(s)

# ── WSL-only niceties (interop reach-arounds into Windows) ───────────────────
# The WSL question is Core's: _core_is_wsl (core/zsh/00-tools.zsh, band 00, deliberately
# left defined for this band) is the ONLY WSL predicate an OS layer may use — it is
# lazily memoised, so a non-WSL box pays nothing. This file used to re-derive it from
# $WSL_DISTRO_NAME and the kernel version string; the reusable lint workflow now fails
# a layer that grows its own back (dotfiles-core#449, #179).
if _core_is_wsl; then
  alias open='explorer.exe'
  command -v wslview >/dev/null && alias xdg-open='wslview'
  [[ -n "${WINHOME:-}" ]] && alias cdwin='cd "$WINHOME"'
fi

# ── openSUSE ships fd as `fd` (not fdfind) — 00-tools.zsh already resolved this. ─

# ── zypper quality-of-life ────────────────────────────────────────────────────
# The update command DIFFERS by flavor: Leap is stable (`up`), Tumbleweed is
# rolling (`dup`). Both aliases are here; use the one that matches your install.
alias zref='sudo zypper refresh'
alias zin='sudo zypper install'
alias zrm='sudo zypper remove'
alias zse='zypper search'
alias zup='sudo zypper up'                # Leap: apply stable updates
alias zdup='sudo zypper dup'              # Tumbleweed: rolling dist  upgrade
alias zwhat='zypper search --provides'    # which package provides a file/command
alias zinfo='zypper info'
alias zlr='zypper repos'                  # list configured repositories
# zypper has no `history undo` like dnf — openSUSE rolls back via Btrfs snapshots:
alias snaps='sudo snapper list'
# revert a bad change:  sudo snapper undochange <pre>..<post>   (or boot a snapshot)

# ── Flatpak helpers (mostly inert on WSL without WSLg; harmless) ─────────────
alias fpi='flatpak install flathub'
alias fpu='flatpak update'
alias fps='flatpak search'
alias fpl='flatpak list --app'

# ── AppArmor helpers ──────────────────────────────────────────────────────────
# openSUSE's default mandatory-access-control is AppArmor (NOT SELinux like
# Fedora). These come from the `apparmor-utils` package. WSL kernels usually run
# with AppArmor inactive, so they're inert there — they matter on bare-metal/VM.
alias aa-status='sudo aa-status 2>/dev/null || echo "AppArmor not active (expected on WSL)"'
alias aa-unconfined='sudo aa-unconfined'                       # network procs with no profile
aa-complain() { sudo aa-complain "${1:?usage: aa-complain <profile|program>}"; }
aa-enforce()  { sudo aa-enforce  "${1:?usage: aa-enforce <profile|program>}"; }

# ── auto-start/attach tmux for interactive terminals ─────────────────────────
# Skip inside an existing tmux, VS Code's integrated terminal, and non-TTYs.
#
# Escape hatch: export DOTFILES_NO_AUTOTMUX=1 to disable entirely. There was no opt-out
# before, which made this awkward in any interactive context where an unexpected tmux
# is wrong — a CI/container shell, a `zsh -i` from an editor or test harness, or a
# remote session where you want the bare shell.
#
# Set it in ~/.zshenv, or in the environment for a single session. NOT in
# ~/.config/zsh/99-local.zsh: the loader sources fragments in NN order, so this file
# (band 80) has already run by the time band 99 is read — the flag would be set too
# late to suppress anything.
if [[ -z "${DOTFILES_NO_AUTOTMUX:-}" ]] \
   && command -v tmux >/dev/null 2>&1 \
   && [[ -z "${TMUX:-}" && -t 1 && "${TERM_PROGRAM:-}" != "vscode" ]]; then
  tmux attach -t main 2>/dev/null || tmux new-session -s main
fi
