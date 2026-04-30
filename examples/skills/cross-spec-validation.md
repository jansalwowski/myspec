# `/myspec:cross-spec-validation` — examples

Detects contradictions, broken contracts, and superseded assumptions between a target feature spec and all related feature specs. Reads specs only — no code exploration. Run after `feature-spec-review` (or `feature-tech-spec-review`) and before `feature-plan`.

**Contents**

- [Single sibling break detected](#single-sibling-break-detected)
- [Multiple breaks across sibling specs](#multiple-breaks-across-sibling-specs)
- [No conflicts — clean pass](#no-conflicts--clean-pass)

---

## Single sibling break detected

The everyday case: an updated spec changes one assumption that a sibling feature relied on. The skill names it specifically.

### Setup

`scheduled-reports` is at `spec_version: 2`. After the most recent update (added run-history retention), it now declares: *"AC-9: Each scheduled run is logged to the audit log table for 90 days."*

Sibling feature `notification-system` was the original audit-log consumer and its tech-spec assumed audit log entries persist for **30 days** (the default).

### Invocation

```
/myspec:cross-spec-validation scheduled-reports
```

### Skill flow

#### 1. Load target

Reads `scheduled-reports/{spec.md, tech-spec.md, dependencies.md}`. Extracts key concepts: schedule cadence presets, audit-log retention (90d), run-history table, email delivery hand-off.

#### 2. Build related set

**Dependency graph**: `scheduled-reports` depends on `notification-system`. `notification-system` is a dependency.

**Keyword scan**: greps `${aiDir}/features/*/{spec.md, tech-spec.md}` for `audit log`, `audit_log`, `retention`. Finds matches in:

- `notification-system/tech-spec.md` (multiple — owns the audit_log table).
- `compliance/spec.md` (one — references audit_log retention as a compliance requirement).

Combined related set: `notification-system`, `compliance`.

#### 3. Compare

Loads both related specs. Cross-references against `scheduled-reports`'s changes.

Finds a conflict:

- `scheduled-reports/spec.md` AC-9: *"Each scheduled run is logged to the audit log table for 90 days."*
- `notification-system/tech-spec.md` Architecture: *"Audit log entries are retained for 30 days, then purged by the nightly retention job."*

A scheduled-export run logged today would be purged after 30 days — but `scheduled-reports` says 90.

Also flags a soft warning:

- `compliance/spec.md` mentions audit-log retention as **at least 30 days** for compliance. Both 30 and 90 satisfy compliance, so no conflict — but a future change that *reduced* retention below 30 would violate compliance. Worth flagging.

#### 4. Report

```
Cross-spec validation: scheduled-reports

Related features (blast radius):
- notification-system (declared dependency + audit-log keyword match)
- compliance (audit-log keyword match)

⚠ CONFLICT — notification-system

  scheduled-reports/spec.md AC-9:
    "Each scheduled run is logged to the audit log table for 90 days."

  notification-system/tech-spec.md (Architecture):
    "Audit log entries are retained for 30 days, then purged by the
     nightly retention job."

  Effect: A scheduled run's audit entry would be purged 60 days early.
  AC-9 cannot be satisfied without changes to notification-system's
  retention behavior.

  Resolution paths:
  - A) Modify notification-system: retention becomes 90 days globally
       (or per-source-type, with scheduled-reports getting 90).
       → /myspec:feature-update notification-system
  - B) Modify scheduled-reports: AC-9 reduced to "30 days" to match
       notification-system. Likely simpler if 30 is acceptable.
       → /myspec:feature-update scheduled-reports
  - C) Carve out an exception: scheduled-reports keeps its own
       retention table separate from notification-system's audit_log.
       Reduces coupling but adds infrastructure.

i NOTE — compliance

  compliance/spec.md requires audit-log retention >= 30 days. Both 30
  and 90 satisfy this, so no current conflict — but flag it as a
  hard floor for future changes.
```

#### 5. User picks a resolution

User: option A — bump notification-system globally to 90 days.

The skill **does not** edit notification-system itself — it routes the user to `/myspec:feature-update notification-system` so the change is properly recorded with `spec_version` bumps and re-approval.

### Why this example matters

- **The skill doesn't auto-fix.** It identifies the conflict and offers structured resolution paths. Each path has consequences (cost vs. simplicity); the user chooses.
- **Soft warnings vs. hard conflicts.** The compliance match is *not* a conflict, but it's flagged as a constraint. Future changes that violate it would become real conflicts; surfacing the constraint now prevents accidental violations later.
- **Keyword scan + dependency graph together.** Either alone misses things. Dependency graph catches declared relationships; keyword scan catches undeclared ones (compliance wasn't declared, but the audit-log keyword match surfaces it).

---

## Multiple breaks across sibling specs

The harder case: a meaningful spec change ripples through several siblings, and each break is different.

### Setup

`user-invitations` was just updated to v3 (deprecated magic-link, added bulk-invite). Several siblings touch invitation flow.

### Invocation

```
/myspec:cross-spec-validation user-invitations
```

### Skill flow

#### Related set

Dependency graph: `notification-system` (dependency), `team-workspaces` (dependent). Keyword scan adds: `audit-log` (broad term), `signup-flow` (mentions invite acceptance), and the compliance spec.

Combined: 4 related features.

#### Conflicts found

**Conflict 1 — `notification-system`** (queue contract):

- `user-invitations` AC-7 says invites are "sent immediately on POST /invitations."
- `notification-system` says delivery is queued, may be deferred up to 60 seconds.
- Effect: AC-7 is technically violated. Resolution: weaken AC-7 to "within 60 seconds" or carve out invitations from the queue.

**Conflict 2 — `team-workspaces`** (deprecated capability):

- `user-invitations` v3 deprecated magic-link mode (removed AC-6).
- `team-workspaces/tech-spec.md` Implementation Step 7 says: *"Use magic-link invites for workspace member onboarding when the org has SSO enabled."*
- Effect: team-workspaces still references a deprecated capability. Either tech-spec needs updating to drop the magic-link path, or the deprecation is incomplete (need to migrate workspace onboarding first).

**Conflict 3 — `signup-flow`** (acceptance link path):

- `user-invitations` v3 added new query parameter `?source=bulk` to invite acceptance URLs (for analytics).
- `signup-flow/spec.md` AC-3 specifies the accepted invite-link format and doesn't include the new param.
- Effect: low severity — `signup-flow` may need to acknowledge the new parameter (or explicitly say it ignores it). Not a blocker but a documentation gap.

**No conflict — `compliance`**:

- Compliance requires audit log of invite send/accept events. `user-invitations` v3 still logs both. ✓

#### Report

```
Cross-spec validation: user-invitations (v3)

Related features (blast radius): 4
  notification-system  → CONFLICT
  team-workspaces      → CONFLICT
  signup-flow          → MINOR
  compliance           → ok

═══════════════════════════════════════
[1] CONFLICT — notification-system (delivery semantics)
   user-invitations AC-7: "sent immediately on POST"
   notification-system: queue, up to 60s deferred
   Resolution: weaken AC-7 to "within 60s" OR carve out
   invitations from queue.

[2] CONFLICT — team-workspaces (deprecated capability reference)
   user-invitations v3: magic-link removed
   team-workspaces tech-spec Step 7: still requires magic-link
   for SSO orgs.
   Resolution: update team-workspaces to drop magic-link OR
   keep magic-link active for SSO use case (revisit deprecation
   scope in user-invitations).

[3] MINOR — signup-flow (acceptance link format)
   user-invitations v3: added ?source= query param.
   signup-flow AC-3: doesn't reference it.
   Resolution: signup-flow can ignore the param; recommend a
   one-line acknowledgment in its spec to prevent future
   "what's this?" investigations.

════════════════════════════════════════
Recommended order:

1. Resolve [2] FIRST — magic-link deprecation incomplete; you may
   need to walk back the deprecation scope or commit to migrating
   team-workspaces onboarding before user-invitations v3 ships.
2. Resolve [1] — likely a one-line change to AC-7.
3. Resolve [3] — non-blocking, can be a separate small update.

Until [2] is resolved, do NOT proceed to /myspec:feature-plan
on user-invitations — the deprecation will silently break
team-workspaces' onboarding.
```

### Why this example matters

- **Severity-ranked recommendations.** [2] is a *blocker* (incomplete deprecation), [1] is a *fix* (semantic mismatch), [3] is a *nice-to-have*. The order matters — fixing [1] first wouldn't unblock the real problem.
- **The skill is willing to halt the pipeline.** "Do NOT proceed to feature-plan" is a hard stop — it's saying *this update is broken in ways that planning won't catch*.
- **Real-world updates often have several ripples.** A "small" change to one spec frequently touches 3–4 siblings. Skipping cross-spec-validation produces silent breakage that surfaces during implementation or — worse — in production.

---

## No conflicts — clean pass

The base case: an update that legitimately doesn't affect any sibling. The skill confirms and gets out of the way.

### Setup

`favorite-reports` was just updated v1 → v2 to add a "favorite count" displayed next to each starred report (purely UI-internal, no API change). Run cross-spec-validation.

### Invocation

```
/myspec:cross-spec-validation favorite-reports
```

### Skill flow

#### Related set

Dependency graph: nothing depends on `favorite-reports`, and it depends on nothing. Keyword scan: matches `favorite-` and `star` in dashboards-favorites, queries-favorites, collections-favorites — but those are the same-pattern siblings, not consumers.

Examined those three: each manages its own favorites table; none reference `favorite-reports` directly.

#### Compare

No actual contracts cross between these features. The "favorite-" pattern is shared *implementation*, not a shared *interface*. No conflict.

#### Report

```
Cross-spec validation: favorite-reports (v2)

Related features (blast radius): 0 active consumers
  Pattern siblings (no contract): dashboards-favorites,
    queries-favorites, collections-favorites

✓ No conflicts found.

The v2 change (add favorite-count display) is UI-internal and
introduces no contract changes that affect other features.

Safe to proceed: /myspec:feature-plan favorite-reports
```

### Why this example matters

- **Empty result is a real result.** A clean pass tells the user it's safe to proceed — that confidence is the whole point of running validation.
- **"Pattern siblings" are noted but not treated as conflicts.** Three other features use the same "favorites table per entity" pattern, but they don't share contracts. The skill recognizes the difference between *similar code* and *coupled code*.
- **Hand-off line at the end.** Even on a clean pass, the skill tells you what's next. Saves the user from having to remember the next step in the pipeline.
