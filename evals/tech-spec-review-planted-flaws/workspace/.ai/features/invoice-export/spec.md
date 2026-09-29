---
title: "Invoice CSV Export"
status: approved
phase: 1
priority: P2
spec_version: 2
created: 2026-09-20
last_updated: 2026-09-24
---

# Invoice CSV Export

## Overview
Account owners can download the invoices of a chosen period as a CSV file for bookkeeping.

## Goals
- Let users move invoice data into spreadsheets and accounting tools without copying it by hand.

## Requirements
1. REQ-001: The user must be able to choose a date range (start and end date, both inclusive, by issue date).
2. REQ-002: The export must contain one row per issued invoice in the range.
3. REQ-003: Each row must contain invoice number, issue date, customer name, net amount, currency and status.
4. REQ-004: Draft invoices must never appear in an export.
5. REQ-005: If the range contains no invoices, the user must see the message "No invoices in this period" instead of an empty file.

## User Stories
- As an account owner, I want to export last month's invoices so that my accountant can import them.

## Acceptance Criteria
- [ ] AC-1: Choosing a range and clicking "Export" downloads a CSV with one row per issued invoice in the range.
- [ ] AC-2: A draft invoice dated inside the range is absent from the file.
- [ ] AC-3: Column headers are exactly: number, issue_date, customer, net_amount, currency, status.
- [ ] AC-4: A range with no invoices shows "No invoices in this period" and downloads nothing.

## Out of Scope
- PDF export.
- Scheduled or emailed exports.

## Open Questions
- None.
