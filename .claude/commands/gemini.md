# /gemini — Gemini CLI Adapter

Delegate a research, analysis, or planning prompt to Gemini CLI via the lightweight
`scripts/gemini-ask.js` adapter. No Docker required.

## Invocation

```
/gemini [--model flash|pro|pro-exp] <prompt>
```

**Examples:**
```
/gemini what are the tradeoffs of Drizzle ORM vs Prisma for SQLite?

/gemini --model pro analyze the security implications of the auth middleware

/gemini --model flash summarize the last 50 git commits

/gemini --model pro-exp review the entire src/ directory for architectural issues
```

## Model Selection

| Model | Speed | Quality | Cost | Best for |
|---|---|---|---|---|
| `flash` (default) | Fast | Good | Free tier | Summaries, quick research, docs |
| `pro` | Medium | Better | Free tier | Security analysis, complex reasoning |
| `pro-exp` | Slower | Best available | Free tier | Architecture review, large context |

## Workflow

**Announce:** "Delegating to Gemini (`$MODEL`): $PROMPT"

Run:
```bash
node scripts/gemini-ask.js "$PROMPT" --model "$MODEL"
```

Parse the JSON output:
```json
{
  "summary": "...",
  "model": "gemini-2.0-flash",
  "exitCode": 0,
  "tokenUsage": { "input": 120, "output": 850, "total": 970 }
}
```

Present `summary` to the user along with `tokenUsage` (for awareness).

If `exitCode != 0`:
- Report the error
- Suggest: `gemini --version` to verify CLI is installed
- Suggest: `gemini auth` to re-authenticate

## When to Use Gemini

- **Research**: Compare libraries, explain concepts, survey documentation
- **Large context**: Analyze many files at once (Gemini has a large context window)
- **Docs**: Write comprehensive documentation, READMEs, API docs
- **Planning**: Explore design alternatives before `/argue`
- **Free-tier tasks**: Tasks where Claude quota is scarce

## Prerequisites

```bash
npm install -g @google/gemini-cli   # install CLI
gemini auth                          # authenticate
node scripts/gemini-ask.js "test"    # verify adapter works
```
