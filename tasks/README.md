# tasks/

Harness-agnostic work board. Any agent, in any harness, registers and tracks progress here. Do not edit `registry.json` by hand — use the CLI.

## Usage

```bash
node tasks/bin/tasks.mjs register --agent <name> --harness <claude-code|opencode|codex|cursor>
node tasks/bin/tasks.mjs claim T-001
node tasks/bin/tasks.mjs update T-001 -m "signing golden vectors green"
node tasks/bin/tasks.mjs done T-001
node tasks/bin/tasks.mjs status
node tasks/bin/tasks.mjs board     # regenerate BOARD.md
```

## Files

| File | Purpose |
|---|---|
| `registry.json` | Machine state: `agents[]`, `tasks[]` |
| `TODO.md` | Prioritized backlog (generated) |
| `BOARD.md` | Kanban view (generated) |
| `progress/<agent>.md` | Append-only per-agent log (handoff) |
| `templates/` | Task + progress templates |

## Status values
`todo` → `doing` → `review` → `done` (or `blocked`).

## Conventions
- Register **before** claiming. One owner per task.
- `done` requires the DoD in `AGENTS.md` §5.
- Leave handoff notes in `progress/<agent>.md`, never only in chat.
