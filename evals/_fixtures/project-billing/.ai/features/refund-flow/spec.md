---
title: "Refund Flow"
status: draft
phase: 2
priority: P3
spec_version: 1
created: 2026-09-01
last_updated: 2026-09-01
---

# Refund Flow

## Overview
Account owners can issue a full or partial refund against a paid invoice.

## Requirements
1. REQ-001: A refund must reference exactly one paid invoice.
2. REQ-002: The refunded amount must not exceed the invoice's paid amount.

## User Stories
- As an account owner, I want to refund a customer without leaving the app.

## Acceptance Criteria
- [ ] AC-1: Refunding more than the paid amount is rejected with a message.

## Out of Scope
- Refunds to a different payment method.
