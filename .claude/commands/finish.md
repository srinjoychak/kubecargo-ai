# /finish — Finish a Development Branch

*Sourced from obra/superpowers:finishing-a-development-branch (skills.sh)*

Verify tests, present completion options, execute the chosen path, and clean up worktrees.

**Announce:** "I'm using the finishing-a-development-branch skill to complete this work."

## Step 1: Verify Tests

Run the project's test suite (`npm test` / `cargo test` / `pytest` / `go test ./...`).

If tests **fail**: Display failures and stop.
> "Cannot proceed with merge/PR until tests pass."

If tests **pass**: Continue to Step 2.

## Step 2: Determine Base Branch

```bash
git merge-base HEAD main 2>/dev/null || git merge-base HEAD master
```

Confirm the base branch with the user if ambiguous.

## Step 3: Present Options

Display exactly these four choices:

1. **Merge back to `<base-branch>` locally**
2. **Push and create a Pull Request**
3. **Keep the branch as-is** (I'll handle it later)
4. **Discard this work**

## Step 4: Execute Choice

**Option 1 — Merge Locally:**
```bash
git checkout <base-branch> && git pull
git merge --no-ff <feature-branch>
```
Verify tests pass after merge. Delete the feature branch. Cleanup worktree.

**Option 2 — Create PR:**
```bash
git push -u origin <feature-branch>
gh pr create --title "<title>" --body "<summary + test plan>"
```
Cleanup worktree.

**Option 3 — Keep As-Is:**
Report the branch and worktree location. Do NOT cleanup.

**Option 4 — Discard:**
Require user to type `discard` exactly to confirm.
```bash
git checkout <base-branch>
git branch -D <feature-branch>
```
Cleanup worktree.

## Step 5: Cleanup Worktree (Options 1, 2, 4 only)

```bash
git worktree list
git worktree remove ".worktrees/<branch-name>" --force
```
