#!/usr/bin/env bash
# test/check-flavors.sh
# ──────────────────────────────────────────────────────────────────────────────
# Do the three capability declarations still differ in EXACTLY the ways they are ALLOWED
# to differ — and does the machinery that chooses between them still exist?
#
# WHY THIS IS THE FIRST TEST IN THIS REPO. One repo serves three editions that upgrade
# with different verbs: Tumbleweed is rolling and takes `zypper dup`, Leap is versioned
# and takes `zypper up`, and the transactional edition (MicroOS / Aeon / Kalpa) is a
# Tumbleweed base whose root is read-only, so `zypper` is refused outright and every
# install or upgrade goes through `transactional-update` into a NEW snapshot that a
# reboot applies (#191). CLAUDE.md calls the first split "the rule that bites", and all
# three declarations carry a wall of comments saying so. What none of them carried was a
# gate: the files are maintained BY HAND ("Keep the rest in step by hand; there is
# deliberately no generator"), so an edit to one and not the others is silent drift in a
# set of files that are 90% identical by design — the single most likely way this repo
# breaks.
#
# core/scripts/check-capabilities.sh validates each file against Core's SCHEMA (`make
# capabilities`), one at a time. It cannot see this, because the invariant is not about
# either file: it is about the DELTA between them.
#
# THE CONTRACT, as the files themselves state it. Tumbleweed vs Leap:
#
#   PKG_UPGRADE                — `dup` on Tumbleweed, `up` on Leap. Divergent.
#   MAINT_UNATTENDED_UPGRADE   — declared on Leap ONLY. On Tumbleweed the same flag
#                                would drive `dup`, i.e. an unattended DISTRIBUTION
#                                upgrade on a rolling distro. Divergent.
#   everything else            — identical, key for key and value for value.
#
# Tumbleweed vs the transactional edition (a Tumbleweed base — still `dup`):
#
#   PKG_UPGRADE / PKG_INSTALL / PKG_REMOVE
#                              — the same verbs through `transactional-update` (`dup`,
#                                `-n pkg in`, `-n pkg rm`); `zypper` itself is refused.
#   PROVISIONER / PKG_APPLY / PKG_APPLY_PENDING
#                              — ADDED: `transactional`, the reboot that makes a staged
#                                snapshot live, and the probe that says one is waiting.
#   PKG_ASSUME_YES / PKG_UPGRADE_PARTIAL
#                              — DROPPED: options go before the command so `-y` cannot be
#                                appended, and a snapshot is all-or-nothing.
#   MAINT_UNATTENDED_UPGRADE   — absent on both, for one more reason here: MicroOS ships
#                                its own timer and rollback.
#   everything else            — identical to the Tumbleweed file.
#
# Plus the things that make the splits reachable at all: bootstrap.sh's /etc/os-release
# probe and its relink of the Leap file; its host marker (transactional-update on PATH
# beside a read-only /usr — NOT the ID, which says ID_LIKE=tumbleweed), the CI seam that
# forces it, its relink of the transactional file, and `--continue` on EVERY
# transactional-update call (without it each call restarts from the BOOTED snapshot and
# silently discards the pending one — measured, dotfiles-core NON-MUTABLE-HOST-PROPOSAL
# R4); and the pair of user-facing `zup`/`zdup` aliases in os/opensuse.zsh. And one thing
# about that file that is not a flavor question but lives here because this is the test
# that already reads it: its WSL-only aliases must ask Core (_core_is_wsl), not a private
# copy of the detection.
#
# Needs no zypper and no openSUSE: it reads the repo, so it is the half of the suite
# that is true everywhere and runs in CI on a plain runner.
#
# Exit codes:
#   0  the three declarations differ in exactly the declared ways
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
MICROOS=os/opensuse.microos.capabilities

# The keys the two files are DECLARED to disagree on. Anything else that differs is the
# finding. Adding a key here is a deliberate widening of the contract — it should arrive
# with the comment in both declarations that explains why.
DIVERGENT="PKG_UPGRADE MAINT_UNATTENDED_UPGRADE"
# The same contract for Tumbleweed vs the transactional edition: the verbs that change
# value, the keys only the transactional file declares, and the keys only it omits.
MICROOS_DIVERGENT="PKG_UPGRADE PKG_INSTALL PKG_REMOVE"
MICROOS_ADDED="PROVISIONER PKG_APPLY PKG_APPLY_PENDING"
MICROOS_DROPPED="PKG_ASSUME_YES PKG_UPGRADE_PARTIAL"
# Declared in both, different by design, and NOT a command. PKG_UNLISTED_TOOLS
# (dotgibson/dotfiles-core#1087) names the binaries a file's OWN verbs run that
# install/packages.txt does not; it differs here because the verbs differ — Tumbleweed
# reads and writes with zypper alone, the transactional edition also runs
# transactional-update (the only thing allowed to write) and systemctl (what PKG_APPLY
# reboots through). Kept OUT of MICROOS_DIVERGENT because every key in that list carries a
# hand-written assertion above pinning its exact command shape, and this key is not a
# command. Core's validator already holds each file's value to that file's own verbs from
# both ends, so this test only has to stop demanding the two be identical.
MICROOS_DIVERGENT_NONVERB="PKG_UNLISTED_TOOLS"

fails=()
note_fail() { fails+=("$1"); }

for f in "$TW" "$LEAP" "$MICROOS"; do
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
MICROOS_DUMP="$(cap_dump "$MICROOS")"

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
# …and the transactional edition overrides them, behind Core's accessor, every mutating
# call carrying --continue. The mutable lines above stay (the grep is anchored at column
# 1; the overrides are indented inside the branch), so a box whose Core did not load
# still has the zypper spellings.
say "os/opensuse.zsh overrides the mutating aliases on the transactional edition"
if grep -qE '_core_cap PROVISIONER.*==[[:space:]]*transactional' os/opensuse.zsh; then
  printf '  %s\n' "gated on the declaration (_core_cap PROVISIONER)"
else
  note_fail "os/opensuse.zsh no longer asks Core's _core_cap whether PROVISIONER is transactional — the snapshot-verb aliases have no gate (or re-probe the host, which is bootstrap.sh's job)"
fi
for pair in "zin:pkg in" "zrm:pkg rm" "zdup:dup"; do
  a="${pair%%:*}" verb="${pair#*:}"
  if grep -qE "^[[:space:]]+alias $a='sudo transactional-update .*--continue.* $verb'" os/opensuse.zsh; then
    printf '  %-5s %s\n' "$a" "-> transactional-update --continue $verb"
  else
    note_fail "os/opensuse.zsh: no transactional override of '$a' as 'sudo transactional-update … --continue … $verb' — without --continue each call opens its snapshot from the BOOTED one and drops the pending snapshot"
  fi
done

# ── 6. the WSL predicate is Core's, not this layer's ─────────────────────────
# os/opensuse.zsh gates its WSL-only aliases (open/xdg-open/cdwin) on a WSL question that
# Core answers: _core_is_wsl in core/zsh/00-tools.zsh (dotfiles-core#449). Six OS repos
# each carried a private copy of that detection until #179, and the reusable lint
# workflow's Core-owned-block leg is flipping from a warning to a failure once they are
# gone. This asserts both halves locally, before that flip: the private copy stays gone,
# AND the Core call is still there — delete the block without rewiring its consumer and
# the aliases go quiet on every WSL box with no error to say so.
#
# The pattern is the leg's own (core/scripts/lib/common.sh :: _core_owned_block_hits,
# rule `wsl-detect`), minus its comment-line skip; keep prose about the kernel version
# file out of os/opensuse.zsh rather than teaching this grep to skip comments.
say "os/opensuse.zsh asks Core whether this is WSL"
if grep -qE '/proc/version|(^|[^[:alnum:]_])_IS_WSL[[:space:]]*=' os/opensuse.zsh; then
  note_fail "os/opensuse.zsh re-implements WSL detection — Core owns it (core/zsh/00-tools.zsh :: _core_is_wsl); use 'if _core_is_wsl; then' (#179)"
else
  printf '  %s\n' "no local WSL detection"
fi
if grep -qE '(^|[^[:alnum:]_])_core_is_wsl($|[^[:alnum:]_])' os/opensuse.zsh; then
  printf '  %s\n' "_core_is_wsl is called"
else
  note_fail "os/opensuse.zsh never calls _core_is_wsl — the WSL-only aliases (open/xdg-open/cdwin) have no predicate gating them"
fi

# ── 7. the transactional edition: a Tumbleweed base through the snapshot verbs ──
# The third declaration differs from Tumbleweed's in exactly three ways — verbs that go
# through transactional-update, three keys added, two dropped — and is otherwise the same
# file. Every assertion here is a value measured on a booted MicroOS guest (dotfiles-core
# NON-MUTABLE-HOST-PROPOSAL.md §5 R2/R4/R5), not a preference.
say "the transactional edition — PROVISIONER and the snapshot verbs"
m_prov="$(cap_get "$MICROOS_DUMP" PROVISIONER)" || m_prov=""
if [[ "$m_prov" != transactional ]]; then
  note_fail "$MICROOS: PROVISIONER is '${m_prov:-absent}', expected 'transactional' — it is the key Core's up/nudge/maint/core-doctor branch on to say 'staged — reboot to apply' instead of running the verb"
else
  printf '  %-12s %s\n' "PROVISIONER" "$m_prov"
fi
m_up="$(cap_get "$MICROOS_DUMP" PKG_UPGRADE)" || m_up=""
if [[ ! "$m_up" =~ transactional-update[[:space:]]+dup([[:space:]]|$) ]]; then
  note_fail "$MICROOS: PKG_UPGRADE is '${m_up:-absent}' — the transactional edition is a Tumbleweed base (ID_LIKE says so) and stages 'transactional-update dup'; 'up' half-updates it and bare 'zypper' is refused (rc 5)"
else
  printf '  %-12s %s\n' "PKG_UPGRADE" "$m_up"
fi
m_in="$(cap_get "$MICROOS_DUMP" PKG_INSTALL)" || m_in=""
if [[ ! "$m_in" =~ transactional-update[[:space:]]+-n[[:space:]]+pkg[[:space:]]+in([[:space:]]|$) ]]; then
  note_fail "$MICROOS: PKG_INSTALL is '${m_in:-absent}' — must be 'transactional-update -n pkg in' (-n BEFORE the command: options precede the verb, and the key requires non-interactive)"
else
  printf '  %-12s %s\n' "PKG_INSTALL" "$m_in"
fi
m_rm="$(cap_get "$MICROOS_DUMP" PKG_REMOVE)" || m_rm=""
if [[ ! "$m_rm" =~ transactional-update[[:space:]]+-n[[:space:]]+pkg[[:space:]]+rm([[:space:]]|$) ]]; then
  note_fail "$MICROOS: PKG_REMOVE is '${m_rm:-absent}' — must be 'transactional-update -n pkg rm'"
else
  printf '  %-12s %s\n' "PKG_REMOVE" "$m_rm"
fi
for k in PKG_APPLY PKG_APPLY_PENDING; do
  if v="$(cap_get "$MICROOS_DUMP" "$k")"; then
    printf '  %-12s %s\n' "$k" "$v"
  else
    note_fail "$MICROOS declares no $k — a staged host without the apply verb / the staged probe leaves 'up' and the nudge unable to say a reboot is waiting"
  fi
done
if cap_get "$MICROOS_DUMP" MAINT_UNATTENDED_UPGRADE >/dev/null; then
  note_fail "$MICROOS declares MAINT_UNATTENDED_UPGRADE — MicroOS ships its own transactional-update.timer and health-checker rollback; Core's runner must not stage a second dup beside it"
else
  printf '  %-12s %s\n' "unattended" "absent (correct — MicroOS runs its own timer)"
fi
for k in $MICROOS_DROPPED; do
  if v="$(cap_get "$MICROOS_DUMP" "$k")"; then
    note_fail "$MICROOS declares $k='$v' — dropped on the transactional edition (options go BEFORE the verb so 'up -y' cannot append -y, and a snapshot is all-or-nothing)"
  else
    printf '  %-12s %s\n' "$k" "absent (correct)"
  fi
done
# Exempting a key from the identical-values sweep must not also exempt it from EXISTING:
# a file that quietly dropped it would then pass here while the warnings it suppresses came
# back on that edition alone.
for k in $MICROOS_DIVERGENT_NONVERB; do
  t="$(cap_get "$TW_DUMP" "$k")" || t=""
  m="$(cap_get "$MICROOS_DUMP" "$k")" || m=""
  [[ -n "$t" ]] || note_fail "$TW declares no $k — it is a declared divergence, not an optional key here"
  [[ -n "$m" ]] || note_fail "$MICROOS declares no $k — it is a declared divergence, not an optional key here"
  [[ -z "$t" || -z "$m" ]] || printf '  %-12s %s\n' "$k" "tw '$t' | transactional '$m'"
done

# ── 8. every OTHER key matches the Tumbleweed file, both directions ──────────
# The same load-bearing check as section 3, for the third file: individually valid, and
# kept in step by hand.
say "the remaining keys — identical to the Tumbleweed declaration"
m_diverged=0
while IFS= read -r k; do
  [[ -n "$k" ]] || continue
  case " $MICROOS_DIVERGENT $MICROOS_DIVERGENT_NONVERB $MICROOS_DROPPED " in *" $k "*) continue ;; esac
  a="$(cap_get "$TW_DUMP" "$k")" || a=""
  if ! b="$(cap_get "$MICROOS_DUMP" "$k")"; then
    note_fail "$k is declared in $TW but not in $MICROOS — every key but $MICROOS_DIVERGENT $MICROOS_DROPPED must exist in both"
    m_diverged=1
    continue
  fi
  if [[ "$a" != "$b" ]]; then
    note_fail "$k differs but is not a declared transactional divergence: Tumbleweed '$a' vs transactional '$b'"
    m_diverged=1
  fi
done < <(cap_keys "$TW_DUMP")
while IFS= read -r k; do
  [[ -n "$k" ]] || continue
  case " $MICROOS_DIVERGENT $MICROOS_DIVERGENT_NONVERB $MICROOS_ADDED " in *" $k "*) continue ;; esac
  cap_get "$TW_DUMP" "$k" >/dev/null || {
    note_fail "$k is declared in $MICROOS but not in $TW — only $MICROOS_ADDED may be added there"
    m_diverged=1
  }
done < <(cap_keys "$MICROOS_DUMP")
((m_diverged)) || printf '  %s\n' "the transactional declaration agrees with Tumbleweed's on every key outside its declared delta"

# ── 9. the transactional split is reachable, and it chains ───────────────────
# The ID cannot pick this file (MicroOS says ID_LIKE=tumbleweed), so bootstrap.sh tests
# the host: the verb on PATH beside a read-only /usr, with a CI seam that forces it in a
# container. And the one hazard that lost 47 packages on the research guest: every
# transactional-update invocation must carry --continue, or it opens its snapshot from
# the BOOTED one and drops the pending one. The invocation form is `transactional-update
# -n …` (options before the command), which is also what the operator retry hints print;
# the `command -v` probe, the comments and the prose lines never carry `-n`.
say "bootstrap.sh still picks the transactional edition"
if grep -qE 'command -v transactional-update.*-w /usr' bootstrap.sh; then
  printf '  %s\n' "host marker present (transactional-update on PATH, /usr read-only)"
else
  note_fail "bootstrap.sh no longer tests for transactional-update beside a read-only /usr — nothing picks $MICROOS, and every MicroOS box gets Tumbleweed's 'zypper in', which the host refuses"
fi
if grep -qE 'BOOTSTRAP_PROVISIONER.*transactional' bootstrap.sh; then
  printf '  %s\n' "CI seam present (BOOTSTRAP_PROVISIONER=transactional)"
else
  note_fail "bootstrap.sh no longer honours BOOTSTRAP_PROVISIONER=transactional — the reusable's provisioner: leg (.github/workflows/bootstrap.yml) forces the staging path through it, and without it that leg tests the mutable branch"
fi
if grep -q "os/opensuse.microos.capabilities" bootstrap.sh; then
  printf '  %s\n' "relinks $MICROOS on a transactional box"
else
  note_fail "bootstrap.sh no longer references $MICROOS — the declaration is dead weight without the relink"
fi
if grep -qE 'transactional-update -n' bootstrap.sh; then
  missing="$(grep -nE 'transactional-update -n' bootstrap.sh | grep -v -- '--continue' || true)"
  if [[ -n "$missing" ]]; then
    note_fail "bootstrap.sh invokes transactional-update without --continue — each such call opens its snapshot from the BOOTED one and silently discards the pending snapshot (measured: 47 packages lost):"$'\n'"$missing"
  else
    printf '  %s\n' "every transactional-update invocation carries --continue"
  fi
else
  note_fail "bootstrap.sh never invokes 'transactional-update -n …' — the staging path is gone"
fi

# ── 10. the login shell is STAGED, not written to the running /etc (#199) ─────
# /etc is per-snapshot here, and a file changed in BOTH the pending snapshot and the
# running /etc keeps only the SNAPSHOT's copy after the reboot (measured, dotfiles-core run
# 35130669056). Core's blib_set_login_shell writes the RUNNING /etc — /etc/shells, then
# chsh — so on this edition it reports success and is discarded: the run says "default
# shell -> zsh" and the operator reboots into bash. bootstrap.sh takes the step over in
# bootstrap_wire_post_loader and tells the driver to skip Core's version. None of this is
# visible to check-capabilities.sh, which validates a declaration against a schema, and
# none of it is reachable from a container — .github/core-gates.txt says so.
say "the login shell is staged inside the snapshot, not written to the running /etc"
if grep -q '^bootstrap_wire_post_loader()' bootstrap.sh; then
  printf '  %s\n' "bootstrap_wire_post_loader present (blib_main calls it immediately before its login-shell step)"
else
  note_fail "bootstrap.sh defines no bootstrap_wire_post_loader — that hook is the only slot before Core's blib_set_login_shell, so the login shell goes back to writing an /etc the reboot discards (#199)"
fi
if grep -qE '^[[:space:]]*BOOTSTRAP_LOGIN_SHELL=0' bootstrap.sh; then
  printf '  %s\n' "sets BOOTSTRAP_LOGIN_SHELL=0 (Core's own step stands down)"
else
  note_fail "bootstrap.sh never sets BOOTSTRAP_LOGIN_SHELL=0 — Core's blib_set_login_shell then runs AFTER the staged change and appends /etc/shells + chsh on the RUNNING system, which is the write the reboot throws away"
fi
if grep -qE 'transactional-update -n .*--continue run sh -c' bootstrap.sh; then
  printf '  %s\n' "staged through 'run sh -c' inside the snapshot (zsh is resolved THERE)"
else
  note_fail "bootstrap.sh no longer stages the login-shell change with 'transactional-update … --continue run sh -c …' — resolving zsh and running chsh on the HOST cannot work on a first run (zsh exists only in the snapshot) and does not survive the reboot on any run"
fi
if grep -q 'blib_want zsh' bootstrap.sh; then
  printf '  %s\n' "mirrors Core's 'blib_want zsh' guard, so --skip=zsh suppresses the staged change too"
else
  note_fail "bootstrap.sh no longer asks blib_want zsh before staging — --skip=zsh / --only=nvim would still stage a chsh, which Core's blib_set_login_shell would not have done"
fi
# The gate's SECOND half: a snapshot pending from an EARLIER run. The probe is
# PKG_APPLY_PENDING's, and bootstrap.sh hardcodes it (it is bash, with no _core_cap to
# ask), so the two spellings must be held together or the gate silently stops firing.
m_pending="$(cap_get "$MICROOS_DUMP" PKG_APPLY_PENDING)" || m_pending=""
if [[ "$m_pending" != */run/reboot-needed* ]]; then
  note_fail "$MICROOS: PKG_APPLY_PENDING is '${m_pending:-absent}' — bootstrap.sh's login-shell gate hardcodes this key's /run/reboot-needed probe; changing one without the other leaves a doomed /etc write ungated"
elif grep -q '/run/reboot-needed' bootstrap.sh; then
  printf '  %s\n' "the gate reads PKG_APPLY_PENDING's probe (/run/reboot-needed) for a snapshot pending from an earlier run"
else
  note_fail "bootstrap.sh no longer probes /run/reboot-needed — a run that stages nothing itself (--links-only, or a re-run before the reboot) then writes a running /etc that the pending snapshot overwrites; installing zsh is exactly what puts /usr/bin/zsh in the SNAPSHOT's /etc/shells"
fi

echo
if ((${#fails[@]})); then
  bad "${#fails[@]} flavor-split finding(s):"
  printf '    %s\n' "${fails[@]}" >&2
  cat >&2 <<'EOF'

All three declarations document their own delta at length. If a divergence here is
INTENDED, say so in the files concerned and add the key to DIVERGENT (Leap) or to
MICROOS_DIVERGENT / MICROOS_DIVERGENT_NONVERB / MICROOS_ADDED / MICROOS_DROPPED (the
transactional edition) in this
test; if it is not, the fix is to bring the files back into step by hand.
EOF
  exit 2
fi
ok "the three capability declarations differ in exactly the declared ways."
