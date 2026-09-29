---
title: "Customer Portal"
status: approved
phase: 1
priority: P1
spec_version: 1
created: 2026-06-02
last_updated: 2026-06-10
---

# Customer Portal

## Overview
Customers log in with a magic link and see their open and paid invoices.

## Requirements
1. REQ-001: A customer must be able to request a login link by email.
2. REQ-002: A logged-in customer must see every invoice addressed to them, newest first.

## User Stories
- As a customer, I want to see my invoices without calling support.

## Acceptance Criteria
- [ ] AC-1: Requesting a link for a known email sends exactly one email.
- [ ] AC-2: The invoice list shows only the customer's own invoices.

## Out of Scope
- Paying invoices online.
