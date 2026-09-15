# openSUSE Aliases Cheat Sheet

OS-specific aliases from `os/opensuse.zsh`. See dotfiles-core's [`aliases.md`](https://github.com/dotgibson/dotfiles-core/blob/main/aliases.md)
for the universal aliases reference (modern CLI, git, safety nets) that applies on every machine.

> **Tumbleweed vs Leap:** Use `zdup` for Tumbleweed (rolling distribution upgrade),
> use `zup` for Leap (stable package updates). Getting this wrong causes a half-upgrade.
> **Transactional edition (MicroOS / Aeon / Kalpa):** `zypper in|rm|dup` is refused on the
> read-only root, so when the linked capability declaration says `PROVISIONER=transactional`
> the same names expand to the snapshot verbs instead (see the second table) — every one
> carries `--continue`, so a pending snapshot is never silently dropped. Nothing reboots for
> you: the change is live after `sudo systemctl reboot`, which Core's `up` and the
> shell-start nudge say.

## Package Management (zypper)

| Alias   | Expands To                                                |
| ------- | --------------------------------------------------------- |
| `zref`  | `sudo zypper refresh`                                     |
| `zin`   | `sudo zypper install`                                     |
| `zrm`   | `sudo zypper remove`                                      |
| `zse`   | `zypper search`                                           |
| `zup`   | `sudo zypper up` (Leap — stable update)                   |
| `zdup`  | `sudo zypper dup` (Tumbleweed — distribution upgrade)     |
| `zwhat` | `zypper search --provides` (what provides a file/command) |
| `zinfo` | `zypper info`                                             |
| `zlr`   | `zypper repos` (list configured repositories)             |

On the transactional edition only (the declaration linked by `bootstrap.sh` says so):

| Alias  | Expands To                                                                 |
| ------ | -------------------------------------------------------------------------- |
| `zin`  | `sudo transactional-update -n --continue pkg in` (into the next snapshot)  |
| `zrm`  | `sudo transactional-update -n --continue pkg rm`                           |
| `zdup` | `sudo transactional-update --continue dup` (a Tumbleweed base — staged)    |
| `zup`  | prints why Leap's verb has no meaning here and exits 1                     |

## Snapshots (snapper)

| Alias   | Expands To          |
| ------- | ------------------- |
| `snaps` | `sudo snapper list` |

## Flatpak

| Alias | Expands To                |
| ----- | ------------------------- |
| `fpi` | `flatpak install flathub` |
| `fpu` | `flatpak update`          |
| `fps` | `flatpak search`          |
| `fpl` | `flatpak list --app`      |

## AppArmor

| Alias / Function        | Expands To                                                                     |
| ----------------------- | ------------------------------------------------------------------------------ |
| `aa-status`             | `sudo aa-status 2>/dev/null \|\| echo "AppArmor not active (expected on WSL)"` |
| `aa-unconfined`         | `sudo aa-unconfined`                                                           |
| `aa-complain <profile>` | Set profile to complain mode (function)                                        |
| `aa-enforce <profile>`  | Set profile to enforce mode (function)                                         |

## Clipboard / WSL / Navigation

| Alias      | Expands To                            | Condition            |
| ---------- | ------------------------------------- | -------------------- |
| `pbcopy`   | `clip`                                | clip available       |
| `pbpaste`  | `clip-paste`                          | clip-paste available |
| `dotsync`  | `cd "$HOME/dotfiles-openSUSE"`        | always               |
| `opsignin` | `eval "$(op signin)"`                 | 1Password CLI        |
| `localip`  | `ip -brief -4 addr show scope global` | always               |
| `open`     | `explorer.exe`                        | WSL                  |
| `xdg-open` | `wslview`                             | WSL + wslview        |
| `cdwin`    | `cd "$WINHOME"`                       | WSL + WINHOME set    |
