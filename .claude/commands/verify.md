# /verify — Verification Before Completion

*Sourced from obra/superpowers:verification-before-completion (skills.sh)*

**NO COMPLETION CLAIMS WITHOUT FRESH VERIFICATION EVIDENCE.**

You cannot claim work is complete, fixed, or passing without running actual verification
commands and confirming the output in the current message.

## The Five-Step Gate

Before making any success claim:

1. **IDENTIFY** — What command proves this claim?
2. **RUN** — Execute the full command fresh and completely
3. **READ** — Check full output, exit code, and count failures
4. **VERIFY** — Does the output confirm the claim?
   - If NO: State actual status with evidence
   - If YES: State claim WITH evidence attached
5. **ONLY THEN** — Make the claim

Skipping any step violates the rule.

## What Requires Verification

- "Tests pass" → need: test command output showing 0 failures
- "Build succeeds" → need: exit code 0
- "Bug is fixed" → need: original symptom test now passes
- "Requirements met" → need: line-by-line checklist verification
- "Task complete" → need: `git diff` showing actual changes committed

## Red Flags — Stop Here

- Using "should", "probably", "seems to"
- Expressing satisfaction before running verification
- Trusting agent reports without independent verification
- Relying on partial checks (linting ≠ compilation)
- Any wording implying success without running the command

## When This Applies

**ALWAYS before:**
- Any success/completion claim
- Commits or PRs
- Moving to the next task
- Delegating to agents
- Calling `/finish`
