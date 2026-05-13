---
name: "feature-spec-cleanup"
description: "Use when a spec.md has leaked implementation details (SQL, language code blocks, ORM patterns, database indexes, source file paths) that belong in tech-spec.md. Keywords: spec cleanup, separate business from technical, move code out of spec, spec hygiene. Do NOT use for creating new specs."
tags: [documentation, cleanup, maintenance, spec]
---

# Spec Cleanup

Clean up spec.md files that violate the business-vs-technical documentation separation by moving implementation details to tech-spec.md.

## Instructions

### 1. Load Context

Read the target feature's documentation:
- Read `${aiDir}/features/{feature}/spec.md`
- Read `${aiDir}/features/{feature}/tech-spec.md` (if exists)
- Read `.claude/rules/workflow.md` for documentation rules (if it exists)

### 2. Detect Violations

Scan spec.md for technical implementation content:

**Code blocks** with language tags (examples — adjust to project stack):
- ` ```sql ` - SQL queries, DDL statements
- ` ```typescript ` or ` ```ts ` - TypeScript implementation
- ` ```javascript ` or ` ```js ` - JavaScript code
- ` ```prisma ` - ORM schema definitions
- ` ```graphql ` - GraphQL schema implementations
- Any language-specific code block that contains implementation details

**SQL/database keywords** (case-insensitive):
- `SELECT`, `INSERT`, `UPDATE`, `DELETE`, `CREATE TABLE`, `ALTER TABLE`
- `DROP`, `TRUNCATE`, `BEGIN`, `COMMIT`, `ROLLBACK`

**ORM/database operation patterns** (examples for Prisma — adapt to project ORM):
- `findMany`, `findUnique`, `create`, `update`, `upsert`, `delete`, `createMany`
- `@@index`, `@@unique`, `@@id`, `@relation`

**Database index specs**:
- `GIN`, `B-tree`, `BRIN`, `Hash`, `GiST`, `SP-GiST`
- `trigram`, `tsvector`, `gin_trgm_ops`

**File paths** (adapt `src/`, `apps/`, `packages/` to project structure):
- Source directory patterns: `.ts`, `.vue`, `.tsx`, `.jsx`, `.py`, `.rb`, etc.
- `import`, `export`, `from`, `require()`

### 3. Categorize Content

Group violations by type:
- **Code blocks**: Exact language and line numbers
- **SQL queries**: Count and line ranges
- **File paths**: List paths found
- **Index definitions**: Database index specifications
- **Service patterns**: Implementation code snippets

### 4. Present Findings

Show table with violations:

```
Violations Found in {feature}/spec.md
====================================

| Type | Lines | Count | Example |
|------|-------|-------|---------|
| SQL code blocks | 99-149, 224-272 | 4 | SELECT query with WHERE clause |
| TypeScript blocks | 125-143, 150-180 | 2 | Service function implementations |
| GraphQL schema | 224-272 | 1 | Full type definitions |
| Database indexes | 88-91 | 1 | @@index with GIN |
| File paths | Various | 5 | src/services/guide.ts |
```

### 5. Propose Changes

Explain what will be moved:
- All code blocks with language tags → tech-spec.md
- All SQL queries → tech-spec.md (in "Database Queries" section)
- All implementation patterns → tech-spec.md
- File paths that are implementation references → tech-spec.md

**Keep in spec.md**:
- High-level data model descriptions (conceptual, no code)
- Business requirements
- User stories
- Acceptance criteria
- Out of Scope
- Open Questions
- UI/UX wireframes (ASCII art)

### 6. Wait for Confirmation

Call `AskUserQuestion`:

```
question: "Move the identified technical content to tech-spec.md?"
header:   "Move content"
options:
  - "Move all"       → apply every proposed move
  - "Pick sections"  → choose which blocks to move individually
  - "Leave as-is"    → no changes to spec.md
```

### 7. Execute Changes

If approved:

**A. Create/Update tech-spec.md**

If tech-spec.md doesn't exist, create it with frontmatter:

```yaml
---
title: "{Feature Title} - Technical Specification"
status: draft
phase: 2
version: 1
spec_version: 1
created: {TODAY}
last_updated: {TODAY}
load_when: "Implementing {feature}"
see_also:
  - spec.md
  - dependencies.md
---
```

Add sections as needed:
- **Architecture Overview** (if applicable)
- **Data Model** (move database schemas, indexes)
- **Database Queries** (move SQL code blocks)
- **API Design** (move GraphQL schemas with full code)
- **Service Layer** (move TypeScript service patterns)
- **Implementation Steps** (if applicable)
- **File Inventory** (move file path references)

**B. Clean spec.md**

Remove all technical content. For sections that become empty, either:
- Remove the section entirely
- Replace with high-level business description

**C. Update spec_version**

Increment `spec_version` in spec.md frontmatter to indicate the change.

### 8. Verify Structure

Check that:
- spec.md contains only business/product content
- tech-spec.md contains all implementation details
- Both files have proper frontmatter
- `spec_version` incremented in spec.md
- If tech-spec.md exists, it has `spec_version` matching spec.md

## Detection Patterns Reference

Use these regex patterns for detection:

**Code fences**:
- ` ```(sql|typescript|ts|javascript|js|prisma|graphql) `

**SQL keywords** (word boundaries):
- `\b(SELECT|INSERT|UPDATE|DELETE|CREATE|ALTER|DROP|TRUNCATE)\b`

**ORM operations** (examples — adapt to project ORM/database layer):
- `\b(findMany|findUnique|findFirst|create|update|upsert|delete|createMany|updateMany|deleteMany)\b`

**Database indexes**:
- `@@index|@@unique|@@id`
- `\b(GIN|B-tree|BRIN|Hash|GiST|trigram|tsvector)\b`

**File paths**:
- `\b(src/|apps/|packages/)/[a-zA-Z0-9/_-]+\.(ts|tsx|js|jsx|vue)\b`

## Verification Checklist

After cleanup:

- [ ] Run project documentation audit command if configured
- [ ] spec.md contains only business content (no code blocks with language tags)
- [ ] tech-spec.md contains all moved technical content
- [ ] Both files have valid frontmatter
- [ ] `spec_version` incremented in spec.md
- [ ] No broken internal references between files
- [ ] All code examples properly formatted in tech-spec.md

## Notes

- GraphQL schemas are **always** moved to tech-spec.md (no borderline decisions)
- High-level data model descriptions (field names, types, relationships) can stay in spec.md if they're conceptual
- Database index specifications always move to tech-spec.md
- Service layer patterns and transaction handling always move to tech-spec.md
- Batch mode: One feature per invocation for careful review
