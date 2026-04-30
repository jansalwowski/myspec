# `/myspec:idea-process` — examples

Promotes a queued idea into feature documentation: creates `spec.md`, `dependencies.md`, `scenarios.md`, and `seed.json` in `ai/features/{name}/`. Picks the highest-priority `[ ]` idea automatically — or processes a named one. **Always asks clarifying questions** (the skill is explicit about this — it's non-skippable).

**Contents**

- [Clean conversion of a queued idea](#clean-conversion-of-a-queued-idea)
- [Idea blocked by unsatisfied dependencies](#idea-blocked-by-unsatisfied-dependencies)
- [Idea too vague — bounces back to brainstorm](#idea-too-vague--bounces-back-to-brainstorm)

---

## Clean conversion of a queued idea

The standard flow: an idea is well-formed and ready, dependencies are satisfied, the user runs the skill and ends with a draft spec.

### Setup

`ideas/PRIORITY-LISTING.md` has `keyboard-shortcut-help` at HIGH `[ ]` (from the [idea-intake example](idea-intake.md#standard-new-idea-with-clear-priority)). No upstream dependencies.

### Invocation

```
/myspec:idea-process
```

(no argument — pick the next available HIGH idea)

### Skill flow

#### 1. Select idea

The skill reads `PRIORITY-LISTING.md`, finds the highest-priority `[ ]`, confirms dependencies satisfied (none here), and marks it `[~]` (in progress) immediately so a parallel agent doesn't double-process.

#### 2. Initial analysis

Reads `ideas/keyboard-shortcut-help.md` and the related parts of the codebase (`src/shortcuts/registry.ts`). Identifies:

- The shortcut registry already exists and exposes a `listShortcuts()` API.
- No global keyboard handler at the app level — would need to add one.
- No existing modal/overlay component pattern — needs design.

#### 3. Clarifying questions (mandatory step)

> A few questions before I draft the spec:
>
> **Scope**
> - Show shortcuts for the **current page only**, or **all global shortcuts** too?
> - Should the overlay be modal (blocks interaction) or non-modal (dismissible by clicking out)?
>
> **UX**
> - Should pressing `?` again close the overlay, or only Escape?
> - Should it be searchable (filter by shortcut name) or just a list?
> - Sort: by category, alphabetical, or by frequency-of-use?
>
> **Data**
> - Where do we get the human-readable description for each shortcut? Currently the registry stores the keybinding only.
>
> **Out of scope?**
> - Customizing shortcuts? Recording new ones?
> - Mobile / touch? `?` doesn't have an obvious touch equivalent.

**User**: current page + global combined; non-modal; `?` toggles; not searchable in v1; sort by category; descriptions added to the registry as a new field; customization out of scope; touch out of scope.

#### 4. Generate feature scaffolding

Creates `ai/features/keyboard-shortcut-help/`:

- `spec.md` — populated from the answers. Frontmatter `status: draft, spec_version: 1, priority: P1`. Required sections present.
- `dependencies.md` — names the shortcut registry as an internal dependency, no external libs.
- `scenarios.md` — Gherkin scenarios for the main flows: open with `?`, close with `?`, close with Escape, click outside (no-op for non-modal but stays open), shortcut list shows current page's category first.
- `seed.json` — sample registry entries with the new `description` field. Useful for testing.

#### 5. Update manifest + queue

Adds `keyboard-shortcut-help` to `ai/features/index.yaml`:

```yaml
- name: keyboard-shortcut-help
  title: "Keyboard Shortcut Help Overlay"
  status: draft
  phase: 1
  priority: P1
  depends-on: []
```

Marks the idea `[x]` in `PRIORITY-LISTING.md`:

```markdown
- [x] **keyboard-shortcut-help** — `?` overlay listing keyboard shortcuts. (→ `features/keyboard-shortcut-help/`)
```

#### 6. Hand-off

> Created `ai/features/keyboard-shortcut-help/` — spec, dependencies, scenarios, seed all drafted.
>
> **Next:** `/myspec:feature-spec-review keyboard-shortcut-help` to validate the spec before tech-spec.

### Why this example matters

- **Mandatory clarifying questions are the point.** Even an idea that *looks* complete has gaps the file doesn't cover (sort order, descriptions field, mobile scope). The skill makes the user answer them before the spec lands.
- **Four files, not one.** `scenarios.md` and `seed.json` are easy to forget if you're writing the spec by hand — `idea-process` always emits them so the next stages of the pipeline have what they need.
- **Marking `[~]` early** is the concurrency fix — without it, two agents/users running this in parallel would both pick the same idea.

---

## Idea blocked by unsatisfied dependencies

The skill refuses cleanly when prerequisites aren't met.

### Setup

The user runs:

```
/myspec:idea-process scheduled-bulk-export
```

This idea (from [idea-intake.md scenario 3](idea-intake.md#idea-blocked-by-unsatisfied-dependencies)) has a noted blocker: `bulk-export` is queued but not yet processed.

### Skill flow

#### 1. Select idea

The skill finds `scheduled-bulk-export` in the queue, sees its `Depends on:` line listing `bulk-export ✗`.

#### 2. Verify dependencies

Reads `ai/features/index.yaml`. `scheduled-reports` ✓, `bulk-export` not found in manifest. Searches `ideas/PRIORITY-LISTING.md`: present, status `[ ]` (still unprocessed).

#### 3. Refuse + explain

> Cannot process `scheduled-bulk-export` — dependency not satisfied:
>
> - `scheduled-reports` ✓ (shipped, available to depend on)
> - `bulk-export` ✗ (queued idea at HIGH `[ ]`, not yet promoted to feature)
>
> A spec for this idea would have nothing to anchor the bulk-export contract against — `tech-spec.md` would later fail cross-spec validation.
>
> Options:
>
> - **A) Process `bulk-export` first** — run `/myspec:idea-process bulk-export`. Comes back to this once that's at least a draft feature.
> - **B) Override** — process anyway with the dependency unmet. The spec will explicitly mark the assumption (block via Open Questions). Use only if you're committed to processing bulk-export imminently.

**User**: A — let's do bulk-export first.

The skill **does not** mark `scheduled-bulk-export` as `[~]`. It stays `[ ]` so the next run picks it up cleanly.

### Why this example matters

- **Refusal is structured.** "Process upstream first" or "explicit override" — both are valid, both are visible. The skill doesn't silently block.
- **Doesn't mark `[~]` on refusal.** A refused idea stays `[ ]` so the queue accurately reflects what's processable.
- **The override path exists for a reason.** Sometimes the dependency is "in flight in another agent's worktree" and the user knows it'll land soon. Forcing strict ordering would block legitimate parallelism.

---

## Idea too vague — bounces back to brainstorm

Some ideas should never become features without more thinking. The skill notices and says so.

### Setup

The queue has `[ ]` `redesign-onboarding` at MEDIUM. The idea file says simply: *"Onboarding is bad. Redesign it. priority MEDIUM."*

User runs:

```
/myspec:idea-process redesign-onboarding
```

### Skill flow

#### 1. Read

Reads the idea file. ~12 words of body. No specifics.

#### 2. Refuse to process

The skill stops before even asking clarifying questions:

> The idea file for `redesign-onboarding` doesn't have enough scope to convert to a spec. The body is essentially "onboarding is bad, redesign it" — that's a direction, not a feature.
>
> If I tried to process this, I'd be guessing at:
>
> - What specifically is bad? (Length? Confusion? Drop-off at a specific step? Visual design?)
> - What "good" looks like — quantitative goal, qualitative target, both?
> - Whether the redesign means small fixes to current flow, or a from-scratch alternative.
> - Which user segment we're optimizing for (new free users, paid trial-starters, returning?).
>
> Each of those is a meaningful product decision. Inventing answers in a spec would produce a doc that doesn't match anyone's actual intent — including yours.
>
> Suggested path:
>
> - **A) Brainstorm first** — run `/myspec:brainstorm redesign onboarding` to scope the problem before specing the solution. The output will go back into `ideas/` with much more detail; then re-run `idea-process`.
> - **B) Update the idea file by hand** — if you already know what you want, expand the file with specifics, then re-run `idea-process`.
> - **C) Drop the idea** — if it was a passing thought without commitment, mark it `[skip]` and move on.

**User**: A.

The skill **does not** mark `[~]` (the idea isn't being processed). It leaves the queue alone and hands off to brainstorm.

### Why this example matters

- **"Process anyway" isn't always offered.** When the idea has zero specificity, even an override would produce garbage. The skill is willing to refuse outright.
- **Routing to `brainstorm`** is the right move — it's exactly what brainstorm is for. The user doesn't need to figure that out themselves.
- **Specificity threshold is judgment-based, not bytecount.** A short idea file can still be processable if it names a concrete behavior ("press `?` to show shortcuts"). A long idea file can still be vague if it's all aspirations ("make it better").
