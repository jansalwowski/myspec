---
title: "Invoice Reminders"
status: draft
phase: 1
priority: P2
spec_version: 1
stage: brief
created: 2026-11-20
last_updated: 2026-11-20
---

# Invoice Reminders

## Overview
- Problem: customers forget unpaid invoices until they are overdue
- Who: small-business owner (sender), their customers (recipients)
- Today: owners chase late payers by hand from their own inbox

## Goals
- Success: fewer invoices pass their due date unpaid
- Appetite: not set

## Requirements
1. REQ-001: Reminder email three days before the due date
2. REQ-002: Reminder email on the due date
3. REQ-003: Owner turns reminders on or off per customer
4. REQ-004: No reminder once the invoice is paid

## Out of Scope
- SMS reminders

## Open Questions
- [open] Can the owner edit the reminder text? (inferred) -> resolve by: mockup; default: no
- [assumption] Reminders go to the invoice's billing email (inferred)
- [fact] Owners chase late payers by hand today (user)
