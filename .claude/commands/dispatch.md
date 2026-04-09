# /dispatch — Parallel Agent Dispatch

Dispatch independent tasks to specialized agents working in parallel, each in their own
isolated context and git worktree.

**Any agent can handle any task type.** Routing is by your explicit annotation — not by
assumed capability. Gemini can write code. Codex can write tests. Claude can do research.
Choose based on what you want, not what's "typically" done.

---

## Annotation syntax

```
[agent] task description
[agent --model <model>] task description
```

| Annotation | Routes to | Model flag |
|---|---|---|
| `[gemini]` | `gemini-worker` subagent → Gemini CLI | `--model flash\|pro\|pro-exp` |
| `[codex]` | `codex-worker` subagent → codex-plugin-cc | `--model gpt-5.4-mini\|gpt-5.3-codex-spark` |
| `[claude]` | Native Claude Code subagent (Task tool) | Inherits session model — change with `/model opus\|sonnet\|haiku` first |
| *(no annotation)* | Native Claude Code subagent | Same as above |

**Each annotated task gets its own isolated git worktree** (via `isolation: worktree` on the
`gemini-worker` and `codex-worker` sub-agents). Claude tasks run in the main worktree unless
you explicitly set isolation.

---

## Examples

### Same task type, different agents
```
[gemini --model pro]   write the authentication module (src/auth/index.js)
[claude]               write unit tests for src/auth/index.js
[codex]                review src/auth/index.js for security vulnerabilities
```

### All Gemini, different models
```
[gemini --model flash]   write JSDoc for all functions in src/utils/
[gemini --model pro]     analyze the architecture of src/ and suggest improvements
[gemini --model pro-exp] refactor src/db/ to use the repository pattern
```

### All agents on parallel features
```
[gemini]   implement the rate limiter middleware (src/middleware/rate-limit.js)
[claude]   implement the caching layer (src/middleware/cache.js)
[codex]    implement the auth middleware (src/middleware/auth.js)
```

### Mixed models, mixed agents
```
[gemini --model pro]       write a comprehensive test suite for src/api/
[claude]                   fix the type error in src/router/index.js line 42
[codex --model gpt-5.4-mini]  review src/api/ for missing error handling
```

---

## How to dispatch

1. **List all tasks** with annotations
2. **Spawn all annotated tasks in parallel** using the Agent tool — one Agent call per task
3. **For `[gemini]` tasks**: delegate to `gemini-worker` subagent
4. **For `[codex]` tasks**: delegate to `codex-worker` subagent  
5. **For `[claude]` or unannotated tasks**: spawn as a standard Task/Agent call
6. **Wait for all to complete**, then **review and integrate**:
   - Read each agent's summary
   - Verify no file conflicts (if tasks touched the same files, resolve manually)
   - Run the full test suite
   - Each agent's worktree changes are available on their respective branches

> **Codex concurrency note:** `codex-worker` has an internal queue (JSON-RPC broker allows
> one active Codex request). Multiple `[codex]` tasks will serialize automatically.

---

## When to use /dispatch

**Use when:**
- Tasks are genuinely independent (different files or subsystems)
- You want different AI backends to work on different parts
- You're parallelizing research, implementation, and review simultaneously
- You want to compare outputs from different agents on the same task

**Don't use when:**
- Task B requires the output of Task A
- Both tasks modify the same file (merge conflicts)
- You need a single coherent narrative across all tasks

---

## Task prompt template

Each agent receives an isolated context. Embed everything it needs:

```
Task: [Name]
Working directory: [absolute path]

Files to create/modify:
  - [absolute path/file.js] (create — purpose)

Full requirements:
  [complete requirements, no external references]

Instructions:
  - Non-interactive shell only
  - Do NOT modify: CLAUDE.md, AGENTS.md, DESIGN.md, agents.json
  - After all files are done: git add -A && git commit -m "task: [name]"

Done when:
  - [ ] [verifiable checklist item]
  - [ ] git log shows new commit
```
