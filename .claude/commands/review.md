# /review — Request Code Review

*Sourced from obra/superpowers:requesting-code-review (skills.sh)*

Dispatch a code-reviewer subagent with focused context to catch issues before they compound.

**Core principle:** "Review early, review often."

## When to Review

**Mandatory:**
- After completing a major feature
- Before merging to main
- After each task in a multi-task job

**Optional but valuable:**
- When stuck (fresh perspective often unblocks)
- Before refactoring (establish baseline understanding)
- After fixing a complex bug

## How to Request

### 1. Capture git context

```bash
BASE_SHA=$(git merge-base HEAD main 2>/dev/null || git rev-parse HEAD~1)
HEAD_SHA=$(git rev-parse HEAD)
```

### 2. Dispatch reviewer subagent

Use the Task tool with this prompt template:

```
You are a code reviewer. Review the changes between $BASE_SHA and $HEAD_SHA.

**What was implemented:** $WHAT_WAS_BUILT

**Requirements / plan:** $REQUIREMENTS

**Your task:**
- Run: git diff $BASE_SHA..$HEAD_SHA
- Identify issues by severity:
  - Critical (fix immediately — correctness, security, data loss)
  - Important (fix before proceeding — performance, maintainability)
  - Minor (note for later — style, naming, small improvements)
- For each issue: file path, line number, description, suggested fix
- End with a clear verdict: APPROVE / REQUEST_CHANGES
```

### 3. Act on feedback

- **Critical** → fix immediately before any other work
- **Important** → fix before calling `/finish`
- **Minor** → note, fix opportunistically
- **Reviewer is wrong** → push back with technical reasoning + evidence

## Red Flags

**Never:**
- Skip review because "it's simple"
- Ignore Critical issues
- Proceed with unfixed Important issues without explicit user approval

## Integration with /argue

For design review (before implementation), use `/argue` instead — it runs the full
Claude ↔ Codex debate loop on `DESIGN.md`. `/review` is for code that already exists.
