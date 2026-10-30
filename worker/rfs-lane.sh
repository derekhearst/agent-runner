#!/bin/bash
# rfs-lane: one git worktree per RigForSilent lane, cheap to make and never left behind.
#   rfs-lane new LANE [BASE] [--branch NAME]
#                              ~/work/rfs-LANE on branch claude/rfs-LANE, or NAME (the remote branch
#                              if it exists, else a new one from BASE, default origin/main). The Godot
#                              cache and the LFS files are copy-on-write clones of the main
#                              checkout's, so a new lane costs a few GB rather than ~20.
#   rfs-lane seed [--if-stale] keeps ~/work/.rfs-seed, a checkout of origin/main with its Godot
#                              import done, for `new` to clone. Run it after a landing (the dev box
#                              does it hourly when main has moved).
#   rfs-lane done LANE         removes the worktree once it is clean, pushed and in main.
#   rfs-lane prune             `done` for every lane; lists the ones it keeps and why.
#   rfs-lane list              the lanes with their state.
# TMD_MAIN_CHECKOUT (or the old RFS_MAIN) is the main checkout (default ~/work/RigForSilent). `done --force` skips the in-main
# check (an abandoned lane) but never deletes uncommitted or unpushed work.
set -euo pipefail

main="${TMD_MAIN_CHECKOUT:-${RFS_MAIN:-$HOME/work/RigForSilent}}"
root="$(dirname "$main")"
git_main() { git -C "$main" "$@"; }

lane_dir() { echo "$root/rfs-$1"; }
seed="$root/.rfs-seed"
seed_commit="$root/.rfs-seed.commit"

# LFS files as reflinks of the objects the repo already has (downloading what's missing).
lfs_files() {
  git -C "$1" lfs pull >/dev/null && git -C "$1" lfs dedup >/dev/null || echo "lfs dedup skipped" >&2
}

# Files git calls modified only because the index still holds the LFS pointer's size: the
# worktree is checked out without smudging, then `lfs pull` and `dedup` rewrite the files with
# the same content. Re-record those (nothing gets staged: they clean to the committed blobs).
fix_index() {
  local dir="$1"
  comm -23 <(git -C "$dir" ls-files -m | sort -u) <(git -C "$dir" diff --name-only | sort -u) \
    | tr '\n' '\0' | git -C "$dir" add --renormalize --pathspec-from-file=- --pathspec-file-nul 2>/dev/null \
    || true
}

# The warm import cache a new lane starts from: the seed's when it has been imported, else the
# main checkout's (which matches whatever branch that checkout is on, so expect more reimports).
# While the seed is being refreshed its cache is half-updated, so use the main checkout's then.
cache_source() {
  if [ -s "$seed_commit" ] && [ -d "$seed/game/.godot" ] \
    && (exec 9>"$root/.rfs-seed.lock" && flock -n 9); then
    echo "$seed"
  else
    echo "$main"
  fi
}

# Why a lane can't go yet (empty when it can). $2 = "force" skips the in-main check.
blocker() {
  local dir="$1" force="${2:-}" branch
  branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD)"
  fix_index "$dir"
  [ -z "$(git -C "$dir" status --porcelain)" ] || { echo "uncommitted changes"; return; }
  git -C "$dir" rev-parse -q --verify "origin/$branch" >/dev/null || { echo "branch never pushed"; return; }
  [ "$(git -C "$dir" rev-list --count "origin/$branch..HEAD")" = 0 ] || { echo "unpushed commits"; return; }
  [ "$force" = force ] && return
  git -C "$dir" merge-base --is-ancestor HEAD origin/main && return
  # Squash merges leave no ancestry; ask GitHub.
  if command -v gh >/dev/null \
    && [ -n "$(cd "$dir" && gh pr list --head "$branch" --state merged --json number -q '.[].number' 2>/dev/null)" ]; then
    return
  fi
  echo "not in main yet"
}

remove() {
  local dir="$1" branch
  branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD)"
  git_main worktree remove --force "$dir"
  git_main branch -D "$branch" >/dev/null 2>&1 || true
  echo "removed $dir ($branch)"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  new)
    lane="${1:?usage: rfs-lane new LANE [BASE] [--branch NAME]}" base="origin/main" branch="claude/rfs-$lane"
    shift
    while [ $# -gt 0 ]; do
      case "$1" in
        --branch) branch="${2:?--branch needs a name}"; shift 2 ;;
        *) base="$1"; shift ;;
      esac
    done
    dir="$(lane_dir "$lane")"
    [ ! -e "$dir" ] || { echo "$dir already exists" >&2; exit 1; }
    git_main fetch -q origin main
    git_main fetch -q origin "$branch" 2>/dev/null || true
    if git_main rev-parse -q --verify "origin/$branch" >/dev/null; then
      GIT_LFS_SKIP_SMUDGE=1 git_main worktree add -B "$branch" "$dir" "origin/$branch"
    else
      GIT_LFS_SKIP_SMUDGE=1 git_main worktree add -b "$branch" "$dir" "$base"
    fi
    git -C "$dir" branch -q --set-upstream-to="origin/$branch" 2>/dev/null || true
    # LFS files and the import cache as reflinks of what the main checkout already has.
    lfs_files "$dir"
    fix_index "$dir"
    src="$(cache_source)"
    if [ -d "$src/game/.godot" ] && [ ! -e "$dir/game/.godot" ]; then
      echo "import cache from $src ($(git -C "$src" log -1 --format=%h))"
      cp -a --reflink=always "$src/game/.godot" "$dir/game/.godot" \
        || { rm -rf "$dir/game/.godot"; echo "no reflink copy of game/.godot; the first import fills it" >&2; }
    fi
    echo "$dir on $branch"
    ;;
  seed)
    exec 9>"$root/.rfs-seed.lock"
    flock -n 9 || { echo "a seed refresh is already running" >&2; exit 0; }
    git_main fetch -q origin main
    target="$(git_main rev-parse origin/main)"
    if [ "${1:-}" = --if-stale ] && [ "$(cat "$seed_commit" 2>/dev/null)" = "$target" ]; then exit 0; fi
    rm -f "$seed_commit"
    if [ ! -e "$seed/.git" ]; then
      GIT_LFS_SKIP_SMUDGE=1 git_main worktree add -q --detach "$seed" "$target"
      # Start from the main checkout's cache so the first import only redoes what differs.
      [ ! -d "$main/game/.godot" ] || cp -a --reflink=always "$main/game/.godot" "$seed/game/.godot" || true
    else
      GIT_LFS_SKIP_SMUDGE=1 git -C "$seed" checkout -q --force --detach "$target"
      git -C "$seed" clean -q -fd -e game/.godot
    fi
    lfs_files "$seed"
    fix_index "$seed"
    echo "importing the seed at $(git -C "$seed" log -1 --format='%h %s')"
    # A first seed import can redo ~1,000 assets, past rfs.py's 30 min default; Godot keeps what
    # it finished, so a timed-out import resumes on the next refresh.
    (cd "$seed" && t="${TMD_SEED_TIMEOUT:-${RFS_SEED_TIMEOUT:-120}}" && TMD_TIMEOUT="$t" RFS_TIMEOUT="$t" rfs-slot tools/godot.sh --import)
    echo "$target" > "$seed_commit"
    echo "seed ready at ${target:0:9}"
    ;;
  done)
    lane="${1:?usage: rfs-lane done LANE [--force]}"
    dir="$(lane_dir "$lane")"
    [ -d "$dir" ] || { echo "no lane at $dir" >&2; exit 1; }
    git_main fetch -q origin
    why="$(blocker "$dir" "$([ "${2:-}" = --force ] && echo force)")"
    [ -z "$why" ] || { echo "kept $dir: $why" >&2; exit 1; }
    remove "$dir"
    ;;
  prune|list)
    git_main fetch -q origin
    git_main worktree prune
    for dir in "$root"/rfs-*; do
      [ -e "$dir/.git" ] || continue
      why="$(blocker "$dir")"
      if [ "$cmd" = list ]; then
        echo "$(basename "$dir")  $(git -C "$dir" rev-parse --abbrev-ref HEAD)  ${why:-landed}"
      elif [ -z "$why" ]; then
        remove "$dir"
      else
        echo "kept $dir: $why"
      fi
    done
    ;;
  *)
    sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
