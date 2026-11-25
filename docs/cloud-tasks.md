# Working on The Merrow Deep from a cloud task

For sessions that have no Godot or GPU: Claude Duet tasks and other cloud threads. They write the
code and push it; the TrueNAS dev box tests it (`rfs-ci`, see the README's "Box CI" section) in the
same slots and memory cap as the box's own sessions, and reports back on the pull request.
These rules are meant to go into TheMerrowDeep's `docs/AGENT_WORK.md`.

## Rules

- **Never download the Git LFS files.** Clone with `GIT_LFS_SKIP_SMUDGE=1 git clone --depth 1 ...`
  and never run `git lfs pull`: every cloud clone that pulls them spends the account's LFS
  bandwidth (the free 10 GB ran out on 12 Nov 2026). The box already has every file.
- **Don't run Godot, Blender or the test suites here.** There is no toolchain in a cloud task and
  `tools/bootstrap.sh` would download gigabytes. Python checks that need neither are fine.
- **Avoid adding big binary assets from the cloud.** They count against LFS storage (100% of the
  free 10 GB on 13 Nov 2026); asset work belongs on the box or the PC.
- **Push a branch and open a pull request** to `main` as the repo's rules say. Every push is tested
  on the box: the newest push of each pull request, one run at a time, queued behind the box's
  other runs.
- **Pick the suite with a trailer** on the last commit of a push (its own paragraph at the end of
  the message):
  - no trailer: the landing suite (`tools/test.sh landing`), reported as `box/landing`.
  - `Box-Test: lobby` (a suite folder, a test name, `tools` or `assets`): just that, as `box/test`.
    Use it while you work: run the tests of what you touched.
  - `Box-Test: none`: nothing (work in progress).
  `all`, `quick` and `slow` aren't run on their own: landing runs them.
- **Read the result** on the pull request: the `box/landing` or `box/test` check on the head commit
  (`gh api repos/derekhearst/TheMerrowDeep/commits/SHA/status`), and the "TrueNAS box tests"
  comment, which has the end of the log when a run fails. A pending check means it is queued or
  running; the box may be busy for a while, so don't push again just to retry.
- **Before the last push, merge `main`** into your branch: the box tests your branch's head as it
  is, not merged with main.
- **Pictures:** add `Box-Shot: NAME` to the same last paragraph and commit
  `tools/ci_shots/NAME.txt`: the box runs its steps, one per line, each queued on its own
  (`tools/bpy.sh ...` to rebuild, `tools/shot.sh SCENE out/ci_shots/after --only=...`, and
  `tools/shot.sh SCENE out/ci_shots/before --before --only=...` for the same views from main;
  `tools/godot.sh --import` if a step needs it; nothing else). Every picture written under
  `out/ci_shots/` comes back in the "TrueNAS box tests" comment as a 1280 px JPG on the `pr-shots`
  branch (`ci/pr-N/SHA/`, `/` in its path as `__`), which you can fetch with
  `gh api repos/derekhearst/TheMerrowDeep/contents/ci/pr-N/SHA/FILE.jpg?ref=pr-shots`.
  `Box-Test: none` with it renders without testing. Bakes stay with the integrator.

## Who gets tested

Pull requests by `derekhearst` (the account cloud tasks push as) run by themselves. Anyone else's
needs the `box: test` label, added by someone with triage access; pull requests from forks never
run. `box: skip` turns a pull request off. A branch that a box session has checked out in its own
lane is left to that session, which runs its own tests.
