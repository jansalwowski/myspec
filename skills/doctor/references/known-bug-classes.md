# Known bug classes

Regression greps for `/myspec:doctor`: check these first, they recur. Read in full before dispatching the Phase 1 surfaces.


The **Owner** column says what already decides the class. A row owned by a script is not a
subagent's job: read its verdict from the Phase 0 records. The rest recur because nothing
mechanical can see them.

| Class | Shape | Owner |
|---|---|---|
| Config value breaks derived pattern | trailing slash in a configured dir → derived glob `dir//*` matches nothing; consumer silently dead | tier 0 `aidir-trailing-slash` |
| Promised binary absent | `timeout` assumed, absent on macOS → "120s cap" runs unbounded | tier 0 `tooling-absent` (jq/node); judgment otherwise |
| Mixed status vocabularies | frontmatter statuses outside the manifest's allowed enum | `audit.mjs` (surface F) |
| ID collision across namespaces | framework P001 vs project P001 in one index | `memory-doctor.mjs` `duplicate-id` |
| Framework file silently forked | a rule hand-edited at a matching version; an update that half-applied | tier 0 `framework-drift` |
| Framework hook still wired or copied locally | a 2.x `settings.json` entry runs a stale copy beside the plugin's own; a copy sits under `.claude/hooks/` or `.claude/lib/` that nothing runs | tier 0 `hook-wired-locally` / `hook-copy-retired` |
| Project hook copied but never wired | the file is there, no settings entry, nothing ever runs it | tier 0 `hook-unregistered` |
| Tool/server name drift | agent declares `mcp__db__*`; the real server registers under a different prefix | judgment (surface B) |
| Phantom contract vocabulary | a consumer branches on labels its producer is forbidden from emitting | judgment (surface B) |
| Defaults that don't exist | a documented default flag value names a project/target that was never defined | judgment (surface B) |
| Script referenced ≠ script defined | docs say `lint --fix`, the manifest defines `lint:fix`; config file present but never wired as a script | judgment (surface B) |
| Allowlist missing self | a guard hook blocks edits to its own file | judgment (surface E, behavioral run) |
| Temporary ban outlives reality | "DO NOT implement X yet" beside shipped, working X | judgment (surface C) |
| Frozen index | INDEX.md lists 2 of 15 features | judgment (surface C/F) |
| History embedded in hot files | multi-KB changelog or "PR #N still draft" inside a manifest `note:` field | tier 0 `note-over-cap` / `note-volatile`; judgment for other hot files (surface F) |

