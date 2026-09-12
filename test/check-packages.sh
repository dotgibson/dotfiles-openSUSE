#!/usr/bin/env bash
# test/check-packages.sh
# ──────────────────────────────────────────────────────────────────────────────
# Is install/packages.txt still a list zypper can actually install?
#
# bootstrap.sh's zypper_install is deliberately forgiving: a bulk install that fails
# retries package-by-package and records "skipped (unavailable on this box?)" for each
# casualty. That resilience is right for a live box — one dead name should not sink a
# whole bootstrap — but it means a typo, a rename, or a dropped package is easy to miss.
# This turns that into a gate. It installs NOTHING.
#
# TWO HALVES, and they are true in different places.
#
#   1. HYGIENE — no zypper needed, so it runs on any box and in CI on a plain runner.
#      Parses the list with the SAME reader bootstrap.sh feeds zypper
#      (blib_read_pkgs_into), then checks the things a resolver would never tell you
#      apart from a rename: a list that parses to nothing, a name repeated in two
#      sections of a heavily-commented 50-name file, and a name carrying a character no
#      RPM name can hold — a smart quote, a stray comment marker, an alignment tab
#      pulled into the name by an edit. Each of those reaches zypper as a bogus name and
#      comes back as "not found", which reads exactly like drift and is not.
#
#   2. RESOLUTION — needs zypper AND root, so it is a smoke test where you can have one
#      and a clean skip everywhere else. `zypper install --dry-run` runs the real
#      solver and installs nothing, which is the same question bootstrap.sh's `zypper
#      install` asks. It is run in BULK first, and that is the part CI does not cover:
#      .github/workflows/bootstrap.yml's packages-check job probes one name at a time
#      (better reporting for a rename), so nothing anywhere asks whether the whole set
#      is CO-INSTALLABLE — whether two names in it conflict.
#
# WHY `install --dry-run` AND NOT THE OBVIOUS PROBES. Both traps are recorded in
# bootstrap.yml at length: `search --match-exact` matches package NAMES only and rejects
# `python3-pip`, which installs fine as a versioned `python313-pip` that Provides it;
# `zypper info` prints "not found" for a bogus name and still EXITS 0, which is a gate
# that can never fail. Only the solver answers the question bootstrap.sh will ask.
#
# VERSION FLOORS ARE CHECKED, per flavor, and a name resolving is not the whole story for
# a floored entry: `neovim` resolves on Tumbleweed, Leap 16.1 AND Leap 16.0, and clears
# its `# min:0.12.0` on only the first two (#178). Two facts, and this gate reports both.
# The floor is declared ONCE as a contract in two places that must agree — the `# min:`
# on the manifest line, and NEOVIM_FLOOR in bootstrap.sh, which warns on the box — and
# the hygiene half asserts that agreement, so the restatement cannot silently drift. The
# probe itself needs zypper (`zypper info` for the candidate, `zypper versioncmp` for
# the RPM comparison) but NOT root, so it runs wherever the resolve is skipped for lack
# of it. Three tiers, because a gate that cannot tell them apart is the useless kind:
#
#   • a floor unmet on TUMBLEWEED       → FAIL (exit 2). Unsatisfiable fleet-wide: Core's
#                                          pin outran the rolling target.
#   • a floor unmet on LEAP             → REPORT. Known, documented in the manifest, and
#                                          unfixable by zypper on that release; bootstrap.sh
#                                          warns on the box itself. Failing would be a
#                                          permanent red that no one can act on.
#   • a floor that disagrees with       → FAIL (exit 1). A contract with two values is
#     bootstrap.sh's NEOVIM_FLOOR          not a contract.
#
# RUN IT WHERE THE ANSWER IS TRUE. Availability is a property of the repos on the box,
# and Tumbleweed and Leap disagree BY DESIGN — install/packages.txt documents the
# flavor-dependent entries, and bootstrap.sh cargo-builds them on Leap. Those names are
# listed in LEAP_OPTIONAL below and are a warning there rather than a failure. The
# authoritative resolve is the workflow, in a pinned container.
#
# Exit codes:
#   0  the list is well-formed, every name resolved and every declared floor is met on
#      this flavor (or a clean skip: no zypper/root)
#   1  usage/environment failure, or a `# min:` that disagrees with bootstrap.sh
#   2  one or more findings — the drift signal
#
# Usage:
#   test/check-packages.sh                      # install/packages.txt
#   test/check-packages.sh install/packages.txt
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
# `set -e` is deliberately off (the exit code IS the result), so guard the cd
# explicitly — continuing in the wrong directory would read the wrong manifest.
cd -- "$REPO_ROOT" || exit 1

if [[ -r core/lib/ux.sh ]]; then
  # shellcheck source=core/lib/ux.sh
  source core/lib/ux.sh
fi
say() { printf '%s::%s %s\n' "${UX_BLU:-}" "${UX_RST:-}" "$*"; }
ok() { printf '%s%s%s %s\n' "${UX_GRN:-}" "${UX_OK:-+}" "${UX_RST:-}" "$*"; }
bad() { printf '%s%s%s %s\n' "${UX_YEL:-}" "${UX_WARN:-!}" "${UX_RST:-}" "$*" >&2; }

# Names install/packages.txt documents as flavor-dependent: present on Tumbleweed,
# absent from Leap 16.x's primary repos, and supplied there by a presence-guarded
# bootstrap.sh fallback instead. They stay in the list so Tumbleweed takes the
# signed-repo path, so a Leap run must report them as expected-absent rather than as
# drift. Keep this in step with the entries in install/packages.txt that say so.
LEAP_OPTIONAL="tealdeer"

manifest="${1:-install/packages.txt}"
[[ -f "$manifest" ]] || {
  bad "manifest not found: $manifest"
  exit 1
}

# Reuse Core's parser rather than re-implementing the comment/whitespace rules: it is
# the SAME function bootstrap.sh feeds zypper, so this checks exactly the names that
# would really be installed, inline-comment stripping and all. The `_into` form assigns
# in this frame, so an unreadable list is a REAL failure — `mapfile -t pkgs < <(...)`
# runs the reader in a subshell and reports mapfile's status, which makes the reader's
# failure structurally unreachable (dotfiles-core#460).
if [[ -r core/lib/bootstrap-lib.sh ]]; then
  # shellcheck source=core/lib/bootstrap-lib.sh
  source core/lib/bootstrap-lib.sh
else
  bad "core/lib/bootstrap-lib.sh not found — is the core/ subtree vendored?"
  exit 1
fi
command -v blib_read_pkgs_into >/dev/null 2>&1 || {
  bad "this repo's vendored core/ predates blib_read_pkgs_into — sync Core (make sync in dotfiles-core)"
  exit 1
}
# Declared here, not just filled by the helper: blib_read_pkgs_into assigns into this
# frame through an `eval`, which ShellCheck cannot see (SC2154 on every later use). The
# helper empties the array before reading anyway, so the declaration costs nothing and is
# the honest statement of which frame owns the variable.
pkgs=()
blib_read_pkgs_into pkgs "$manifest" || exit 1

findings=()
note() { findings+=("$1"); }

# ── 1. hygiene ────────────────────────────────────────────────────────────────
say "$manifest — ${#pkgs[@]} names"
if ((${#pkgs[@]} == 0)); then
  # NOT an empty set: bootstrap.sh treats a list that parses to nothing as a failure for
  # the same reason (a machine that provisioned none of its tooling is not a machine
  # that asked for no extras).
  bad "$manifest parsed to zero package names — that is a malformed list, not an empty one"
  exit 2
fi

# Duplicates. Harmless to zypper, which is exactly why nothing else would ever report
# them — but in a list whose sections are separated by paragraphs of prose, the same
# name in two places means two entries claiming different things about one package, and
# the reader believes whichever they find first.
dups="$(printf '%s\n' "${pkgs[@]}" | sort | uniq -d)"
if [[ -n "$dups" ]]; then
  while IFS= read -r d; do
    [[ -n "$d" ]] && note "$d — listed more than once; one package, one entry"
  done <<<"$dups"
else
  printf '  %s\n' "no duplicate names"
fi

# Legal RPM package names only. rpm names hold [A-Za-z0-9._+-] and start alphanumeric;
# anything else got there by an edit accident (a smart quote, a `#` that lost its space,
# an alignment tab dragged into the name) and reaches zypper as a name it cannot find —
# a finding that reads like a rename and is not.
badname=0
for p in "${pkgs[@]}"; do
  if [[ ! "$p" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; then
    note "$(printf '%q' "$p") — not a legal RPM package name; a resolver would report this as 'not found'"
    badname=1
  fi
done
((badname)) || printf '  %s\n' "every name is a legal RPM package name"

# ── 1b. version floors: one contract, two spellings, must agree ───────────────
# Floors live in the manifest's trailing comments (`name  # min:X.Y.Z`) so the file stays
# human-first and there is no second list to drift — read straight from the source, since
# blib_read_pkgs strips comments by design. bootstrap.sh restates neovim's as NEOVIM_FLOOR
# (the value it warns against on the box); that restatement is the one thing here that CAN
# drift, so it is asserted, and a mismatch is a broken contract rather than a finding.
declare -A floors=()
while IFS= read -r line; do
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ "$line" == *"min:"* ]] || continue
  name="${line%%#*}"; name="${name//[[:space:]]/}"
  [[ -n "$name" ]] || continue
  floor="$(printf '%s' "$line" | sed -n 's/.*min:\([0-9][0-9A-Za-z.+~-]*\).*/\1/p')"
  [[ -n "$floor" ]] || continue
  floors["$name"]="$floor"
done <"$manifest"
if ((${#floors[@]})); then
  say "declared version floors"
  for name in "${!floors[@]}"; do printf '  %-16s >= %s\n' "$name" "${floors[$name]}"; done
fi
if [[ -n "${floors[neovim]:-}" ]]; then
  bfloor="$(sed -n 's/^NEOVIM_FLOOR="\([^"]*\)".*/\1/p' bootstrap.sh | head -1)"
  if [[ -z "$bfloor" ]]; then
    bad "bootstrap.sh no longer declares NEOVIM_FLOOR — nothing warns a Leap 16.0 box that its neovim is below the floor install/packages.txt declares"
    exit 1
  elif [[ "$bfloor" != "${floors[neovim]}" ]]; then
    bad "neovim floor disagrees: install/packages.txt says min:${floors[neovim]}, bootstrap.sh says NEOVIM_FLOOR=$bfloor — one contract, two values; fix whichever is stale"
    exit 1
  fi
  printf '  %s\n' "neovim floor agrees with bootstrap.sh's NEOVIM_FLOOR ($bfloor)"
fi

# ── 2. resolution ─────────────────────────────────────────────────────────────
# Everything below needs zypper and the privileges its solver insists on even for a
# --dry-run. Report the skip and fall through to the verdict rather than pretending.
resolve_or_skip() {
  command -v zypper >/dev/null 2>&1 || {
    say "no zypper on this host — skipping the resolve (the authoritative run is .github/workflows/bootstrap.yml)"
    return 0
  }

  # `zypper install` requires root even with --dry-run, so resolve an escalator the way
  # bootstrap.sh does: Core's documented BLIB_SU contract, empty when already root. A
  # non-interactive `sudo -n` probe keeps `make test` from blocking on a password prompt.
  local su="${BLIB_SU-sudo}"
  local -a priv=()
  if [[ "$(id -u)" == 0 ]]; then
    su=""
  elif [[ -z "$su" ]]; then
    bad "BLIB_SU is empty but this is not root — zypper's solver needs root even for --dry-run"
    return 0
  elif ! command -v "$su" >/dev/null 2>&1; then
    say "'$su' not found and not root — skipping the resolve (run as root, or set BLIB_SU)"
    return 0
  elif [[ "$su" == sudo ]] && ! sudo -n true 2>/dev/null; then
    say "sudo would prompt for a password — skipping the resolve (run 'sudo -v' first, or as root)"
    return 0
  fi
  [[ -n "$su" ]] && priv=("$su")

  local flavor="Leap"
  grep -qi tumbleweed /etc/os-release 2>/dev/null && flavor="Tumbleweed"
  say "flavor in view: $flavor"

  # --no-recommends mirrors bootstrap.sh's zypper_install: the gate must ask the question
  # the installer asks, not a wider one.
  #
  # --allow-downgrade (dotfiles-openSUSE#149) for the reason bootstrap.yml documents: on
  # Tumbleweed the container/mirror pair are published independently, and in the skew
  # window every name that reaches glibc-devel (gcc, gcc-c++, cargo) resolves only by
  # downgrading an already-installed glibc, which `install` refuses by default. The flag
  # only widens what the solver may do to packages ALREADY INSTALLED here; a bogus name
  # still fails. NOT --force-resolution, which would let the solver answer "do not
  # install it" — a false green.
  sim() { "${priv[@]}" zypper --non-interactive install --dry-run --no-recommends --allow-downgrade "$@" 2>&1; }

  # Bulk first, then per-name — the same bulk-then-retry shape as bootstrap.sh's
  # zypper_install, and for the same reason. The bulk pass proves what no per-name probe
  # can: that the whole set is CO-INSTALLABLE.
  local out rc=0
  out="$(sim "${pkgs[@]}")" || rc=$?
  # zypper's exit codes are not a simple 0/non-0: 102 (reboot needed), 103 (zypper needs
  # restarting) and 106 (a repo was unavailable but the transaction worked) all mean it
  # RESOLVED. bootstrap.sh's zypper_install treats them as success; so must this.
  case $rc in
  0 | 102 | 103 | 106)
    ok "all ${#pkgs[@]} names resolve, and the set is co-installable."
    return 0
    ;;
  esac

  bad "the bulk resolve failed (rc=$rc) — narrowing down per package"
  local p prc reason
  for p in "${pkgs[@]}"; do
    prc=0
    out="$(sim "$p")" || prc=$?
    case $prc in 0 | 102 | 103 | 106) continue ;; esac
    # KEEP THE PROBE OUTPUT. A name fails for reasons only the solver can tell apart —
    # renamed upstream, dropped, or a half-synced mirror — and discarding it left
    # dotfiles-openSUSE#149 with three names and no reason across four CI runs.
    reason="$(printf '%s' "$out" | grep -iE '^(Problem|No provider|.*not found)' | head -1)"
    reason="${reason:-rc=$prc}"
    case " $LEAP_OPTIONAL " in
    *" $p "*)
      if [[ "$flavor" == Leap ]]; then
        # Documented in install/packages.txt: absent from Leap 16.x, supplied there by a
        # presence-guarded cargo build. Expected, so not a finding.
        bad "$p — did not resolve, but install/packages.txt documents it as Tumbleweed-only; bootstrap.sh cargo-builds it on Leap"
        continue
      fi
      ;;
    esac
    note "$p — did not resolve on $flavor: $reason"
  done
  return 0
}
resolve_or_skip

# ── 3. version floors: does the candidate clear them on THIS flavor? ─────────
# `zypper info` prints the candidate's "Version : X-R" line and needs no root (unlike the
# solver above), so this runs on a box where the resolve was skipped. `zypper versioncmp`
# is the RPM comparator zypper itself uses — the openSUSE analogue of Debian's
# `dpkg --compare-versions` — and its exit codes are documented in zypper(8): 0 equal,
# 11 VERSION1 newer, 12 VERSION2 newer. Not `sort -V`: the candidate carries a release
# (`0.11.3-bp160.2.1`) and RPM's rules for that are not sort's.
floors_or_skip() {
  ((${#floors[@]})) || return 0
  command -v zypper >/dev/null 2>&1 || {
    say "no zypper on this host — skipping the floor probe (the authoritative run is .github/workflows/bootstrap.yml)"
    return 0
  }
  local flavor="Leap"
  grep -qi tumbleweed /etc/os-release 2>/dev/null && flavor="Tumbleweed"
  say "version floors on $flavor"
  local name floor cand rc
  for name in "${!floors[@]}"; do
    floor="${floors[$name]}"
    cand="$(zypper --non-interactive info "$name" 2>/dev/null | sed -n 's/^Version *: *//p' | head -1)"
    if [[ -z "$cand" ]]; then
      # No candidate at all is the resolve pass's finding, not this one's — do not report
      # one missing name twice.
      bad "$name — no candidate on $flavor, cannot check its >=$floor floor (the resolve above owns that finding)"
      continue
    fi
    rc=0
    zypper --non-interactive versioncmp "$cand" "$floor" >/dev/null 2>&1 || rc=$?
    case $rc in
    0 | 11) printf '  %-16s %s (floor %s) ok\n' "$name" "$cand" "$floor" ;;
    12)
      if [[ "$flavor" == Leap ]]; then
        # Documented in install/packages.txt: Leap 16.0 ships below the floor and zypper
        # has no lever there. bootstrap.sh warns on the box; here it is a report.
        bad "$name — candidate $cand is BELOW its >=$floor floor on $flavor; install/packages.txt documents this (Leap 16.0), bootstrap.sh warns on the box, and the fix is Leap 16.1+ or 'mise use -g $name@${floor%.*}'"
      else
        note "$name — candidate $cand is BELOW its >=$floor floor on $flavor: Core's pin has outrun the rolling target"
      fi
      ;;
    *) bad "$name — 'zypper versioncmp $cand $floor' returned $rc; cannot judge the floor" ;;
    esac
  done
}
floors_or_skip

# ── verdict ───────────────────────────────────────────────────────────────────
echo
if ((${#findings[@]})); then
  bad "${#findings[@]} finding(s) in $manifest:"
  printf '    %s\n' "${findings[@]}" >&2
  cat >&2 <<'EOF'

A non-resolving name is one of:
  • a rename       — find the new name and update install/packages.txt
  • a drop         — remove it, or add a presence-guarded fallback in bootstrap.sh
  • a typo         — fix it
  • flavor drift   — real on Tumbleweed, absent on Leap. If bootstrap.sh already has a
                     fallback for it, add the name to LEAP_OPTIONAL in this test and say
                     so in install/packages.txt, the way tealdeer does.
A name BELOW its floor on Tumbleweed means Core's pin has moved past what the rolling
target ships: raise it upstream (dotfiles-core) rather than lowering the `# min:` here.
EOF
  exit 2
fi
ok "install/packages.txt is well-formed."
