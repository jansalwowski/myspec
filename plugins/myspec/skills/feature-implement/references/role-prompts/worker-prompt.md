# Worker Dispatch Envelope (Orchestrator Mode)

Controller renders this envelope and dispatches `worker-base`. The agent definition (`~/.claude/agents/worker-base.md` / `~/.cursor/agents/worker-base.md` / `~/.codex/agents/worker-base.toml`) owns the output contract and rules. This file owns only per-task content.

Substitution + dispatch invocation discipline lives in `orchestrator-dispatcher.md` → "Dispatch envelope discipline (shared)". Read it once; it governs every envelope file.

## Envelope template

```
Files you may touch:
{{FILE_LIST}}

Touch nothing else. Do not import sibling parallel tasks' files (they do not exist in your worktree).

You have Read, Edit, MultiEdit, Write only. No shell, no Grep/Glob, no git. Reviewer runs tests/lint after you finish; controller commits. Ignore any "Run …", "Commit", or shell-command step in the task block.

Return: <result>OK <file-list></result> where <file-list> is the comma-separated paths you created or modified.

Task:
{{TASK_TEXT}}
```

## Retry append

On `FAIL-SPEC` or `FAIL-QUALITY`, append after `{{TASK_TEXT}}`:

```
## Reviewer verdict (retry N)

<reviewer verdict body verbatim — drop the <verdict>…</verdict> tags, keep the label line and bullets>
```

## Slots

- `{{FILE_LIST}}` — task's declared file list, one path per line.
- `{{TASK_TEXT}}` — full task block from plan, verbatim.
- `{{TASK_SHORT_NAME}}` — dispatch description.
