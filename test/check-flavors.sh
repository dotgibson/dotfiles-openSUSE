#!/usr/bin/env bash
# test/check-flavors.sh
# ──────────────────────────────────────────────────────────────────────────────
# Do the two capability declarations still differ in EXACTLY the two ways they are
# ALLOWED to differ — and does the machinery that chooses between them still exist?
#
# WHY THIS IS THE FIRST TEST IN THIS REPO. One repo serves two distributions that
# upgrade with different verbs: Tumbleweed is rolling and takes `zypper dup`, Leap is
# versioned and takes `zypper up`. CLAUDE.md calls this "the rule that bites", and both
# declarations carry a wall of comments saying so. What neither of them carried was a
# gate: `os/opensuse.capabilities` and `os/opensuse.leap.capabilities` are maintained BY
# HAND ("Keep the rest in step by hand; there is deliberately no generator"), so an edit
# to one and not the other is silent drift in a pair of files that are 90% identical by
# design — the single most likely way this repo breaks.
#
# core/scripts/check-capabilities.sh validates each file against Core's SCHEMA (`make
# capabilities`), one at a time. It cannot see this, because the invariant is not about
# either file: it is about the DELTA between them.
#
# THE CONTRACT, as the two files themselves state it:
#
#   PKG_UPGRADE                — `dup` on Tumbleweed, `up` on Leap. Divergent.
#   MAINT_UNATTENDED_UPGRADE   — declared on Leap ONLY. On Tumbleweed the same flag
#                                would drive `dup`, i.e. an unattended DISTRIBUTION
#                                upgrade on a rolling distro. Divergent.
#   everything else            — identical, key for key and value for value.
#
# Plus the two things that make the split reachable at all: bootstrap.sh's
# /etc/os-release probe and its relink of the Leap file, and the pair of user-facing
# `zup`/`zdup` aliases in os/opensuse.zsh.
#
# Needs no zypper and no openSUSE: it reads the repo, so it is the half of the suite
# that is true everywhere and runs in CI on a plain runner.
#
# Exit codes:
#   0  the two declarations differ in exactly the declared ways
#   1  usage/environment failure (a file this test needs is missing)
#   2  drift — the delta is not what it is declared to be
#
# Usage:
#   test/check-flavors.sh
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
# `set -e` is deliberately off (the exit code IS the result), so guard the cd
# explicitly — continuing in the wrong directory would read the wrong declarations.
cd -- "$REPO_ROOT" || exit 1

if [[ -r core/lib/ux.sh ]]; then
  # shellcheck source=core/lib/ux.sh
  source core/lib/ux.sh
fi
say() { printf '%s::%s %s\n' "${UX_BLU:-}" "${UX_RST:-}" "$*"; }
ok() { printf '%s%s%s %s\n' "${UX_GRN:-}" "${UX_OK:-+}" "${UX_RST:-}" "$*"; }
bad() { printf '%s%s%s %s\n' "${UX_YEL:-}" "${UX_WARN:-!}" "${UX_RST:-}" "$*" >&2; }

TW=os/opensuse.capabilities
LEAP=os/opensuse.leap.capabilities

# The keys the two files are DECLARED to disagree on. Anything else that differs is the
# finding. Adding a key here is a deliberate widening of the contract — it should arrive
# with the comment in both declarations that explains why.
DIVERGENT="PKG_UPGRADE MAINT_UNATTENDED_UPGRADE"

fails=()
note_fail() { fails+=("$1"); }

for f in "$TW" "$LEAP"; do
  [[ -r "$f" ]] || {
    bad "declaration not readable: $f"
    exit 1
  }
done

# cap_dump <file> → `KEY<TAB>value` per declared key, in file order.
#
# Mirrors core/scripts/check-capabilities.sh's reader, including the part that is easy to
# get wrong: a `#` INSIDE A VALUE IS NOT A COMMENT (both files say so in their headers),
# so only a line whose first non-blank character is `#` is dropped. The indent is
# stripped BEFORE the `#` test, so an indented comment is a comment and an indented
# assignment is still an assignment.
cap_dump() {
  local line k v
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in '' | '#'*) continue ;; esac
    [[ "$line" == *=* ]] || continue
    k="${line%%=*}"
    v="${line#*=}"
    printf '%s\t%s\n' "$k" "$v"
  done <"$1"
}

TW_DUMP="$(cap_dump "$TW")"
LEAP_DUMP="$(cap_dump "$LEAP")"

# cap_get <dump> <key> — echo the declared value, status 1 when the key is absent.
#
# NO PIPE, deliberately, and for the reason Core's own cap_value documents: under
# `pipefail` a reader that exits on its match gives the writer EPIPE, and the pipeline
# reports failure on the SUCCESS path. A read loop over a herestring has neither the
# hazard nor a fork.
cap_get() {
  local _k _v
  while IFS=$'\t' read -r _k _v; do
    if [[ "$_k" == "$2" ]]; then
      printf '%s' "$_v"
      return 0
    fi
  done <<<"$1"
  return 1
}

cap_keys() { printf '%s' "$1" | cut -f1; }

# ── 1. PKG_UPGRADE: the verb that half-updates a box when it is wrong ─────────
say "PKG_UPGRADE — the verb each flavor upgrades with"
tw_up="$(cap_get "$TW_DUMP" PKG_UPGRADE)" || tw_up=""
leap_up="$(cap_get "$LEAP_DUMP" PKG_UPGRADE)" || leap_up=""

if [[ -z "$tw_up" ]]; then
  note_fail "$TW declares no PKG_UPGRADE (Core requires it)"
elif [[ ! "$tw_up" =~ zypper[[:space:]]+dup([[:space:]]|$) ]]; then
  note_fail "$TW: PKG_UPGRADE is '$tw_up' — Tumbleweed is ROLLING and must upgrade with 'zypper dup'; 'up' holds packages back and leaves the box in a state neither dialect describes"
else
  printf '  %-12s %s\n' "Tumbleweed" "$tw_up"
fi

if [[ -z "$leap_up" ]]; then
  note_fail "$LEAP declares no PKG_UPGRADE (Core requires it)"
elif [[ "$leap_up" =~ zypper[[:space:]]+dup([[:space:]]|$) ]]; then
  note_fail "$LEAP: PKG_UPGRADE is '$leap_up' — 'zypper dup' on Leap re-resolves the whole distribution against whatever repos are enabled, which is how you accidentally migrate a box"
elif [[ ! "$leap_up" =~ zypper[[:space:]]+up([[:space:]]|$) ]]; then
  note_fail "$LEAP: PKG_UPGRADE is '$leap_up' — Leap is a versioned release and must upgrade with 'zypper up'"
else
  printf '  %-12s %s\n' "Leap" "$leap_up"
fi

# ── 2. MAINT_UNATTENDED_UPGRADE: Leap only, and that is the point ─────────────
say "MAINT_UNATTENDED_UPGRADE — declared on Leap only"
if cap_get "$TW_DUMP" MAINT_UNATTENDED_UPGRADE >/dev/null; then
  note_fail "$TW declares MAINT_UNATTENDED_UPGRADE — the flag drives PKG_UPGRADE, which here is 'dup', so declaring it turns the nightly maint run into an unattended DISTRIBUTION upgrade on a rolling distro. Leap declares it; Tumbleweed must not"
else
  printf '  %-12s %s\n' "Tumbleweed" "absent (correct — it would drive an unattended dup)"
fi
leap_unattended="$(cap_get "$LEAP_DUMP" MAINT_UNATTENDED_UPGRADE)" || leap_unattended=""
if [[ "$leap_unattended" != 1 ]]; then
  note_fail "$LEAP: MAINT_UNATTENDED_UPGRADE is '${leap_unattended:-absent}', expected 1 — Leap's maintenance updates to a versioned release are exactly what an unattended nightly is for, and dropping the flag silently retires that behaviour"
else
  printf '  %-12s %s\n' "Leap" "1"
fi

# ── 3. every OTHER key is identical, key for key and value for value ──────────
# The load-bearing check. The two files are 90% the same by design and are kept in step
# BY HAND, so this is the one that catches "edited the Tumbleweed file, forgot the Leap
# one" — drift that no schema validator can see, because each file is individually valid.
say "the remaining keys — identical in both declarations"
diverged=0
while IFS= read -r k; do
  [[ -n "$k" ]] || continue
  case " $DIVERGENT " in *" $k "*) continue ;; esac
  a="$(cap_get "$TW_DUMP" "$k")" || a=""
  if ! b="$(cap_get "$LEAP_DUMP" "$k")"; then
    note_fail "$k is declared in $TW but not in $LEAP — every key but $DIVERGENT must exist in both"
    diverged=1
    continue
  fi
  if [[ "$a" != "$b" ]]; then
    note_fail "$k differs but is not a declared divergence: Tumbleweed '$a' vs Leap '$b'"
    diverged=1
  fi
done < <(cap_keys "$TW_DUMP")

while IFS= read -r k; do
  [[ -n "$k" ]] || continue
  case " $DIVERGENT " in *" $k "*) continue ;; esac
  cap_get "$TW_DUMP" "$k" >/dev/null || {
    note_fail "$k is declared in $LEAP but not in $TW — every key but $DIVERGENT must exist in both"
    diverged=1
  }
done < <(cap_keys "$LEAP_DUMP")
((diverged)) || printf '  %s\n' "the two declarations agree on every key outside $DIVERGENT"

# ── 4. the split is reachable: bootstrap.sh still chooses ─────────────────────
# A declaration is DATA and cannot probe, so the choice is made in bootstrap.sh. Without
# these two lines both files are still individually valid and every Leap box silently
# gets Tumbleweed's `dup` — the failure this whole tier split exists to prevent.
say "bootstrap.sh still picks a flavor"
if grep -q 'grep -qi tumbleweed /etc/os-release' bootstrap.sh; then
  printf '  %s\n' "/etc/os-release probe present"
else
  note_fail "bootstrap.sh no longer probes /etc/os-release for tumbleweed — nothing chooses between the two declarations, and every Leap box gets Tumbleweed's 'dup'"
fi
if grep -q "os/opensuse.leap.capabilities" bootstrap.sh; then
  printf '  %s\n' "relinks $LEAP on a non-Tumbleweed box"
else
  note_fail "bootstrap.sh no longer references $LEAP — blib_link_os_layer links the Tumbleweed file by default, so without the relink the Leap declaration is dead weight"
fi

# ── 5. both user-facing aliases survive ──────────────────────────────────────
say "os/opensuse.zsh keeps both upgrade aliases"
if grep -qE "^alias zup=.*zypper up" os/opensuse.zsh; then
  printf '  %s\n' "zup  -> zypper up   (Leap)"
else
  note_fail "os/opensuse.zsh: no 'zup' alias for 'zypper up' — bootstrap.sh's own output tells a Leap user to run 'zup'"
fi
if grep -qE "^alias zdup=.*zypper dup" os/opensuse.zsh; then
  printf '  %s\n' "zdup -> zypper dup  (Tumbleweed)"
else
  note_fail "os/opensuse.zsh: no 'zdup' alias for 'zypper dup' — bootstrap.sh's own output tells a Tumbleweed user to run 'zdup'"
fi

echo
if ((${#fails[@]})); then
  bad "${#fails[@]} flavor-split finding(s):"
  printf '    %s\n' "${fails[@]}" >&2
  cat >&2 <<'EOF'

Both declarations document their own delta at length. If a divergence here is
INTENDED, say so in both files and add the key to DIVERGENT in this test; if it is
not, the fix is to bring the two files back into step by hand.
EOF
  exit 2
fi
ok "the two capability declarations differ in exactly the two declared ways."
