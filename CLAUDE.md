# CLAUDE.md — dotfiles-openSUSE

Project memory for Claude Code, auto-loaded every session. For the shared Core
rules (the load order, the "is it Core?" test, the manifest contract) see
dotfiles-core's [`README.md`](https://github.com/dotgibson/dotfiles-core/blob/main/README.md) and
[`CONTRIBUTING.md`](https://github.com/dotgibson/dotfiles-core/blob/main/CONTRIBUTING.md) — upstream, not in `core/`, which
vendors only what a machine actually runs.

## What this repo is

`dotfiles-openSUSE` is the **OS-native layer for openSUSE** in an **eleven-repo dotfiles system** built on a three-layer
model (Core → OS-native → Role). Stamped from the Fedora template (see `core/PORTING-MATRIX.md`). Two flavors with **different update commands** — Tumbleweed (rolling) uses `zypper dup`, Leap (stable) uses `zypper up`. Get this wrong and you half-update. Add the Packman repo for codecs.

## The rule that bites

`core/` is a **vendored `git subtree` copy of [dotfiles-core](https://github.com/dotgibson/dotfiles-core)** — it
is *not* editable here. Anything you change under `core/` is overwritten on the
next sync. To change shared Core config, edit it **in dotfiles-core**, run
`make audit` there, then `make sync` to fan it out to every OS repo.

What belongs **here** is only the OS-native layer: the `zypper` package list, clipboard + paths, and the bootstrap.

## Where things are

- `os/opensuse.zsh` — clipboard + package-manager aliases for openSUSE
- `os/opensuse.conf`, `os/opensuse.gitconfig` — tmux + git OS overlays
- `install/packages.txt` — openSUSE package names
- `bootstrap.sh` — symlinks Core + OS files into place
- `core/` — vendored Core (read-only here; edit upstream in dotfiles-core)
