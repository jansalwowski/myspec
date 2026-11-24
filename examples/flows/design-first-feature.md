# Flow: design-first feature (brief, mockups, then the spec)

Some features are easier to specify after you have seen them. The layout is the problem, the interaction is new, or the user says "I'll know it when I see it". For these, a short brief and rough mockups come before the detailed spec. For backend, integration, rule-heavy or compliance work, write the spec first ([full feature delivery](full-feature-delivery.md)). The choice is per feature.

The example feature is **Accountant Access**: customers invite their accountant to see and export invoices.

## At a glance

| Step | Skill | Produces | Approval gate |
|------|-------|----------|---------------|
| 1 | `/myspec:feature-requirements` | `spec.md` with `stage: brief`, manifest entry `draft` | questions (optional) |
| 2 | `/myspec:feature-mockup --explore` | rough variants in `exploration/`; picks logged as `[decision]` lines in the brief | pick a variant |
| 3 | `/myspec:feature-mockup` | mockups in `mockups/` that trace to the brief's REQ IDs | yes / changes |
| 4 | `/myspec:feature-spec` | the same `spec.md`, completed: ACs from mockup states, `stage` removed; `dependencies.md` | yes / changes |
| 5 | `/myspec:feature-spec-review` | `status: approved` | no Critical or High findings |
| 6 onward | `feature-tech-spec` → `feature-plan` → `feature-implement` → `feature-complete` | as in the spec-first flow | as usual |

Steps 2 and 3 are both optional. A small feature can go from the brief straight to step 3, or skip mockups and go to step 4.

---

## 1. Brief

```
/myspec:feature-requirements accountant-access TICKET-1
```

The skill drafts the brief from the ticket first, then challenges it: the ticket named a solution ("invite") and vague words ("simple", "secure"). The user answers four questions. The result is about 25 lines: Problem, Who, Today, Success, Appetite, four one-line requirements, no-gos, and tagged open questions such as:

```markdown
- [open] What does "secure" require? (ticket) -> resolve by: spec; default: same login rules as customers
```

The skill recommends design first, because the invite flow and the accountant's view are new screens. Details: [feature-requirements examples](../skills/feature-requirements.md).

## 2. Rough variants

```
/myspec:feature-mockup accountant-access --explore
```

Three greyscale variants of the accountant's view, which differ in structure: one invoice list, a per-customer dashboard, and a monthly folder view. They are written to `exploration/`, a throwaway folder. The user picks the monthly folders. The pick is appended to the brief:

```markdown
- [decision] Accountant view groups invoices by month (user)
```

## 3. Mockups

```
/myspec:feature-mockup accountant-access
```

High-fidelity mockups of the chosen layout. The brief has no acceptance criteria yet, so each surface traces to a REQ ID. A surface with no REQ is scope creep: the user drops it or adds a REQ to the brief. `exploration/` is reference only.

## 4. Complete the spec

```
/myspec:feature-spec accountant-access
```

`feature-spec` sees `stage: brief` and completes the file in place. Each mockup state becomes an example, the examples group into rules, and each rule becomes an AC that names its mockup state. The "what mockups miss" checklist then covers what no screen shows: bounced invite emails, expired links, the audit entry on revoke, a 10,000-invoice export. Each item becomes an AC, is marked N/A with a reason, or becomes an open question. The `[decision]` lines turn into requirements. `stage` is removed and `dependencies.md` is written. Details: [feature-spec examples](../skills/feature-spec.md#completing-a-brief-after-mockups).

## 5. Review and continue

```
/myspec:feature-spec-review accountant-access
```

From here the feature follows the normal pipeline. Run on the brief in step 1, the review would not report the missing User Stories and Acceptance Criteria as defects: it would say the spec is still a brief and offer `/myspec:feature-spec` first. A brief is never approved, so `feature-tech-spec` and `feature-plan` refuse it.

## Why this flow matters

The spec is written once, after the mockups answered the layout questions, so it does not need a rewrite after every mockup round. The brief and the full spec are the same file, so a change made by hand or by `feature-update` stays in one place.
