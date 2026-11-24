# `/myspec:feature-requirements` examples

Turns rough input (a ticket, a chat message, an idea file) into a brief: a short `spec.md` with `stage: brief`, one-line requirements and tagged open questions. The brief is the input for rough mockups or for `/myspec:feature-spec`, which completes the same file later. The skill challenges the request and asks questions, but the user can stop at any time and the brief is written anyway.

**Contents**

- [A vague ticket becomes a brief](#a-vague-ticket-becomes-a-brief)
- [The user stops after one round](#the-user-stops-after-one-round)
- [A full spec already exists](#a-full-spec-already-exists)

---

## A vague ticket becomes a brief

### Setup

A support ticket says: *"Customers want to invite their accountant to see invoices. Make it simple and secure."* Nobody has decided what "see" means.

### Invocation

```
/myspec:feature-requirements accountant-access TICKET-1
```

### Skill flow

The skill reads the ticket and drafts the brief before it asks anything. It fills only what the ticket supports and turns each gap into a tagged line:

```markdown
## Open Questions
- [fact] Request came from 4 customers in one month (ticket)
- [assumption] Accountant needs read-only access (inferred)
- [open] Can an accountant serve several customers? (inferred) -> resolve by: spec; default: yes, one login
```

It rates the brief fields:

| Field | Rating |
|-------|--------|
| Problem | Partial: the ticket names a solution ("invite") |
| Who | Clear |
| Today | Missing |
| Success | Missing |
| Appetite | Missing |
| Requirements | Partial |
| Out of Scope | Missing |

Then it leads with the strongest concern:

> The ticket asks for an invite feature. The problem behind it is not stated. What do customers do today when their accountant needs the invoices?

It asks 4 questions in one call, each with a recommended answer and a line on why it matters: what customers do today, read-only or also export, how long access lasts, and what is out of scope.

**User**: today they email PDF exports every month; read-only plus CSV export; access until revoked; no editing, no payments.

### Result

`ai/features/accountant-access/spec.md`, 22 body lines:

```markdown
---
title: "Accountant Access"
status: draft
phase: 1
priority: P2
spec_version: 1
stage: brief
created: 2026-11-24
last_updated: 2026-11-24
---

## Overview
- Problem: customers email monthly invoice exports to their accountant by hand
- Who: customer admin, external accountant
- Today: PDF exports sent by email every month (user)

## Goals
- Success: we will know when customers stop sending monthly exports
- Appetite: not set

## Requirements
1. REQ-001: invite an accountant by email
2. REQ-002: accountant sees invoices, read-only
3. REQ-003: accountant exports invoices as CSV
4. REQ-004: customer revokes access

## Out of Scope
- Editing invoices, payments

## Open Questions
- [decision] Access lasts until revoked (user)
- [open] Can an accountant serve several customers? (inferred) -> resolve by: spec; default: yes, one login
- [open] What does "secure" require (2FA, audit log)? (ticket) -> resolve by: spec; default: same login rules as customers
```

A manifest entry with `status: draft` is added. No dependencies.md yet. The skill says the files are uncommitted, then recommends the next step. The invite flow and the accountant's view are new screens, so it recommends design first:

> **Next step?** `/myspec:feature-mockup accountant-access --explore` (Recommended) / `/myspec:feature-spec accountant-access` / Stop here

### Why this example matters

The ticket named a solution and two vague words ("simple", "secure"). The brief names the problem instead and keeps "secure" as an open line with a default, so mockups can start now and the spec resolves it later.

---

## The user stops after one round

Same ticket. After the first round of questions, the user answers one and says:

**User**: Enough for now, just write it.

The skill writes the brief at once. The three unanswered questions become `[assumption] ... (inferred)` lines with their defaults. It does not refuse because something is open and does not ask again.

### Why this example matters

The skill assists and never gates. An open question is a warning with a default, not a blocker.

---

## A full spec already exists

### Setup

`ai/features/accountant-access/spec.md` exists without `stage: brief`: someone already wrote the full spec.

### Skill flow

The skill does not overwrite it:

> accountant-access already has a full spec. To change it, run `/myspec:feature-spec accountant-access` while it is unimplemented, or `/myspec:feature-update accountant-access` once it is built.

### Why this example matters

One feature keeps one spec.md. The brief is an early stage of that file, so the skill refines a brief in place and leaves a full spec alone.
