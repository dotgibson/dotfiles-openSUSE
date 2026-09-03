# Contributing to dotfiles-openSUSE

This is the **OS-native layer** for openSUSE in a three-tier system
(Core → OS-native → Role). Most of the rules here are boundary rules: what belongs in
this repo versus upstream in [`dotfiles-core`](https://github.com/dotgibson/dotfiles-core).

For the shared Core rules — the load order, the "is it Core?" test, the manifest
contract — see dotfiles-core's [`README.md`](https://github.com/dotgibson/dotfiles-core/blob/main/README.md) and
[`CONTRIBUTING.md`](https://github.com/dotgibson/dotfiles-core/blob/main/CONTRIBUTING.md), upstream rather than in `core/`.

## The rule that bites

**`core/` is a vendored `git subtree` copy of `dotfiles-core`. It is not editable here.**

Anything you change under `core/` is overwritten on the next sync, and the
`core-integrity` CI gate will fail the PR by comparing the vendored tree hash against
the commit `core.lock` pins. To change shared config: edit it **in dotfiles-core**, run
`make audit` there, then `make sync` to fan it out to every OS repo.

The `no-core-edits` pre-commit hook enforces this locally. A genuine
`git subtree pull` will also trip it — that one is expected; bypass with
`git commit --no-verify`, or let the upstream fan-out raise the `sync/core-vX.Y.Z` PR.

## What belongs here

Only what changes with the OS:

| Path                    | Owns                                                        |
| ----------------------- | ----------------------------------------------------------- |
| `bootstrap.sh`          | zypper provisioning + calling Core's link helpers           |
| `install/packages.txt`  | openSUSE package names                                      |
| `os/opensuse.zsh`       | clipboard, PATH, zypper aliases → `~/.config/zsh/80-os.zsh` |
| `os/opensuse.conf`      | tmux OS overlay → `~/.config/tmux/os.conf`                  |
| `os/opensuse.gitconfig` | git OS overlay → `~/.config/git/os.gitconfig`               |
| `wsl/wsl.conf`          | WSL systemd/user config (the ssh client config is Core's)   |
| `test/*.sh`             | the repo's own suite — run by `make suite`, and by CI       |

If it would be identical on every distro it belongs in Core. If it changes with the
operator rather than the OS, it belongs in a role repo (`dotfiles-Offense`,
`dotfiles-Defense`).

## Before you push

```bash
make test
```

That runs the same checks CI does: ShellCheck + `bash -n` on the repo-owned bash,
`zsh -n` on `os/*.zsh`, `actionlint` on the workflow callers, `make core-verify`
(the local mirror of CI's `guard / integrity` — it runs Core's own `core-integrity.sh`
against a sibling `dotfiles-core` checkout to verify `core/` still matches the commit
`core.lock` pins; without that checkout it checks what it can offline and defers the tree
comparison to CI), and `make suite`, this repo's own tests. Linters that aren't installed
are skipped with a warning rather than failing, so a partial toolchain still gives useful
output.

The target names come from Core, not from here: `scripts/make-vocabulary.txt` in
`dotfiles-core` declares one `make` vocabulary — `help lint check dry-run
packages-check core-verify test` — for every repo that vendors it
(dotgibson/dotfiles-core#691), so the verbs mean the same thing in all of them. The two
targets this repo renamed to reach it keep their old spellings as aliases, so
`make check-core` and `make bootstrap-dry` still work.

Two more worth knowing:

```bash
make check           # lint + a hermetic --links-only bootstrap into a throwaway HOME
make packages-check  # do all install/packages.txt names still resolve? (installs nothing)
```

`make check` is the only local gate that actually executes `wire_links` — `make lint`
only parses it. It needs an openSUSE host (`bootstrap.sh` refuses to run off-distro) and
skips with a note elsewhere; CI runs it in a pinned container either way.

Optional but recommended:

```bash
pip install pre-commit && pre-commit install
```

This adds gitleaks (secret scanning), the exec-bit checks, and the `no-core-edits`
guard at commit time. **Nothing else in this repo scans for secrets** — the gitleaks
config inside `core/` audits *dotfiles-core*, not this layer.

## Windows / `\\wsl.localhost` checkouts — read this first

If you edit this repo from Windows against a WSL share, run this once per clone:

```bash
git config core.fileMode false
```

Two things go wrong without it:

1. **Phantom mode changes.** The SMB mount cannot represent the executable bit, so git
   reports every `+x` file as `100755 → 100644` — 35 files, all with zero content
   changes. A `git commit -a` then strips `+x` from `bootstrap.sh` (breaking the
   documented `./bootstrap.sh`) *and* rewrites 34 files under `core/`, tripping
   `core-integrity`.
2. **Line endings.** `core.autocrlf` is commonly `true` globally on Windows. A
   `bootstrap.sh` committed with CRLF gets the shebang `#!/usr/bin/env bash\r` and dies
   on every Linux box with `bad interpreter: No such file or directory`. The root
   `.gitattributes` pins `eol=lf` to prevent this — do not remove it.

Also note that a tool which *rewrites* a file (rather than patching it) drops the
executable bit on that mount. If you regenerate `bootstrap.sh`, check `ls -l` and
`chmod +x` it back; `core.fileMode=false` keeps the index mode correct, so the commit
is unaffected, but your local copy will not run.

## Style

- 2-space indent, LF, final newline — enforced by `.editorconfig` and `.gitattributes`.
- `shfmt` is deliberately **not** enforced (it would expand the compact one-liner style
  in `bootstrap.sh`'s argument loop). This matches Core's decision.
- [Conventional Commits](https://www.conventionalcommits.org/): `fix(bootstrap): …`,
  `docs(readme): …`, `chore(core): …`.

## Adding a package

Put it in `install/packages.txt` with a short trailing comment saying what it replaces
or provides. The policy is **packaged-first**: if openSUSE ships it, it goes in that
file and comes from the signed repo. `bootstrap.sh`'s upstream installers
(`curl | sh` for starship/atuin/mise) exist only as a fallback for Leap or for a box
where the package was unavailable — keep them off the happy path.

`zypper_install` degrades to a package-by-package pass if the bulk transaction fails,
so a name that is missing on older Leap is skipped and recorded in the failure ledger
rather than aborting the run.
