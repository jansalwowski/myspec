---
title: "Invoice CSV Export"
status: draft
phase: 1
priority: P2
spec_version: 1
created: 2026-09-20
last_updated: 2026-09-20
---

# Invoice CSV Export

## Overview
Account owners can download their invoices as a CSV file for bookkeeping.

## Goals
- Let users move invoice data into spreadsheets and accounting tools.

## Requirements
1. REQ-001: The user must be able to choose a date range (start and end date).
2. REQ-002: The export must include every invoice in the range, regardless of its status.
3. REQ-003: Each row must contain invoice number, issue date, customer name, net amount, currency and status.
4. REQ-004: Draft invoices must never appear in an export.
5. REQ-005: The file downloads immediately after the user clicks "Export".

## Acceptance Criteria
- [ ] AC-1: Choosing a range and clicking "Export" downloads a CSV with one row per invoice in the range.
- [ ] AC-2: The export should be fast.
- [ ] AC-3: Column headers match the fields listed in REQ-003.

## Out of Scope
- PDF export.
- Scheduled or emailed exports.

## Open Questions
- None.
