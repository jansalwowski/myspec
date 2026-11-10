# Verification Planning

Read from SKILL.md Step 3, when `tech-spec.md` sets `verification_mode` other than `none`, or its `### Test Hooks` names *Real inputs*. `<plugin lib>` is the path SKILL.md resolves.

## Checkpoint probes

**Checkpoint probes (REQUIRED when tech-spec.md sets `verification_mode` other than `none`):**
Give every milestone a `**Checkpoint probes:**` block (format and tags in [plan-templates.md](plan-templates.md#milestone-section)). The probes are written now, before any code exists, because a separate executor runs them at the checkpoint and the controller may not substitute its own judgment: a probe authored after the fact by the agent that built the feature proves what that agent chose to look at. Each probe is literal and references only the tech-spec's `### Test Hooks` contract surface — a CSS class or internal DOM path is a plan bug. A `verification_mode` with no `### Test Hooks` section is a tech-spec gap: say so and stop. So is a writing probe — a `[demo]`, a `[real-input]`, a data mutation — when Test Hooks has no *Scratch environment* line: the executor cannot isolate it, and it comes back BLOCKED at every checkpoint. Ports come from the project's `probes.portSource` when it sets one (plan-templates.md, Ports line), so a probe never hardcodes a port a parallel checkout holds. A milestone whose probes read the database gets its own Scratch setup line (migrate, then seed, for that milestone's schema), because the executor starts each checkpoint from what the scratch database already holds.

## Dry run on real inputs

**Dry run on the named real inputs (REQUIRED when Test Hooks names *Real inputs*):**
Realistic inputs are not the inputs the feature must handle. When `tech-spec.md` → `### Test Hooks` names a *Real inputs* corpus, run the derivation's core (the parse, classify, or transform rule the tasks prescribe) on that corpus before presenting the plan, and quote the command and the observed result (counts, any input the rule drops or misplaces) in the plan, on the task's `**Prototype:**` line. An input the rule cannot place is a tech-spec defect: say so and stop. When the core cannot run before the feature exists, make a spike on the corpus the plan's first task, and give its expected result. A tech-spec with no *Real inputs* line skips this.
