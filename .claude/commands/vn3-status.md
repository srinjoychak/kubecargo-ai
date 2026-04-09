# /vn3-status — VN-Squad v3 Self-Improvement Status

Show current state of the v3 self-improvement layer:
- Routing calibration (specialization-profile suggestions)
- Session context (conventions, pending proposals, completed tasks)
- Patch status (active, expired, graduated)
- Trajectory counts
- Plateau milestone progress

## Usage

```
/vn3-status
```

## Workflow

Run in sequence:
```bash
node scripts/vn3/routing.js --status
node scripts/vn3/session-context.js --show
node scripts/vn3/patches.js --list
node scripts/vn3/trajectories.js --list
```

Then check plateau milestone:
```bash
node -e "
  import('./scripts/vn3/decisions.js').then(m => {
    const d = m.readDecisions();
    const overrides = d.filter(e => e.type === 'routing_override_accepted' && e.outcome_ref);
    const taskTypes = [...new Set(overrides.map(e => e.task_type))];
    console.log('Plateau: ' + taskTypes.length + '/3 distinct task_type overrides accepted');
    console.log('Task types:', taskTypes.join(', ') || 'none yet');
  });
"
```

## Output

Present a summary with:
- [ROUTING] Override suggestions (or "all defaults")
- [SESSION] Active conventions and pending proposals
- [PATCHES] Active patch count per agent
- [PLATEAU] Progress toward >=3 distinct task_type routing overrides
