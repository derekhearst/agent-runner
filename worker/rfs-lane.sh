#!/bin/bash
# rfs-lane: one git worktree per RigForSilent lane, cheap to make and never left behind.
#   rfs-lane new LANE [BASE] [--branch NAME]
#                              ~/work/rfs-LANE on branch claude/rfs-LANE, or NAME (the remote branch
#                              if it exists, else a new one from BASE, default origin/main). The Godot
#                              cache and the LFS files are copy-on-write clones of the main
#                              checkout's, so a new lane costs a few GB rather than ~20.
#   rfs-lane seed [--if-stale] keeps ~/work/.rfs-seed, a checkout of origin/main with its Godot
#                              import done, and publishes its cache for `new` to clone. Run it after
#                              a landing (the dev box does it hourly when main has moved). Its import
#                              queues ahead of other runs (rfs-slot --first).
#   rfs-lane done LANE         removes the worktree once it is clean, pushed and in main.
#   rfs-lane prune             `done` for every lane; lists the ones it keeps and why.
#   rfs-lane list              the lanes with their state.
# New lanes only ever clone a published seed cache (~/work/.rfs-seed-caches/current): the last
# seed import that finished. A refresh imports in ~/work/.rfs-seed and publishes a copy-on-write
# copy only when it ends, so lanes made meanwhile still get the last good cache. Until 11 Nov a
# lane made mid-refresh got the main checkout's weeks-old cache and reimported ~3,500 assets.
# TMD_MAIN_CHECKOUT (or the old RFS_MAIN) is the main checkout (default ~/work/RigForSilent). `done --force` skips the in-main
# check (an abandoned lane) but never deletes uncommitted or unpushed work.
set -euo pipefail
# TMD_REFLINK=auto lets the copies below fall back to plain copies (tests on filesystems without reflinks).

main="${TMD_MAIN_CHECKOUT:-${RFS_MAIN:-$HOME/work/RigForSilent}}"
root="$(dirname "$main")"
git_main() { git -C "$main" "$@"; }

lane_dir() { echo "$root/rfs-$1"; }
seed="$root/.rfs-seed"
seed_commit="$root/.rfs-seed.commit"
caches="$root/.rfs-seed-caches"  # published seed caches: <time>-<commit>/.godot, `current` -> the newest

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

# The folder of the newest published seed cache (holding .godot and commit), or nothing.
published() {
  local d
  d="$(readlink -f "$caches/current" 2>/dev/null || true)"
  [ -n "$d" ] && [ -d "$d/.godot" ] && [ -s "$d/commit" ] && echo "$d"
}

# Publishes the seed's finished import: a copy-on-write copy under $caches, then `current` is
# switched to it in one rename, so a lane copying the old one is never cut short. Old copies are
# removed once no lane is copying (they hold $caches/.lock shared while they copy).
publish() {
  local commit="$1" new old
  mkdir -p "$caches"
  new="$caches/$(date +%Y%m%d-%H%M%S)-${commit:0:9}"
  if ! { mkdir -p "$new.part" && cp -a --reflink="${TMD_REFLINK:-always}" "$seed/game/.godot" "$new.part/.godot"; }; then
    rm -rf "$new.part"
    echo "rfs-lane: couldn't copy the seed's cache; lanes keep the last published one" >&2
    return 1
  fi
  echo "$commit" > "$new.part/commit"
  mv "$new.part" "$new"
  ln -sfn "$(basename "$new")" "$caches/current.new"
  mv -T "$caches/current.new" "$caches/current"
  (
    flock -n -x 9 || exit 0
    for old in "$caches"/*; do
      [ "$old" != "$new" ] && [ "$(basename "$old")" != current ] && rm -rf "$old"
    done
  ) 9>"$caches/.lock"
  echo "published the seed cache at ${commit:0:9}"
}

# The warm import cache a new lane starts from: the newest published seed cache. Never the main
# checkout's: it matches whatever that checkout last imported (25 Oct on 11 Nov). With nothing
# published yet (just after the change that brought publishing), a refresh that is running is
# waited for, up to TMD_SEED_WAIT minutes (60), and then an imported seed counts.
cache_source() {
  local p
  p="$(published)" && { echo "$p"; return; }
  [ -d "$seed/game/.godot" ] || return 1
  (
    exec 9>"$root/.rfs-seed.lock"
    flock -n 9 || { echo "waiting for the seed refresh to finish" >&2; flock -w $((${TMD_SEED_WAIT:-60} * 60)) 9; }
  ) || return 1
  p="$(published)" && { echo "$p"; return; }
  [ -s "$seed_commit" ] && echo "$seed/game"
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
    if [ ! -e "$dir/game/.godot" ]; then
      mkdir -p "$caches"
      (
        flock -s 9  # keeps `seed` from removing the copy we read
        if src="$(cache_source)"; then
          echo "import cache from the seed at $(cut -c1-9 "$src/commit" 2>/dev/null || cut -c1-9 "$seed_commit")"
          cp -a --reflink="${TMD_REFLINK:-always}" "$src/.godot" "$dir/game/.godot" \
            || { rm -rf "$dir/game/.godot"; echo "no reflink copy of game/.godot; the first import fills it" >&2; }
        else
          echo "rfs-lane: no seed cache yet, so this lane's first import is a full one (an hour or" \
            "more). Run \`rfs-lane seed\` first if you can wait for it." >&2
        fi
      ) 9>"$caches/.lock"
    fi
    echo "$dir on $branch"
    ;;
  seed)
    exec 9>"$root/.rfs-seed.lock"
    flock -n 9 || { echo "a seed refresh is already running" >&2; exit 0; }
    git_main fetch -q origin main
    target="$(git_main rev-parse origin/main)"
    # A seed imported before publishing existed: publish it as it is first.
    if ! published >/dev/null && [ -s "$seed_commit" ] && [ -d "$seed/game/.godot" ]; then
      publish "$(cat "$seed_commit")" || true
    fi
    if [ "${1:-}" = --if-stale ] && [ "$(cat "$seed_commit" 2>/dev/null)" = "$target" ]; then exit 0; fi
    rm -f "$seed_commit"
    if [ ! -e "$seed/.git" ]; then
      GIT_LFS_SKIP_SMUDGE=1 git_main worktree add -q --detach "$seed" "$target"
      # Start from a published cache (else the main checkout's) so the import only redoes what differs.
      from="$(published || echo "$main/game")"
      [ ! -d "$from/.godot" ] || cp -a --reflink="${TMD_REFLINK:-always}" "$from/.godot" "$seed/game/.godot" || true
    else
      GIT_LFS_SKIP_SMUDGE=1 git -C "$seed" checkout -q --force --detach "$target"
      git -C "$seed" clean -q -fd -e game/.godot
    fi
    lfs_files "$seed"
    fix_index "$seed"
    echo "importing the seed at $(git -C "$seed" log -1 --format='%h %s')"
    # A first seed import can redo ~1,000 assets, past rfs.py's 30 min default; Godot keeps what
    # it finished, so a timed-out import resumes on the next refresh.
    # Ahead of every other queued run (rfs-slot --first), and never giving up its place: lanes
    # made while it waits still get the last published cache, but they drift further behind main.
    (cd "$seed" && t="${TMD_SEED_TIMEOUT:-${RFS_SEED_TIMEOUT:-120}}" \
      && TMD_TIMEOUT="$t" RFS_TIMEOUT="$t" TMD_SLOT_MAX_WAIT=0 rfs-slot --first tools/godot.sh --import)
    echo "$target" > "$seed_commit"
    publish "$target" || true
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
