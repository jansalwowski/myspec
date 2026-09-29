---
title: "Invoice Due Dates"
status: approved
phase: 1
priority: P2
spec_version: 1
created: 2026-09-22
last_updated: 2026-09-24
---

# Invoice Due Dates

## Overview
Every issued invoice gets a due date derived from the customer's payment terms, and the invoice API says whether the invoice is overdue.

## Goals
- Let account owners see at a glance which invoices are late.

## Requirements
1. REQ-001: An invoice's due date is its issue date plus the customer's payment terms, in calendar days.
2. REQ-002: A customer without payment terms gets 14 days.
3. REQ-003: An issued invoice is overdue when today is after its due date.
4. REQ-004: The invoice API response carries the due date as an ISO 8601 date (YYYY-MM-DD) in a `due_date` field.
5. REQ-005: A paid invoice is never overdue, whatever its due date.

## User Stories
- As an account owner, I want to see each invoice's due date so that I know when to chase payment.
- As an account owner, I want late invoices flagged so that I do not have to compare dates myself.

## Acceptance Criteria
- [ ] AC-1: An invoice issued on 2026-09-01 to a customer with 30-day terms is due on 2026-10-01.
- [ ] AC-2: An invoice issued on 2026-09-01 to a customer with no terms is due on 2026-09-15.
- [ ] AC-3: On 2026-10-02, an issued invoice due on 2026-10-01 is reported as overdue; on 2026-10-01 it is not.

## Out of Scope
- Reminder emails.
- Business-day calendars and holidays.

## Open Questions
- None.
