---
name: dag-branches
description: Branch setup for the Ark.Workflow (DAG) work, with spec and tests on common-test, Claude's implementation on impl-a, and the user's implementation on impl-b. Use whenever a session touches DAG-SPEC.md, test/ark/workflow, lib/ark/workflow*, or the branches common-test, impl-a or impl-b, or when the user asks to sync, rebase, or skip failing tests.
---

# Ark.Workflow branches

The spec (`DAG-SPEC.md`) and its test suite (`test/ark/workflow`) are shared by
two competing implementations. The branches are managed with git town:

```
main
  feat/dag
    common-test   spec and tests
      impl-a      Claude's implementation
      impl-b      the user's implementation
```

## common-test: spec and tests

- Every change to `DAG-SPEC.md`, `test/ark/workflow` or `test/support` goes
  here, never on an implementation branch.
- Commits are allowed on this branch.
- Run `mix format` before leaving the branch. Otherwise the formatting
  changes show up later as test changes on the implementation branches.
- The test files cannot run on this branch alone, since there is no
  implementation. Check that they parse, then run them on impl-a.

## impl-a: Claude's implementation

- Claude owns this branch and commits implementation changes here.
- After a change on common-test, rebase impl-a onto it and run
  `mix test test/ark/workflow`. The whole suite is expected to pass.
- Do not push without asking. After a rebase, impl-a needs a force push.

## impl-b: the user's implementation

- This is the user's work in progress. Do not change its production code
  unless asked.
- The user syncs impl-b manually, usually with `git town sync`.
- A common request after a sync is to bring back `@tag :skip` on every
  failing test of `test/ark/workflow`, so the user can start over with a
  single failure. Add the tags without committing, and list the tests that
  were skipped.

## Worktree

impl-b is checked out in the main checkout, usually with uncommitted work.
Work on common-test and impl-a in a separate worktree, and switch branches
inside it:

```sh
git worktree add ../ark-common-test common-test
ln -s /home/lud/src/ark/deps ../ark-common-test/deps
cp -a /home/lud/src/ark/_build ../ark-common-test/_build
```

The `deps` symlink shows as untracked. Commit with explicit paths so it is
never added.

The worktree shares the repository with the main checkout, so commits made
there are visible to impl-b without a push. A branch can only be checked out
in one place: while the worktree is on impl-a, `git town sync --all` fails in
the main checkout.
