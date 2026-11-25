---
name: "feature-discover"
description: "Use when code exists but no spec does: undocumented features, reverse engineering a spec from code. Do NOT use where a spec already exists."
tags: [feature, discovery, reverse-engineering, documentation]
---

# Feature Discovery

Reverse-engineers an undocumented feature from existing code into structured documentation.

## Prerequisites

- Code exists in the codebase (no spec required — this skill creates one)
- You have either: a description of the feature, known file/directory paths, or both

## Workflow

### 1. Intake

Collect from the user what they know. Ask only for what's missing:

- **Description** (required if no paths provided): "What feature are we documenting? What does it roughly do?"
- **Paths** (optional): "Do you know which files or directories are involved?"

If only paths are provided, skip the description prompt — infer intent from the code itself.
If only a description is provided, proceed directly to exploration.

### 2. Exploration

Explore the codebase to build a complete picture of the feature. Read the project's stack first from the topology file (`.myspec.json` → `topologyFile`, falling back to `backbone.yml` at the project root) or `${aiDir}/conventions/`, so the categories below map to its real file types. Use grep, file reads, and import tracing. Start from known paths or grep description keywords to locate entry points.

**What to look for:**

| Category | Look for |
|----------|----------|
| Entry points | Routes, controllers, CLI commands, page components, navigation entries, event triggers |
| UI components | Components, templates, views, and their shared helpers (hooks, composables, partials) |
| Client or server state | Stores, sessions, caches, and the code that reads or changes them |
| Data models and persistence | Models, entities, repositories, migrations, schemas |
| Background jobs | Queued jobs, workers, scheduled tasks, event listeners |
| API | GraphQL queries/mutations, REST calls, endpoint URLs |
| Gates / flags | Feature flags, server gates, environment-based conditions |
| Translations | i18n keys, translation files |
| External services | Third-party APIs, external endpoints, webhooks |
| Shared utilities | Common helpers, validators, formatters used |

**Exploration rules:**
- Trace outward from entry points: entry point → UI or handler → state → API → models and types → shared utilities
- Follow imports to find all involved files
- Note every external API call, external service reference, or cross-app dependency as you go
- Do NOT stop to ask about each finding — keep exploring until you have a complete picture
- Collect unknowns into a list; ask about them in batches in Step 3

**When to stop:**
- You can describe the full user journey from entry point to data persistence
- All file categories above have been checked (even if empty)
- All external integration points have been identified (purpose may still be unclear)

### 3. Grouped Q&A

When exploration is complete, ask about unknowns in related batches. Never ask about one thing at a time — group by topic and present together. Wait for answers before continuing.

**Format:**
```
[Agent says]: Exploration complete. Before writing up findings, here are some questions grouped by topic:

**External integrations:**
1. The code calls `{endpoint}` — what does that endpoint do? Is it internal or a third-party service?
2. There's a reference to `{service}` — is this in scope for this feature?

**Business logic:**
3. `{condition}` is checked in several places — what business rule does this represent?

**Scope:**
4. The code touches `{module}` — is that part of this feature, or just a dependency?
```

Record all answers. They are embedded in the discovery document.

### 4. Confirmation

Present the full findings summary using the **Confirmation Findings Template** from [references/templates.md](references/templates.md).

**Wait for explicit confirmation before writing any files.**

Ask: "Does this match your understanding? Anything missing or incorrect?"

Incorporate any corrections, then proceed.

### 5. Complexity Check

Before writing files, evaluate whether this feature should be decomposed.

**Decompose if any of these are true:**
- More than 3 clearly distinct capabilities that could ship independently
- Integrations with more than 2 different external services
- The feature spans multiple unrelated user journeys with no shared core

**If threshold is met**, present the case before proceeding:
```
This feature looks large enough to benefit from decomposition.
I see {N} distinct capabilities: {list}.

Would you like to decompose it into sub-features?
If yes: write discovery first, then follow the feature-decompose workflow.
```

Note the answer — decomposition (if agreed) happens AFTER Step 8.

### 6. Output Decision

Ask where the output goes before writing any file, so `discovery.md` is written once, to a known path:

```
Findings confirmed. Where should the docs go?

A) Discovery only — save to `${aiDir}/discoveries/{TODAY}-{feature-slug}/`
   Good when: knowledge is partial, no time for full spec, or this feeds into a larger feature

B) Full feature docs — save to `${aiDir}/features/{feature-name}/` with spec.md + tech-spec.md
   Good when: findings are solid and you want this in the feature pipeline

C) Both — discovery in `${aiDir}/discoveries/` + full feature docs in `${aiDir}/features/`
```

### 7. Write discovery.md

Write this file now, before any other output file. It is the durable checkpoint. The path comes from the Step 6 answer: `${aiDir}/features/{feature-name}/discovery.md` for B, `${aiDir}/discoveries/{TODAY}-{feature-slug}/discovery.md` for A and C.

Use the **discovery.md Frontmatter** from [references/templates.md](references/templates.md).

**Required sections:**

#### Overview
2–3 sentences: what this feature does, who uses it, and when it activates.

#### Entry Points
How users reach the feature (routes, navigation, event triggers).

#### Components & Structure
All involved files and their roles:

| File | Type | Role |
|------|------|------|
| `path/to/{file}` | UI component | [role] |
| `path/to/{file}` | Data model | [role] |

#### Behavior
Step-by-step: what happens from user action to final state. Include:
- Happy path
- Conditional branches (gate on/off, user permissions, data states)
- Error states visible in code

#### Integration Points

**Internal**
- [Other modules, state, or features this depends on]

**External**
- [External APIs, third-party services, webhooks — with purpose from Q&A answers]
- None found — if applicable

#### Feature Flags & Gates
| Flag | Behavior when enabled |
|------|-----------------------|
| `FLAG_NAME` | [what changes] |

#### Translations
| Key | Purpose |
|-----|---------|
| `translation.key` | [what it labels] |

#### Open Questions
Unresolved items after Q&A. Format:
- **[Q]** What does X do exactly? — *Found at `path/to/{file}:42`*

#### Complexity Assessment
**Rating**: Simple / Moderate / Complex
**Reasoning**: [brief explanation]
**Decompose candidate**: yes / no

### 8. Write Output Files

Load format templates from [references/templates.md](references/templates.md) before generating any files.

#### Option A — Discovery only
- Nothing more to write: `discovery.md` is in `${aiDir}/discoveries/` (Step 7)
- No index.yaml update needed

#### Option B — Full feature
- Create `${aiDir}/features/{feature-name}/` if it doesn't exist
- Generate `spec.md` using the **spec.md Format** template
- Generate `tech-spec.md` using the **tech-spec.md Format** template
- Create `dependencies.md` using the **dependencies.md Format** template
- Add entry to `${aiDir}/features/index.yaml`

#### Option C — Both
Do B. `discovery.md` stays in `${aiDir}/discoveries/` (Step 7) and is not copied into the feature directory.

### 9. Decompose (if flagged in Step 5)

After all output files are written, if decomposition was agreed:

```
Proceeding with feature-decompose workflow.
Suggested sub-feature boundaries based on discovery: {list}
Shall I proceed?
```

If yes: follow `/myspec:feature-decompose` [OPTIONAL — only when decomposition confirmed in Step 5] using the discovery findings as source material instead of an existing spec.

## Rules

- NEVER write any file before user confirms findings in Step 4
- `discovery.md` is ALWAYS written before `spec.md` or `tech-spec.md`
- `tech-spec.md` File Inventory uses `Action: exists` for all discovered files — never `add` or `create`
- Do not invent behavior not observed in code — mark gaps as Open Questions
- Do not ask one question per finding — always group Q&A by topic
- Agent decides when exploration is complete — do not ask user whether to keep looking
- Carry Open Questions forward from discovery → spec → tech-spec without dropping any

## Verification Checklist

- [ ] Description or paths collected before exploration started
- [ ] All file categories explored: entry points, UI, state, models, jobs, APIs, gates, translations, external deps
- [ ] Unknowns grouped by topic and asked in batches (not one-by-one)
- [ ] User explicitly confirmed findings before any file was written
- [ ] Output location chosen by user (A / B / C) before any file was written
- [ ] `discovery.md` written once, to the path that option names
- [ ] `discovery.md` contains all required sections: Overview, Entry Points, Components & Structure, Behavior, Integration Points, Feature Flags, Translations, Open Questions, Complexity Assessment
- [ ] If full feature (B or C): spec.md, tech-spec.md, dependencies.md created; index.yaml updated
- [ ] `tech-spec.md` File Inventory uses `Action: exists` for all discovered files
- [ ] Open Questions carried through from discovery.md into spec.md

## Integration

**Feeds into:** `/myspec:feature-spec-review` [OPTIONAL] — validate the generated spec before further work
**If complex:** `/myspec:feature-decompose` [OPTIONAL] — split into sub-features after discovery
**Source of truth:** `discovery.md` is the canonical record of what was found in code at the time of discovery
