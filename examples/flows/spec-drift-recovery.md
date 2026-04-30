# Flow — spec drift recovery

A feature shipped six months ago. Since then: refactors, bug fixes, half-finished follow-ups. The code has moved; the spec hasn't. Now you're starting work nearby and discover the docs are lying. This flow shows how to diagnose, fix, and re-validate.

## The situation

Feature: **`user-invitations`** — sending invite emails for team workspaces. Shipped 2025-11-04. Since then:

- Two file moves: `src/invitations/service.ts` → `src/services/invitation-service.ts`, etc.
- A new "resend invite" capability was bolted on without updating tech-spec.
- The email template was extracted into `notification-system` (cross-feature contract).
- Original author left the company three months ago.

You're about to add SSO-driven auto-invitations and need to know what's actually true. Time to run the recovery sequence.

## At a glance

| Step | Skill | Purpose |
|------|-------|---------|
| 1 | `/myspec:feature-verify` | Diagnose drift, get a punch list |
| 2 | `/myspec:feature-spec-sync` | Fix file paths, checkbox states, version mismatches |
| 3 | `/myspec:cross-spec-validation` | Catch broken contracts with sibling features |
| 4 | `/myspec:feature-spec-cleanup` | Move tech leakage from spec to tech-spec |
| 5 | `/myspec:feature-verify` (again) | Confirm health is green |

These skills compose. Verify is read-only and routes you to the right fix; the fixes are interactive and ask before changing anything.

---

## 1. Verify — get the diagnosis

```
/myspec:feature-verify user-invitations
```

The skill walks all 8 categories and produces a severity-ranked report. Real output for a well-and-truly drifted feature looks something like:

```
Feature Health: user-invitations
─────────────────────────────────

[CRITICAL]
  ✗ tech-spec.md File Inventory references 4 paths that no longer exist:
    - src/invitations/service.ts (moved → src/services/invitation-service.ts?)
    - src/invitations/types.ts (moved → src/services/invitation-types.ts?)
    - src/invitations/email-template.ts (deleted; email now in notification-system)
    - src/invitations/__tests__/service.test.ts (moved alongside the service)

[HIGH]
  ✗ spec.md spec_version: 1, tech-spec.md based_on_spec_version: 1
    But spec.md has unchecked Open Questions added 2026-02 about
    auto-invitations — likely needs spec_version bump.
  ✗ tech-spec.md "Implementation Steps" has 6/8 unchecked, but the
    files described in those 6 steps DO exist. Status drifted from reality.

[MEDIUM]
  ⚠ spec.md AC-3 mentions `InvitationService.sendEmail()` — that's an
    implementation detail, belongs in tech-spec.
  ⚠ scenarios.md hasn't been updated since 2025-11. Resend-invite
    capability has zero scenarios.

[LOW]
  ⚠ index.yaml entry shows status: complete, phase: 1. But spec has new
    Open Questions, suggesting partial re-opening. Consider phase: 2.

Recommended sequence:
  1. /myspec:feature-spec-sync user-invitations  — fix file paths + checkbox states
  2. /myspec:cross-spec-validation user-invitations — verify notification-system contract
  3. /myspec:feature-spec-cleanup user-invitations  — move AC-3 leakage to tech-spec
  4. /myspec:feature-verify user-invitations  — re-run, confirm green
```

The report doubles as a routing layer — every issue lists the skill that fixes it.

---

## 2. Spec sync — fix the mechanical drift

```
/myspec:feature-spec-sync user-invitations
```

This skill is interactive — it never edits without user confirmation. Walking through:

### Path validation

The skill globs the file inventory paths, finds the misses, fuzzy-matches against the codebase, and proposes:

```
File path drift detected:

1. src/invitations/service.ts
   → fuzzy match: src/services/invitation-service.ts (90% similar)
   → action: UPDATE path

2. src/invitations/types.ts
   → fuzzy match: src/services/invitation-types.ts (88% similar)
   → action: UPDATE path

3. src/invitations/email-template.ts
   → no fuzzy match
   → action: REMOVE from inventory (likely extracted to another feature)

4. src/invitations/__tests__/service.test.ts
   → fuzzy match: src/services/__tests__/invitation-service.test.ts
   → action: UPDATE path

Apply these changes?
```

User: *"Yes for 1, 2, 4. For #3, remove from inventory and add a note that the email template now lives in notification-system."*

The agent edits `tech-spec.md`'s File Inventory and adds a Decisions row:

```
- **Decision (2026-04-30)**: Invitation email template extracted to
  notification-system feature. Inventory entry removed; see notification-system/tech-spec.md.
```

### Implementation checkboxes

Six unchecked items have files that exist. The skill verifies each:

```
Implementation Steps reconciliation:

Step 4: "Add resend-invite endpoint to InvitationService"
  → src/services/invitation-service.ts contains `resendInvite()` method (line 87)
  → action: CHECK [x]

Step 5: "Wire resend button in TeamMemberRow"
  → src/components/TeamMemberRow.tsx renders <ResendInviteButton/>
  → action: CHECK [x]

... (4 more) ...

Apply?
```

User: *"Apply all."*

### Spec version alignment

The skill notices the spec has new Open Questions but `spec_version: 1` is unchanged. Prompts:

> The Open Questions added in February suggest the spec was modified after the original approval. Should I bump `spec_version` to 2 and reset `tech-spec.md`'s `based_on_spec_version` to 2 (with status: needs-review)?

User: *"Yes."*

The skill writes the version bumps and flips tech-spec status to `draft`.

### Reports back

```
spec-sync complete. Applied 12 changes:
  - 3 file paths updated
  - 1 path removed (with replacement note)
  - 6 checkboxes flipped to [x]
  - spec_version bumped 1 → 2
  - tech-spec status: approved → draft (needs re-review at v2)

Remaining issues from /feature-verify (2):
  - Cross-spec contract with notification-system (run cross-spec-validation)
  - AC-3 implementation leakage (run feature-spec-cleanup)
```

---

## 3. Cross-spec validation — verify the contract with notification-system

```
/myspec:cross-spec-validation user-invitations
```

Now that the email template was extracted to `notification-system`, there's an implicit contract: invitations call into notification-system to send. The skill loads both specs and looks for breaks.

```
Contract analysis: user-invitations ↔ notification-system

✓ user-invitations references NotificationService.send({type: 'invitation', ...})
✓ notification-system/tech-spec.md defines that exact signature.
✓ notification-system supports the 'invitation' type since v3.

⚠ user-invitations/spec.md AC-7: "Invite email is sent immediately on
   POST /invitations."
⚠ notification-system/spec.md AC-2: "Notifications are queued; delivery
   may be deferred up to 60 seconds."

→ Contract conflict: 'immediately' vs 'queued with up-to-60s delay'.
   Suggested resolution: weaken user-invitations AC-7 to 'sent within
   60 seconds' OR explicitly carve out invitation type from
   notification-system queue.
```

User picks the first option (weaken the AC; the queue is fine for invitations). Agent rewrites AC-7, bumps `spec_version` to 3 to reflect.

Re-runs cross-spec-validation — green.

---

## 4. Spec cleanup — move the tech leakage

```
/myspec:feature-spec-cleanup user-invitations
```

The skill scans `spec.md` for telltale tech leakage:

- Class/function names (`InvitationService.sendEmail()` in AC-3)
- File paths
- SQL/code snippets
- Specific framework calls

Finds AC-3 and proposes:

```
Spec leakage in AC-3:
  Current: "On POST /invitations, the system calls
            InvitationService.sendEmail() to dispatch the email."
  Proposed:
    spec.md AC-3:
      "On POST /invitations, the system sends an invite email to the
       recipient address."
    tech-spec.md "API Endpoints" (POST /invitations):
      Add row: "Calls notificationService.send() with type='invitation'."

Apply?
```

User: *"Apply."* The leakage moves; spec is implementation-clean again.

---

## 5. Verify (again) — confirm green

```
/myspec:feature-verify user-invitations
```

```
Feature Health: user-invitations
─────────────────────────────────

[CRITICAL] none
[HIGH]     none
[MEDIUM]   none
[LOW]
  ⚠ index.yaml entry: status complete, phase 1.
    Re-classification suggests phase 2 (resend-invite + auto-invite work
    in progress at spec_version 3, tech-spec at draft).
    Recommended: bump phase to 2 and consider status: in-progress.

→ Run /myspec:feature-update to plan the re-opening, or manually
  edit the manifest if the re-opening is just bookkeeping.
```

User decides the re-opening is real work (the SSO auto-invite) and runs `/myspec:feature-update` to plan it — which is its own flow (out of scope for this example, but follows the same shape as `feature-tech-spec` + `feature-plan` for the *delta* from current state).

---

## What this flow demonstrates

- **`feature-verify` is the entry point.** Read-only, exhaustive, routes you to the right fix skill for each issue. Don't try to remember which skill fixes which class of drift — just run verify first.
- **Drift comes in three shapes**: mechanical (paths moved, checkboxes stale), semantic (contracts broken with siblings), structural (tech details leaked into spec). Each has a dedicated fix skill. Don't try to do all three by hand.
- **`spec-sync` is conservative**. It proposes; you approve. It will not silently rewrite paths just because they look similar. The fuzzy match + confirmation pattern is what makes it safe to run on a feature you didn't write.
- **`cross-spec-validation` after `spec-sync`** is the order that matters. Path fixes change what the tech-spec actually claims to interface with — the contract check has to follow.
- **`feature-spec-cleanup` is mechanical and almost always safe.** Implementation details moving from spec to tech-spec is a one-way migration. Run it whenever verify flags leakage.
- **Re-running `feature-verify` at the end is non-optional.** It's how you know the recovery actually worked, vs. created new issues.

---

## When a feature is too far gone

If `feature-verify` returns 10+ critical issues, the spec is so stale that fixing it feels like rewriting it, and the original author is unreachable — consider treating the feature as **un-specified existing code**. Use `/myspec:feature-spec` from scratch (read the code, write a spec that matches reality, mark `status: post-hoc`), then run `/myspec:feature-tech-spec` to backfill the design doc. Faster than archaeology.
