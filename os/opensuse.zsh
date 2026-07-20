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

# ── Detect WSL once (for the niceties below) ──────────────────────────────────
_IS_WSL=0
if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
  _IS_WSL=1
elif [[ -r /proc/version ]]; then
  # zsh reads the file directly (no grep/cat fork) — WSL kernels tag /proc/version.
  _pv="$(</proc/version)"; _pv=${_pv:l}
  [[ "$_pv" == *microsoft* || "$_pv" == *wsl* ]] && _IS_WSL=1
  unset _pv
fi

# ── Clipboard: delegate to Core's cross-OS scripts (single implementation) ────
command -v clip       >/dev/null && alias pbcopy='clip'
command -v clip-paste >/dev/null && alias pbpaste='clip-paste'

# ── tool completions / shell hooks (parity with the Mac/Fedora os layers) ────
# direnv/gh/uv/ty emit DETERMINISTIC scripts (the generated hook/completion TEXT is static
# for a given binary; only the runtime hooks vary per-dir/-shell), so route them through
# Core's _cache_eval (00-tools.zsh) — one cheap `source` of a cached file instead of forking
# each generator on EVERY interactive shell. _cache_eval self-guards on the binary being
# present and regenerates only when it's newer than the cache. Falls back to the eager
# eval if this OS layer is sourced without Core's 00-tools.zsh — the fallback
# keeps direnv's stderr visible, while the cached path suppresses the generator's
# stderr (as _cache_eval does); direnv's per-dir runtime warnings are unaffected.
if (( $+functions[_cache_eval] )); then
  _cache_eval direnv direnv hook zsh
  _cache_eval gh gh completion -s zsh
  _cache_eval uv uv generate-shell-completion zsh
  _cache_eval ty ty generate-shell-completion zsh
else
  command -v direnv >/dev/null 2>&1 && eval "$(direnv hook zsh)"
  command -v gh >/dev/null 2>&1 && eval "$(gh completion -s zsh 2>/dev/null)"
  command -v uv >/dev/null 2>&1 && eval "$(uv generate-shell-completion zsh 2>/dev/null)"
  command -v ty >/dev/null 2>&1 && eval "$(ty generate-shell-completion zsh 2>/dev/null)"
fi

# ── conveniences ──────────────────────────────────────────────────────────────
alias dotsync='cd "$HOME/dotfiles-openSUSE"'            # jump to this repo
command -v op >/dev/null 2>&1 && alias opsignin='eval "$(op signin)"'
alias localip='ip -brief -4 addr show scope global'     # iface + LAN IP(s)

# ── WSL-only niceties (interop reach-arounds into Windows) ───────────────────
if (( _IS_WSL )); then
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

unset _IS_WSL

# ── auto-start/attach tmux for interactive terminals ─────────────────────────
# Skip inside an existing tmux, VS Code's integrated terminal, and non-TTYs.
if command -v tmux >/dev/null 2>&1 \
   && [[ -z "$TMUX" && -t 1 && "$TERM_PROGRAM" != "vscode" ]]; then
  tmux attach -t main 2>/dev/null || tmux new-session -s main
fi
