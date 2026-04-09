# /worktrees — Git Worktree Management

*Sourced from obra/superpowers:using-git-worktrees (skills.sh)*

Create and manage isolated git worktrees for parallel development with smart directory
selection and safety verification.

## Directory Selection (Priority Order)

1. Check for existing `.worktrees/` or `worktrees/` (`.worktrees` takes precedence)
2. Check `CLAUDE.md` for worktree directory preferences
3. Ask the user to choose between project-local or global storage

## Safety Requirements

For project-local directories, verify git-ignore status before creation:
```bash
git check-ignore -q .worktrees 2>/dev/null || git check-ignore -q worktrees 2>/dev/null
```

If not ignored: add to `.gitignore` and commit immediately.

## Creation Workflow

1. Detect project root: `git rev-parse --show-toplevel`
2. Create worktree + branch:
   ```bash
   git worktree add ".worktrees/$BRANCH_NAME" -b "$BRANCH_NAME"
   ```
3. Auto-detect and run setup:
   - Node.js (`package.json`): `npm install`
   - Rust (`Cargo.toml`): `cargo build`
   - Python (`requirements.txt`): `pip install -r requirements.txt`
   - Go (`go.mod`): `go mod download`
4. Run baseline tests to establish clean starting state
5. Report: worktree path + test status

## Critical Rules

**Never:**
- Create worktrees without verifying git-ignore status
- Skip baseline test verification
- Proceed with failing baseline tests without user consent

**Always:**
- Follow directory priority order
- Auto-detect project setup requirements
- Report the full worktree path so it can be used in subsequent commands

## Cleanup

When done with a worktree:
```bash
git worktree remove ".worktrees/$BRANCH_NAME"
git branch -d "$BRANCH_NAME"
```

Use `/finish` to handle the full cleanup + merge/PR flow automatically.
