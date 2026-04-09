# /scaffold — Curriculum Task Decomposition

Generate a tiered difficulty ladder for a task that has failed or is too complex to
dispatch directly. Uses Gemini to decompose into increasingly complex sub-tasks.

## When to use
- A task has returned EmptyDiff or CompileRed after 2+ retries
- A task description is too broad to dispatch in a single agent call
- You want to break a complex feature into independently testable tiers

## Usage

```
/scaffold "<failed task description>"
```

## Workflow

1. Send to Gemini: "Decompose this task into 3-4 tiers of increasing complexity.
   Each tier must be independently testable and committable.
   Task: <description>"

2. Present tiers to Tech Lead for approval:
   ```
   Tier 1: <simplest subtask — interfaces/types only>
   Tier 2: <core implementation>
   Tier 3: <full feature with edge cases>
   Tier 4 (optional): <integration/hardening>
   ```

3. On Tech Lead approval: /dispatch each tier as a separate task.
   Gate each tier on success before dispatching the next.

4. After all tiers succeed: aggregate into session-context.json completed_tasks.

## Constraints
- Each tier must produce independently committed, testable work
- Tier N must not depend on tier N+1 being complete
- Do NOT call /argue, /gemini, or /codex:* skills inside scaffold
