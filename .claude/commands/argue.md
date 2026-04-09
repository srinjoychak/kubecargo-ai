# /argue — Design Debate Loop (Claude ↔ Codex)

Drive a structured adversarial debate between Claude and Codex to stress-test a technical
design before any code is written. Iterate until consensus or max rounds.

## Invocation

```
/argue [--codex-model <model>] [--rounds <n>] <topic>
```

**Examples:**
```
/argue should we use ESM or CJS for this Node.js project?

/argue --codex-model gpt-5.4-mini should hello.js use console.log or process.stdout.write?

/argue --rounds 6 --codex-model gpt-5.3-codex-spark redesign the entire authentication module
```

**Flags:**
| Flag | Default | Description |
|---|---|---|
| `--codex-model` | provider default | Model for `/codex:adversarial-review` (e.g. `gpt-5.4-mini`, `gpt-5.3-codex-spark`) |
| `--rounds` | 4 | Maximum debate rounds before forcing convergence |

> **Claude's model** is always the current session model — use `/model opus|sonnet` in
> Claude Code before running `/argue` if you want a more capable Claude position.

## Workflow

**Announce:** "Starting /argue debate (max $ROUNDS rounds): $TOPIC"

**Pre-flight: Branch check**
Before writing DESIGN.md, verify you are NOT on master or main:
```bash
BRANCH=$(git branch --show-current)
```
If `$BRANCH` is `master` or `main`: **STOP**. Tell the user:
> "ERROR: /argue must run on a feature branch, not master. Create one first:
> `git checkout -b argue/<topic-slug>`"
Do not proceed until the user creates a feature branch.

### Round loop

**Step 1 — Draft / Refine design**

If `DESIGN.md` does not exist:
- Write `DESIGN.md` with Claude's initial position on the topic.
- Structure: Problem Statement → Proposed Approach → Key Tradeoffs → Open Questions.

If `DESIGN.md` exists (subsequent rounds):
- Read the Codex findings from the previous round.
- For EACH finding: explicitly DEFEND (explain why concern is addressed), REVISE (update the design), or CONCEDE (note as unresolved).
- Update `DESIGN.md` in-place. It stays a clean design doc — not a debate transcript.

**Step 2 — Commit**

```bash
git add DESIGN.md
git commit -m "argue: round $ROUND — $TOPIC"
```

**Step 3 — Adversarial review**

Run: `/codex:adversarial-review --wait [--model $CODEX_MODEL]`

Codex returns structured findings:
```json
{
  "verdict": "APPROVE" | "REVISE" | "REJECT",
  "confidence": 0.0–1.0,
  "findings": [
    { "severity": "critical|major|minor", "description": "..." }
  ]
}
```

**Step 4 — Convergence check**

Stop if ANY of:
- `verdict == "APPROVE"`
- `confidence >= 0.85`
- `round >= $MAX_ROUNDS`

Otherwise increment round and return to Step 1.

## Convergence Output

When stopping, output:

```
## /argue — Debate Complete (Round $ROUND / $MAX_ROUNDS)

**Verdict:** $VERDICT
**Confidence:** $CONFIDENCE
**Codex model:** $CODEX_MODEL
**Claude model:** (current session)

**Agreed design:** DESIGN.md (committed to current branch)

**Findings addressed:** $N
**Unresolved findings** (if any):
- severity: description

**Next step options:**
1. `/codex:rescue [--model <model>]` — Codex implements the agreed design
2. Continue arguing with `--rounds $((ROUND+2))`
3. Proceed with Claude implementation
```

## Rules

- Never skip a finding — address every one (defend, revise, or concede).
- Never write implementation code during argue — only `DESIGN.md`.
- `DESIGN.md` must remain a clean design document, not a debate transcript.
- If Codex is unavailable or `/codex:adversarial-review` fails with `disable-model-invocation`: **STOP**. Tell the user: "Codex skill is unavailable. Run `/codex:setup` in Claude Code to restore it, then retry /argue."
- If `--rounds` is exceeded without APPROVE, present the unresolved findings to the user.
