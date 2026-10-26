#!/bin/bash
# rfs-lane: one git worktree per RigForSilent lane, cheap to make and never left behind.
#   rfs-lane new LANE [BASE] [--branch NAME]
#                              ~/work/rfs-LANE on branch claude/rfs-LANE, or NAME (the remote branch
#                              if it exists, else a new one from BASE, default origin/main). The Godot
#                              cache and the LFS files are copy-on-write clones of the main
#                              checkout's, so a new lane costs a few GB rather than ~20.
#   rfs-lane done LANE         removes the worktree once it is clean, pushed and in main.
#   rfs-lane prune             `done` for every lane; lists the ones it keeps and why.
#   rfs-lane list              the lanes with their state.
# RFS_MAIN is the main checkout (default ~/work/RigForSilent). `done --force` skips the in-main
# check (an abandoned lane) but never deletes uncommitted or unpushed work.
set -euo pipefail

main="${RFS_MAIN:-$HOME/work/RigForSilent}"
root="$(dirname "$main")"
git_main() { git -C "$main" "$@"; }

lane_dir() { echo "$root/rfs-$1"; }

# Why a lane can't go yet (empty when it can). $2 = "force" skips the in-main check.
blocker() {
  local dir="$1" force="${2:-}" branch
  branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD)"
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
    git -C "$dir" lfs checkout >/dev/null && git -C "$dir" lfs dedup >/dev/null || echo "lfs dedup skipped" >&2
    if [ -d "$main/game/.godot" ] && [ ! -e "$dir/game/.godot" ]; then
      cp -a --reflink=always "$main/game/.godot" "$dir/game/.godot" \
        || { rm -rf "$dir/game/.godot"; echo "no reflink copy of game/.godot; the first import fills it" >&2; }
    fi
    echo "$dir on $branch"
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
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
