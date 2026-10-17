# .githooks

Repo-local git hooks. They are **not** active until each clone opts in once:

```bash
git config core.hooksPath .githooks
```

`AGENTS.md` §1 lists this under bootstrap — run it before your first commit.

## Hooks

| Hook | Enforces |
|---|---|
| `commit-msg` | [Conventional Commits](../rules/07-git-commits.md): valid `<type>(<scope>): <summary>`, subject ≤72 chars, no trailing period. Merges/reverts/autosquash pass through. |

Bypass (rare, deliberate): `git commit --no-verify`. If you use it, say why in the commit body.
