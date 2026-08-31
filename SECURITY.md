# Security Policy

## Reporting a vulnerability

Please **do not open a public issue** for a security problem.

Private vulnerability reporting is enabled on this repository — use
**[Security → Report a vulnerability](https://github.com/dotgibson/dotfiles-openSUSE/security/advisories/new)**.
That opens a private advisory visible only to the maintainer.

If the issue affects shared configuration rather than the openSUSE layer, report it
against [`dotfiles-core`](https://github.com/dotgibson/dotfiles-core) instead — see its
[`SECURITY.md`](https://github.com/dotgibson/dotfiles-core/blob/main/SECURITY.md) for the fleet-wide policy. When in doubt, report here and it will be
routed.

## What this repository is

Dotfiles: shell, editor, tmux and provisioning configuration for an openSUSE box. There
is no service and no released binary, so the realistic threat model is **a change that
causes a user to run something they did not intend, or that weakens their machine's
security posture.** The areas below are where that can happen.

## Trust boundaries in `bootstrap.sh`

`bootstrap.sh` provisions a machine and escalates privileges. Things worth knowing
before you audit or extend it:

- **Privilege escalation** goes through `_priv`, which honours the `BLIB_SU` contract
  (`sudo` by default, `""` for root, `doas` where applicable). It runs a preflight and
  primes the credential cache once rather than escalating unpredictably mid-run.
- **Packages come from signed repositories.** `zypper` verifies GPG signatures; the
  policy is packaged-first precisely so the signed path is the default one.
- **The 1Password repository is key-pinned.** `rpm --import` of 1Password's published
  key **gates** the repository being added at all. If the key import fails, the repo is
  not added and the failure is recorded — earlier versions continued and then ran
  `--gpg-auto-import-keys`, which would import whatever key the repository served.
- **Three upstream installers are unpinned `curl | sh`** — starship, atuin, and mise.
  These are remote code executed as the invoking user. starship and atuin are now in
  `install/packages.txt`, so on Tumbleweed the package satisfies the guard and the
  installer never runs; it remains a fallback for Leap. mise has no openSUSE package,
  so `mise.run` is still its primary path. **This is the largest residual risk in the
  repository, and it is a known, accepted one.** If you are hardening a build, install
  mise from a checksummed release artifact instead.
- **Cargo builds** (`yazi`, `viddy`, `tree-sitter-cli`) use `--locked`, so they build
  the dependency set the crate author pinned.
- **`/etc/wsl.conf`** is rewritten on WSL. An existing file that differs is backed up to
  `/etc/wsl.conf.pre-dotfiles.<timestamp>` first.

## Secrets

**No secret material is ever committed to this repository.**

- `.gitignore` excludes everything under `ssh/`, and nothing there is tracked now that the
  client config lives in Core as `core/ssh/config` — keys are
  never tracked.
- Git identity lives in `~/.config/git/local.gitconfig`, seeded once from Core's example
  and never tracked. `os/opensuse.gitconfig` holds no `[user]` section.
- `gitleaks` runs at commit time via `.pre-commit-config.yaml`. Install the hooks
  (`pre-commit install`) — this is the only secret scan that covers repo-owned paths.
- GitHub secret scanning and push protection are enabled on the repository as a
  server-side backstop.

If you believe a secret has been committed, report it privately as above. Do not open a
PR that removes it — that publicises the leak while leaving it in history.

## Supply chain

- CI delegates to reusable workflows in `dotgibson/dotfiles-core`, referenced as `@v4`.
  That is a **movable tag**: whoever controls the tag controls this repository's CI.
- `core/` is vendored and content-pinned by `core.lock`; the `core-integrity` workflow
  verifies the vendored tree hash against the pinned commit on every PR, and
  `make check-core` reproduces that check locally.
- Dependabot security updates and CodeQL are enabled.

## Supported versions

Only the latest tag is supported. This is a rolling configuration repository; fixes land
on `main` and are tagged, not backported.
