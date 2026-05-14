# Worker Dispatch Envelope (Orchestrator Mode)

Controller renders this envelope and passes it as the prompt body when dispatching a `worker-base` agent. The agent owns the output contract (`<result>OK …</result>` / `<result>ERR …</result>`) and ROBOT MODE rules — see `~/.claude/agents/worker-base.md`, `~/.cursor/agents/worker-base.md`, or `~/.codex/agents/worker-base.toml`. This envelope owns only per-task content.

## Envelope template

```
Files you may touch:
{{FILE_LIST}}

Touch nothing else. Do not import sibling parallel tasks' files (they do not exist in your worktree).

Task:
{{TASK_TEXT}}
```

On retry (`FAIL-SPEC` or `FAIL-QUALITY`), append after `{{TASK_TEXT}}`:

```
## Reviewer verdict (retry N)

<reviewer verdict body verbatim — drop the <verdict>…</verdict> tags, keep the label line and bullets>
```

## Controller substitution protocol

1. **Render envelope verbatim.** Do NOT add a "Job", "Brief", "Current state", "Verification", "Commit", or "Report Format" wrapper. The plan task already contains: file paths, complete inline code, TDD sequence, run commands, commit message. Do not paraphrase, summarize, or split.
2. **Substitute `{{TASK_TEXT}}`** with the full task block from the plan, verbatim.
3. **Substitute `{{FILE_LIST}}`** with the task's declared file list, one path per line.
4. **Do NOT include** working directory, branch name, brief file path, "stage these files explicitly", or any other session metadata. The Worker operates from the worktree it was dispatched into; everything else is task content.
5. **On retry**: append a single `## Reviewer verdict (retry N)` block AFTER `{{TASK_TEXT}}`, containing the reviewer verdict body verbatim (drop the `<verdict>` tags). Do not paraphrase. Do not add commentary.

## Dispatch invocation

- **Claude Code:** `Task` with `subagent_type: worker-base`, `description: "Worker — {{TASK_SHORT_NAME}}"`, `model` resolved from tier (see `orchestrator-dispatcher.md` → Tier vocabulary), `isolation: "worktree"` for parallel-group tasks (omit for sequential), `prompt` = rendered envelope.
- **Cursor:** invoke the `worker-base` subagent (`~/.cursor/agents/worker-base.md`) with rendered envelope as the task body.
- **Codex:** invoke the `worker-base` subagent (`~/.codex/agents/worker-base.toml`) with rendered envelope as the task body.

If the agent produces prose beyond `<result>OK …</result>` / `<result>ERR …</result>`, that is a contract violation. The fix is tightening the agent prompt or the task text — not loosening the controller parser.
