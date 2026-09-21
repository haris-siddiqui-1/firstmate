#!/usr/bin/env bash
# Refresh project clones: fast-forward the checked-out branch to its own upstream
# when safe, or to the declared development base when the checkout sits on the
# declared development branch, and prune local branches whose upstream tracking
# branch is gone (the remote branch was deleted, i.e. its PR merged) and that no
# worktree still needs.
# Self-heals the one unambiguously safe drift: a clean, detached HEAD that holds
# no unique commits (it is an ancestor of the development base) and whose default
# branch is free to check out is re-attached and then fast-forwarded ("recovered:").
# A clean clone on a named branch (default or not) fast-forwards to that branch's
# own upstream when strictly behind it, except a checkout on the declared
# development branch, which fast-forwards to the development base instead. Every
# other unsafe state - a dirty tree, a branch with no upstream or whose upstream
# is gone, a detached HEAD with unique commits, or a branch genuinely diverged
# from its target - may hold real work, so it is left untouched and reported as a
# loud "STUCK: ... - needs attention" warning (quantified against that branch's
# own upstream, or against the development base for detached HEADs) rather than a
# quiet drift. Nothing is ever forced, stashed, or discarded.
# Still skips (benignly) local-only/no-origin projects, missing remotes/branches,
# and fetch failures.
# A candidate under projects/ must be the root of its own work tree: git discovery
# walks up, so a plain nested directory would otherwise resolve to the enclosing
# repository (the firstmate checkout) and be synced under that directory's label.
# Anything else is reported as "skipped: not a clone root" naming the repository
# that would have been touched.
# Pruning never deletes the checked-out branch or a branch that still has a
# worktree, so it cannot discard unlanded work; set FM_FLEET_PRUNE=0 to disable it.
# When the fetch fails on an orphaned .git/packed-refs.lock (left by a ref rewrite
# killed mid-write - e.g. a timed-out bootstrap sync or a teardown process kill),
# it is retried with a bounded wait and removed only when provably stale; see
# fetch_with_packed_refs_lock_guard and the FM_FLEET_SYNC_PACKED_REFS_LOCK_* knobs.
# Usage: fm-fleet-sync.sh [<project-dir-or-name>]
# The single-project form accepts either a path (absolute, or relative to the
# caller's cwd) or a bare "<name>"/"projects/<name>" form, resolved against
# this home's projects dir ($FM_HOME/projects, or $FM_PROJECTS_OVERRIDE).
# Bare names and "projects/<name>" forms prefer this home's projects dir before
# falling back to an explicit path. Example: from anywhere,
# `fm-fleet-sync.sh dotfiles-private` syncs just that one clone, same as
# passing its full projects/dotfiles-private path.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"
# Inert unless FM_TIMING_LOG names a file; only the deferred network stage sets it.
# shellcheck source=bin/fm-timing-lib.sh
. "$SCRIPT_DIR/fm-timing-lib.sh"
FM_LOCK_LOG_PREFIX=fleet-sync
"$FM_ROOT/bin/fm-guard.sh" || true

# Bounded recovery for an orphaned .git/packed-refs.lock. A git ref rewrite
# (fetch --prune, branch -D, pack-refs) killed after creating the lock but before
# renaming it - e.g. bootstrap's fleet-sync timeout kill, or teardown's process
# kills - leaves a lock that makes the next sync's fetch fail with Git's
# "Unable to create '...packed-refs.lock': File exists". These knobs bound the
# patience-then-provably-stale-clear recovery; see fetch_with_packed_refs_lock_guard.
FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=${FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES:-3}
FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=${FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS:-1}
FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=${FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS:-30}
case "$FLEET_SYNC_PACKED_REFS_LOCK_RETRIES" in ''|*[!0-9]*) FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=3 ;; esac
case "$FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS" in ''|*[!0-9]*) FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=30 ;; esac
if ! [[ "$FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]]; then
  echo "fleet-sync: invalid packed-refs lock retry wait '$FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS'; using 1s" >&2
  FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=1
fi

usage() {
  echo "usage: fm-fleet-sync.sh [<project-dir-or-name>]" >&2
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
[ $# -le 1 ] || { usage; exit 1; }

project_label() {
  case "$PROJ" in
    "$PROJECTS"/*) basename "$PROJ" ;;
    projects/*) basename "$PROJ" ;;
    *) printf '%s\n' "$PROJ" ;;
  esac
}

# resolve_project_arg <arg>: accept a path (used as-is when it already exists)
# or a bare/"projects/<name>" project name, resolved against $PROJECTS. Falls
# back to the original argument unresolved so a genuinely bad path still hits
# sync_project's existing "not a directory" skip.
resolve_project_arg() {
  local arg=$1 candidate
  case "$arg" in
    projects/*)
      candidate="$PROJECTS/${arg#projects/}"
      if [ -d "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
      fi
      ;;
    */*)
      if [ -d "$arg" ]; then
        printf '%s\n' "$arg"
        return 0
      fi
      ;;
    *)
      candidate="$PROJECTS/$arg"
      if [ -d "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
      fi
      if [ -d "$arg" ]; then
        printf '%s\n' "$arg"
        return 0
      fi
      ;;
  esac
  printf '%s\n' "$arg"
}

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

first_line() {
  printf '%s\n' "$1" | sed -n '1s/[[:space:]]\{1,\}/ /g;1p'
}

# True when git stderr shows the packed-refs.lock "File exists" race. The lock
# path can appear anywhere in the message (git prefixes it with the failed ref op,
# e.g. "could not delete reference ...:"). Other "File exists" errors must not match.
is_packed_refs_lock_error() {
  printf '%s\n' "$1" | grep -Eq "Unable to create ['\"].*packed-refs\\.lock['\"]: File exists"
}

# Absolute path to $PROJ's packed-refs.lock, or empty when it cannot be resolved.
packed_refs_lock_path() {
  local lock abs
  lock=$(git -C "$PROJ" rev-parse --git-path packed-refs.lock 2>/dev/null) || return 1
  [ -n "$lock" ] || return 1
  case "$lock" in
    /*) printf '%s\n' "$lock" ;;
    *)
      abs=$(cd "$PROJ" && pwd -P) || return 1
      printf '%s/%s\n' "$abs" "$lock"
      ;;
  esac
}

# Run `git -C "$PROJ" fetch origin --prune --quiet`, tolerating an orphaned
# packed-refs.lock left by a killed ref rewrite. Sets FETCH_OUTPUT to the git
# command's combined output and returns its exit status. On the packed-refs.lock
# signature ONLY: retry up to FLEET_SYNC_PACKED_REFS_LOCK_RETRIES times (a
# transient lock self-clears as the owning process exits), then - only if the lock
# is provably stale per fm-lock-lib.sh (still present, mtime age past the
# threshold, no lsof holder of the lock or the clone worktree $PROJ) - remove it
# and retry once more. A live lock, an unprovable one, or any other failure keeps
# today's behavior. Every wait, retry, and removal prints to stderr, and a
# successful recovery also prints one "$label: recovered: ..." summary to stdout so
# a session-start refresh (which discards fleet-sync stderr) still surfaces it.
fetch_with_packed_refs_lock_guard() {
  local rc attempt=0 lock lock_desc
  FETCH_OUTPUT=$(git -C "$PROJ" fetch origin --prune --quiet 2>&1); rc=$?
  [ "$rc" -eq 0 ] && return 0
  is_packed_refs_lock_error "$FETCH_OUTPUT" || return "$rc"

  lock=$(packed_refs_lock_path) || lock=""
  lock_desc=${lock:-packed-refs.lock}
  while [ "$attempt" -lt "$FLEET_SYNC_PACKED_REFS_LOCK_RETRIES" ]; do
    attempt=$(( attempt + 1 ))
    echo "$label: fetch blocked by packed-refs lock ($lock_desc); waiting ${FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS}s and retrying ($attempt/${FLEET_SYNC_PACKED_REFS_LOCK_RETRIES}) (owning process may be exiting)" >&2
    sleep "$FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS"
    FETCH_OUTPUT=$(git -C "$PROJ" fetch origin --prune --quiet 2>&1); rc=$?
    if [ "$rc" -eq 0 ]; then
      echo "$label: fetch succeeded on retry; packed-refs lock cleared on its own" >&2
      # One stdout summary so a session-start refresh (which discards fleet-sync
      # stderr and relays only stdout) still surfaces the recovery.
      echo "$label: recovered: packed-refs lock cleared on its own during retry"
      return 0
    fi
    is_packed_refs_lock_error "$FETCH_OUTPUT" || return "$rc"
  done

  # Retries exhausted and still the lock signature. Clear ONLY if provably stale.
  # The companion liveness dir is $PROJ (the clone worktree): a live `git -C "$PROJ"`
  # keeps its cwd there even in the narrow window after it closes packed-refs.lock
  # and before it exits, so lsof on $PROJ still catches a holder the lock-file check
  # alone would miss.
  lock=$(packed_refs_lock_path) || lock=""
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    if fm_lock_is_provably_stale "$lock" "$PROJ" "$FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS"; then
      if ! rm -f "$lock"; then
        echo "$label: failed to remove provably-stale packed-refs lock $lock; leaving it in place" >&2
        return "$rc"
      fi
      echo "$label: removed provably-stale packed-refs lock $lock (age >= ${FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS}s, no live holder) and retrying fetch" >&2
      FETCH_OUTPUT=$(git -C "$PROJ" fetch origin --prune --quiet 2>&1); rc=$?
      if [ "$rc" -eq 0 ]; then
        echo "$label: fetch succeeded after stale packed-refs lock cleanup" >&2
        echo "$label: recovered: removed a stale packed-refs lock (no live holder)"
        return 0
      fi
      return "$rc"
    fi
    echo "$label: fetch blocked by packed-refs lock $lock that persisted across ${FLEET_SYNC_PACKED_REFS_LOCK_RETRIES} retries and is not provably stale (may belong to a live process); leaving it in place" >&2
    return "$rc"
  fi
  echo "$label: fetch packed-refs lock signature persisted across ${FLEET_SYNC_PACKED_REFS_LOCK_RETRIES} retries even after the lock file disappeared" >&2
  return "$rc"
}

prune_gone_branches() {
  # Delete local branches whose upstream tracking branch is gone - the remote
  # branch was deleted, which in this fleet means its PR merged - as long as
  # nothing still needs them. Never the checked-out branch, and never a branch
  # that still has a worktree (a live or not-yet-torn-down task). "Gone" plus
  # "no worktree" already proves the work landed: teardown removes a branch's
  # worktree only after confirming the work reached the remote. We deliberately
  # do NOT also require the branch to be an ancestor of origin/<default> - PRs in
  # this fleet are squash-merged, so a merged branch is never an ancestor and
  # such a check would prune nothing. The no-worktree guard is the real safety
  # net. Set FM_FLEET_PRUNE=0 to skip pruning entirely.
  [ "${FM_FLEET_PRUNE:-1}" != "0" ] || return 0

  local worktree_branches current refline branch track
  worktree_branches=$(git -C "$PROJ" worktree list --porcelain 2>/dev/null \
    | sed -n 's#^branch refs/heads/##p')
  current=$(git -C "$PROJ" symbolic-ref --quiet --short HEAD 2>/dev/null || true)

  while IFS= read -r refline; do
    branch=${refline%% *}
    track=${refline#* }
    [ "$track" = "[gone]" ] || continue
    [ -n "$branch" ] || continue
    [ "$branch" != "$current" ] || continue
    if printf '%s\n' "$worktree_branches" | grep -Fxq -- "$branch"; then
      continue
    fi
    if git -C "$PROJ" branch -D -- "$branch" >/dev/null 2>&1; then
      echo "$label: pruned $branch"
    fi
  done < <(git -C "$PROJ" for-each-ref \
    --format='%(refname:short) %(upstream:track)' refs/heads 2>/dev/null)
}

# True when some worktree of $PROJ has $DEFAULT checked out (so we cannot attach
# to it here). The current worktree is detached when this is consulted, so any
# match is necessarily another worktree.
default_checked_out_elsewhere() {
  git -C "$PROJ" worktree list --porcelain 2>/dev/null \
    | sed -n 's#^branch refs/heads/##p' \
    | grep -Fxq -- "$DEFAULT"
}

local_default_safe_for_recovery() {
  ! git -C "$PROJ" rev-parse --verify --quiet "$DEFAULT^{commit}" >/dev/null \
    || git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$BASE" 2>/dev/null
}

# Human-readable name for the unsafe state the clone is in, used in the STUCK
# warning. Reads $cur (current branch, empty when detached), $dirty, $UPSTREAM
# (that branch's own upstream, empty when none), and $UPSTREAM_GONE, plus the
# HEAD-vs-$BASE ancestry for detached HEADs.
stuck_state() {
  local s
  if [ -n "$cur" ]; then
    if [ -z "$UPSTREAM" ]; then
      s="branch $cur with no upstream"
    elif [ "$UPSTREAM_GONE" = yes ]; then
      s="branch $cur whose upstream is gone"
    else
      s="branch $cur"
    fi
  elif [ "$dirty" = yes ]; then
    s="detached HEAD"
  elif ! git -C "$PROJ" merge-base --is-ancestor HEAD "$BASE" 2>/dev/null; then
    s="detached HEAD with unique commits"
  elif default_checked_out_elsewhere; then
    s="detached HEAD ($DEFAULT checked out in another worktree)"
  elif ! local_default_safe_for_recovery; then
    s="detached HEAD (local $DEFAULT diverged from $BASE)"
  else
    s="detached HEAD"
  fi
  [ "$dirty" = no ] || s="$s with uncommitted changes"
  printf '%s\n' "$s"
}

# Loud, quantified report for a clone we deliberately leave untouched. Includes
# how far behind its own upstream (named branch) or the development base
# (detached HEAD) it is, so a chronically-stuck clone is visibly distinct from a
# benign one-off skip. A missing or gone upstream has no count to give, so it
# stays loud without one.
report_stuck() {
  local state=$1 behind
  if [ -n "$cur" ] && { [ -z "$UPSTREAM" ] || [ "$UPSTREAM_GONE" = yes ]; }; then
    echo "$label: STUCK: on $state - needs attention"
    return 0
  fi
  behind=$(git -C "$PROJ" rev-list --count "HEAD..$STUCK_BASE" 2>/dev/null) || behind="?"
  echo "$label: STUCK: on $state, $behind commits behind $STUCK_BASE - needs attention"
}

sync_project() {
  PROJ=$1
  label=$(project_label)

  if [ ! -d "$PROJ" ]; then
    echo "$label: skipped: not a directory"
    return 0
  fi
  # Git repository discovery walks UP from $PROJ, so a plain directory merely
  # nested inside a repository - a worktree container left under projects/, say -
  # resolves to the ENCLOSING repository, which in a firstmate home is the
  # firstmate checkout itself. Every later `git -C "$PROJ"` would then read, prune
  # and fast-forward that repository under this project's label, turning a routine
  # refresh into an unrequested self-update reported as a project sync. Require
  # $PROJ to be the root of its own work tree before any other git command runs.
  proj_top=$(git -C "$PROJ" rev-parse --show-toplevel 2>/dev/null) || proj_top=""
  if [ -z "$proj_top" ]; then
    echo "$label: skipped: not a git repo"
    return 0
  fi
  # Both sides are physical paths (git resolves --show-toplevel through symlinks),
  # so a symlinked clone dir still compares equal to its own root.
  proj_abs=$(cd "$PROJ" && pwd -P) || proj_abs=""
  if [ "$proj_top" != "$proj_abs" ]; then
    echo "$label: skipped: not a clone root (git would act on $proj_top)"
    return 0
  fi
  mode_line=$("$FM_ROOT/bin/fm-project-mode.sh" "$label" 2>/dev/null || echo "no-mistakes off")
  mode=${mode_line%% *}
  if [ "$mode" = "local-only" ]; then
    echo "$label: skipped: local-only project"
    return 0
  fi
  if ! git -C "$PROJ" remote get-url origin >/dev/null 2>&1; then
    echo "$label: skipped: no origin remote"
    return 0
  fi

  if ! fetch_with_packed_refs_lock_guard; then
    reason="fetch failed"
    if [ -n "$FETCH_OUTPUT" ]; then
      reason="$reason: $(first_line "$FETCH_OUTPUT")"
    fi
    echo "$label: skipped: $reason"
    return 0
  fi

  prune_gone_branches || true

  DEFAULT=$(default_branch) || {
    echo "$label: skipped: cannot determine default branch"
    return 0
  }
  if DEV_BRANCH=$("$FM_ROOT/bin/fm-project-dev-branch.sh" "$label" 2>/dev/null); then
    if [ -n "$DEV_BRANCH" ]; then
      if git -C "$PROJ" rev-parse --verify --quiet "origin/$DEV_BRANCH^{commit}" >/dev/null; then
        BASE="origin/$DEV_BRANCH"
      else
        echo "$label: skipped: declared development branch origin/$DEV_BRANCH does not exist"
        return 0
      fi
    else
      BASE="origin/$DEFAULT"
    fi
  else
    echo "$label: skipped: invalid development branch declaration"
    return 0
  fi
  if ! git -C "$PROJ" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null; then
    echo "$label: skipped: $BASE does not exist"
    return 0
  fi

  cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
  dirty=no
  [ -z "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ] || dirty=yes
  UPSTREAM=""
  UPSTREAM_GONE=no
  STUCK_BASE=$BASE

  if [ -n "$cur" ]; then
    # On a named branch - default or not. A declared development branch redirects
    # the target: a checkout on the declared branch is moved toward the
    # development base instead of its own upstream, so it tracks the line the
    # project develops on. Every other named branch keeps the fork behavior and
    # moves toward its own upstream. A dirty tree must not be disturbed; a missing
    # or gone upstream (undeclared path) has nothing safe to fast-forward to; a
    # branch that is not strictly behind its target (current or holding unique
    # commits) is left untouched.
    if [ -n "$DEV_BRANCH" ] && [ "$cur" = "$DEV_BRANCH" ]; then
      UPSTREAM=$BASE
    else
      UPSTREAM=$(git -C "$PROJ" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
    fi
    if [ -z "$UPSTREAM" ] || ! git -C "$PROJ" rev-parse --verify --quiet "$UPSTREAM^{commit}" >/dev/null 2>&1; then
      if [ -z "$DEV_BRANCH" ] || [ "$cur" != "$DEV_BRANCH" ]; then
        if git -C "$PROJ" for-each-ref --format='%(upstream:track)' "refs/heads/$cur" 2>/dev/null | grep -Fxq '[gone]'; then
          UPSTREAM=$(git -C "$PROJ" for-each-ref --format='%(upstream:short)' "refs/heads/$cur" 2>/dev/null)
          UPSTREAM_GONE=yes
        else
          UPSTREAM=""
        fi
      fi
      STUCK_BASE=$BASE
      report_stuck "$(stuck_state)"
      return 0
    fi
    STUCK_BASE=$UPSTREAM
    if [ "$dirty" = yes ]; then
      report_stuck "$(stuck_state)"
      return 0
    fi
    local_rev=$(git -C "$PROJ" rev-parse HEAD) || {
      echo "$label: skipped: cannot read local $cur"
      return 0
    }
    remote_rev=$(git -C "$PROJ" rev-parse "$UPSTREAM") || {
      echo "$label: skipped: cannot read $UPSTREAM"
      return 0
    }
    if [ "$local_rev" = "$remote_rev" ]; then
      echo "$label: already current"
      return 0
    fi
    if ! git -C "$PROJ" merge-base --is-ancestor HEAD "$UPSTREAM"; then
      if git -C "$PROJ" merge-base --is-ancestor "$UPSTREAM" HEAD 2>/dev/null; then
        report_stuck "branch $cur ahead of $UPSTREAM"
      else
        report_stuck "branch $cur diverged from $UPSTREAM"
      fi
      return 0
    fi
    before=$(git -C "$PROJ" rev-parse --short HEAD) || {
      echo "$label: skipped: cannot read local $cur"
      return 0
    }
    if ! merge_output=$(git -C "$PROJ" merge --ff-only "$UPSTREAM" 2>&1); then
      reason="fast-forward failed"
      if [ -n "$merge_output" ]; then
        reason="$reason: $(first_line "$merge_output")"
      fi
      echo "$label: skipped: $reason"
      return 0
    fi
    after=$(git -C "$PROJ" rev-parse --short HEAD) || {
      echo "$label: skipped: fast-forward completed but cannot read local $cur"
      return 0
    }
    echo "$label: synced $before..$after"
    return 0
  fi

  # Detached HEAD. Auto-recover only the one unambiguously safe drift: a clean
  # HEAD that holds no unique commits (it is an ancestor of the development
  # base) and whose default branch is free to check out here. Re-attaching to
  # an already-published commit strands nothing, and the fast-forward path
  if ! { [ "$dirty" = no ] \
      && git -C "$PROJ" merge-base --is-ancestor HEAD "$BASE" 2>/dev/null \
      && ! default_checked_out_elsewhere \
      && local_default_safe_for_recovery; }; then
    report_stuck "$(stuck_state)"
    return 0
  fi
  if ! git -C "$PROJ" checkout --quiet "$DEFAULT" 2>/dev/null; then
    report_stuck "$(stuck_state)"
    return 0
  fi
  cur=$DEFAULT
  UPSTREAM=$BASE
  STUCK_BASE=$BASE

  if ! git -C "$PROJ" rev-parse --verify --quiet "$DEFAULT^{commit}" >/dev/null; then
    echo "$label: skipped: local $DEFAULT does not exist"
    return 0
  fi

  local_rev=$(git -C "$PROJ" rev-parse "$DEFAULT") || {
    echo "$label: skipped: cannot read local $DEFAULT"
    return 0
  }
  remote_rev=$(git -C "$PROJ" rev-parse "$BASE") || {
    echo "$label: skipped: cannot read $BASE"
    return 0
  }
  if [ "$local_rev" = "$remote_rev" ]; then
    echo "$label: recovered: re-attached $DEFAULT (already current)"
    return 0
  fi
  if ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$BASE"; then
    report_stuck "diverged $DEFAULT"
    return 0
  fi

  before=$(git -C "$PROJ" rev-parse --short "$DEFAULT") || {
    echo "$label: skipped: cannot read local $DEFAULT"
    return 0
  }
  if ! merge_output=$(git -C "$PROJ" merge --ff-only "$BASE" 2>&1); then
    reason="fast-forward failed"
    if [ -n "$merge_output" ]; then
      reason="$reason: $(first_line "$merge_output")"
    fi
    echo "$label: skipped: $reason"
    return 0
  fi
  after=$(git -C "$PROJ" rev-parse --short "$DEFAULT") || {
    echo "$label: skipped: fast-forward completed but cannot read local $DEFAULT"
    return 0
  }
  echo "$label: recovered: re-attached $DEFAULT, synced $before..$after"
}

if [ $# -eq 1 ]; then
  sync_project "$(resolve_project_arg "$1")"
  exit 0
fi

[ -d "$PROJECTS" ] || exit 0
for proj in "$PROJECTS"/*; do
  [ -e "$proj" ] || continue
  [ -d "$proj" ] || continue
  # Per-clone elapsed, so a fleet refresh that runs long names WHICH clone cost
  # the time instead of only its total. Recording is a no-op unless the deferred
  # network stage asked for it.
  __fm_timing_stamp=$(fm_timing_now_ms)
  sync_project "$proj"
  fm_timing_record clone sync "$__fm_timing_stamp" "$(basename "$proj")"
done
