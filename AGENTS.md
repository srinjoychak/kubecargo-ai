# AGENTS.md — Subagent Prompt Standard (VN-Squad v2)

This file defines how the Tech Lead must structure tasks and prompts for every subagent.
The goal is **zero-supervision completion**: each agent reads its prompt once, executes
fully, commits, and reports back — with no clarifying questions and no retry needed.

---

## Core Principle: Self-Contained Prompts

**Never assume the agent will find information on its own.**

Every prompt must contain:
- What to build (full requirements, not a reference to another file)
- Where to build it (absolute file paths in the current working directory)
- How to verify it worked (completion checklist)
- How to commit and report when done

---

## Protected Files — NEVER modify

| File | Why |
|---|---|
| `CLAUDE.md` | Tech Lead system prompt — changing it corrupts identity |
| `AGENTS.md` | This file — changing it breaks subagent dispatch |
| `agents.json` | Agent capability config — changing it breaks routing |
| `DESIGN.md` | Shared design artifact — only /argue should write this |

---

## Universal Rules (all subagents)

1. **Embed the full task description** — not a pointer to another file.
2. **List every target file explicitly** with its absolute path.
3. **Non-interactive shell only** — no `npm init`, `git init`, `npx create-*`.
4. **Commit instruction is mandatory** — always end with:
   `git add -A && git commit -m "task: <id>"`
5. **Completion checklist** — tell the agent exactly what "done" looks like.
6. **No placeholders or TODOs** — write all code fully.

---

## VN-Squad v3 Protocol Extensions

### AGENT_RESULT Block (v3 extended)

All agents emit this block at the end of their response (adding quality_signals to v2 protocol):

```
AGENT_RESULT:
  status: success | failure
  failure_code: EmptyDiff | CompileRed | TestFail | StaleBranch | PromptMisdelivery | ProviderFailure | none
  evidence: <single line>
  files_changed: <integer>
  quality_signals:
    review_verdict: APPROVE | REQUEST_CHANGES | not_run
    test_coverage: present | absent | unknown
```

### CONTEXT_PROPOSAL Block (optional — v3)

Agents MAY emit one CONTEXT_PROPOSAL when they discover a useful convention. Advisory only — Tech Lead decides:

```
CONTEXT_PROPOSAL:
  key: conventions.<key_name>
  value: <primitive value>
  rationale: <one line>
```

Rules: max 1 per AGENT_RESULT; key must be `conventions.*` or `constraints.*`; do NOT propose previously rejected keys.

### Recovery Annotation

First line of a recovery task prompt must include:
```
[RETRY: <original-task-uuid>]
```

---

## Standard Prompt Template

```
# Task <id>: <title>

## Working Directory
<absolute path>

## Files to Create or Modify
- <absolute path/file.js>   (create — purpose)
- <absolute path/file2.js>  (modify — what changes)

## Full Requirements
<paste the complete requirements verbatim — no summarising>

## Instructions
- Implement all requirements completely. No placeholders, no TODOs.
- Non-interactive shell commands only.
- Do NOT modify: CLAUDE.md, AGENTS.md, agents.json, DESIGN.md
- After completing all files:
    git add -A && git commit -m "task: <id>"

## Completion Checklist
- [ ] All listed files exist and are fully implemented
- [ ] Code runs without syntax errors
- [ ] Tests pass (if applicable)
- [ ] git log shows a new commit for this task

## Reporting
Summarise:
- What files were created/modified and what each does
- Decisions and trade-offs made
- Confirmation of git commit hash
```

---

## Agent-Specific Notes

### Claude Code subagents (via Task tool)

- **Dispatch**: Use Claude Code's Task tool with the above prompt template.
- **Context**: Each subagent has a fresh context — do NOT reference "what we discussed earlier".
- **Constraints**: Add `"Do NOT call any /argue, /gemini, or /codex:* skills"` to prevent recursion.
- **Output format**: Subagent returns a text summary. Verify with `git log` independently.

### Codex (via codex-plugin-cc)

- **Dispatch**: `/codex:rescue <prompt>` or `/codex:adversarial-review`
- **Concurrency**: One active request at a time — the JSON-RPC broker queues subsequent calls.
- **Review**: `/codex:adversarial-review` returns `{ verdict, findings[], confidence }`.
  Used by `/argue` skill automatically.

### Gemini (via scripts/gemini-ask.js)

- **Dispatch**: `/gemini <prompt>` skill or `node scripts/gemini-ask.js "<prompt>"` directly.
- **Best for**: Large-context analysis, documentation, research, planning alternatives.
- **Output**: JSON `{ summary, model, exitCode, tokenUsage }` — `/gemini` skill presents `summary`.
- **Known**: `libsecret` and `projects.json` warnings on stderr are harmless.

---

## Task Type → Agent Routing

| Task type | Preferred agent | Reason |
|---|---|---|
| research / analysis | gemini | Large context window, free tier |
| docs / planning | gemini | Strong writing, good at structure |
| code / refactor | claude-subagent | Precision, reasoning, multi-file |
| test | claude-subagent | Understands test patterns well |
| debug | claude-subagent or codex | Step-by-step reasoning |
| adversarial review | codex | /codex:adversarial-review |
| rescue / complex fix | codex | /codex:rescue |
| design debate | claude + codex | /argue skill |

---

## What Causes a Retry

Retry when:
- Agent reports an error or incomplete work
- `git diff` shows zero files changed on a code/test/refactor task
- Summary is empty or clearly incomplete

On retry: provide a different agent OR the same agent with clarified requirements.
Do NOT rely on state from a previous attempt.

---

## Tech Lead Checklist Before Dispatching

- [ ] Full requirements embedded (not a reference)
- [ ] All target file paths listed with absolute paths
- [ ] Commit instruction present
- [ ] No interactive commands
- [ ] Completion checklist included
- [ ] Agent selected appropriately for task type
