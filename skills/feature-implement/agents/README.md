# Base agents — canonical source

This directory holds the canonical source for the `worker-base` and `reviewer-base` subagent definitions referenced by `orchestrator-dispatcher.md` and the three role-prompt envelopes (`worker-prompt.md`, `spec-reviewer-prompt.md`, `quality-reviewer-prompt.md`).

```
agents/
├── claude/
│   ├── worker-base.md
│   └── reviewer-base.md
├── cursor/
│   ├── worker-base.md
│   └── reviewer-base.md
└── codex/
    ├── worker-base.toml
    └── reviewer-base.toml
```

The body of each agent (Role / Output Protocol / Forbidden Phrases / Rules / Failure Mode) is byte-identical across the three harnesses per agent. Per-harness wrappers differ (Claude YAML frontmatter + `tools`; Cursor YAML frontmatter + `readonly`; Codex TOML + `sandbox_mode` + `developer_instructions`).

## Install target: **user scope**, never project scope

These files are NOT auto-loaded from this directory. They are deliberately shipped under `skills/feature-implement/agents/` (not under `.claude/agents/`, `.cursor/agents/`, `.codex/agents/`) so they do not register as project-scope subagents in any harness. Project-scope registration would create "trash in the repo" — every project would inherit them whether it uses `feature-implement` or not.

Install them to **user-scope** directories so they are available across all your projects:

```bash
# from repo root
cp skills/feature-implement/agents/claude/*.md   ~/.claude/agents/
cp skills/feature-implement/agents/cursor/*.md   ~/.cursor/agents/
cp skills/feature-implement/agents/codex/*.toml  ~/.codex/agents/
```

After install, the dispatcher's references to `~/.claude/agents/worker-base.md` etc. resolve.

## Future: automated install via init/update

`/myspec:init` and `/myspec:update` will eventually copy these files to user scope automatically. See the open follow-up issue on the repo. Until then, manual copy is the install path.

## Editing rules

- Body sections (everything below the frontmatter / outside `developer_instructions`) must stay byte-identical across the three harnesses per agent. CI / pre-commit drift check is the next follow-up.
- Frontmatter / TOML wrappers may differ — they are harness-specific.
- Output contract (`<result>…</result>` for worker, `<verdict>…</verdict>` for reviewer) is load-bearing for the controller parser. Do not change the tag form.
- `reviewer-base` is read-only — enforced via `tools` whitelist (Claude), `readonly: true` (Cursor), `sandbox_mode = "read-only"` (Codex). Keep parity across all three.
