---
description: "Use when cleaning up spec.md files that contain implementation details. Identifies SQL, TypeScript, GraphQL code, database indexes, file paths. Moves technical content to tech-spec.md. Do NOT use for creating new specs."
---

# Spec Cleanup

Clean up spec.md files that violate the business-vs-technical documentation separation by moving implementation details to tech-spec.md.

## Path Resolution

1. Read `.myspec.json` from project root
2. Extract `aiDir` value (e.g., ".ai" or "ai")
3. All paths below use `${aiDir}` — resolve before use
4. If `.myspec.json` not found: STOP and tell user to run `/myspec:init`

## Instructions

### 1. Load Context

Read the target feature's documentation:
- Read `${aiDir}/features/{feature}/spec.md`
- Read `${aiDir}/features/{feature}/tech-spec.md` (if exists)
- Read `${aiDir}/workflow.md` for documentation rules

### 2. Detect Violations

Scan spec.md for technical implementation content:

**Code blocks** with language tags (common technical patterns):
- ` ```sql ` - SQL queries, DDL statements
- ` ```typescript ` or ` ```ts ` - TypeScript implementation
- ` ```javascript ` or ` ```js ` - JavaScript code
- ` ```python ` or ` ```py ` - Python implementation
- ` ```go ` - Go implementation
- ` ```rust ` - Rust implementation
- ` ```java ` - Java implementation
- ` ```graphql ` - GraphQL schema implementations
- ` ```prisma ` - ORM schema definitions
- ` ```proto ` - Protocol buffer definitions

**SQL keywords** (case-insensitive):
- `SELECT`, `INSERT`, `UPDATE`, `DELETE`, `CREATE TABLE`, `ALTER TABLE`
- `DROP`, `TRUNCATE`, `BEGIN`, `COMMIT`, `ROLLBACK`

**ORM/query builder patterns**:
- Common ORM operations: `findMany`, `findOne`, `findUnique`, `create`, `update`, `upsert`, `delete`
- Schema decorators: `@@index`, `@@unique`, `@@id`, `@relation`, `@Column`, `@Entity`

**Database index specs**:
- `GIN`, `B-tree`, `BRIN`, `Hash`, `GiST`, `SP-GiST`
- `trigram`, `tsvector`, `gin_trgm_ops`

**File paths** (implementation references):
- `src/`, `lib/`, `internal/`, `cmd/`, `pkg/`
- Common source file extensions: `.ts`, `.js`, `.py`, `.go`, `.rs`, `.java`, `.vue`, `.tsx`, `.jsx`
- `import`, `export`, `from`, `require()`, `include`

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
| Code blocks | 125-143, 150-180 | 2 | Service function implementations |
| API schema | 224-272 | 1 | Full type definitions |
| Database indexes | 88-91 | 1 | Index with GIN |
| File paths | Various | 5 | src/services/example.ts |
```

### 5. Propose Changes

Explain what will be moved:
- All code blocks with language tags -> tech-spec.md
- All SQL queries -> tech-spec.md (in "Database Queries" section)
- All implementation patterns -> tech-spec.md
- File paths that are implementation references -> tech-spec.md

**Keep in spec.md**:
- High-level data model descriptions (conceptual, no code)
- Business requirements
- User stories
- Acceptance criteria
- Out of Scope
- Open Questions
- UI/UX wireframes (ASCII art)

### 6. Wait for Confirmation

Ask: "Should I move this technical content to tech-spec.md?"

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
- **API Design** (move API schemas with full code)
- **Service Layer** (move service implementation patterns)
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
- ` ```(sql|typescript|ts|javascript|js|python|py|go|rust|java|graphql|prisma|proto) `

**SQL keywords** (word boundaries):
- `\b(SELECT|INSERT|UPDATE|DELETE|CREATE|ALTER|DROP|TRUNCATE)\b`

**ORM operations**:
- `\b(findMany|findUnique|findFirst|findOne|create|update|upsert|delete|createMany|updateMany|deleteMany)\b`

**Database indexes**:
- `@@index|@@unique|@@id`
- `\b(GIN|B-tree|BRIN|Hash|GiST|trigram|tsvector)\b`

**File paths**:
- `\b(src|lib|internal|cmd|pkg)/[a-zA-Z0-9/_-]+\.(ts|tsx|js|jsx|py|go|rs|java|vue)\b`

## Verification Checklist

After cleanup:

- [ ] spec.md contains only business content (no code blocks with language tags)
- [ ] tech-spec.md contains all moved technical content
- [ ] Both files have valid frontmatter
- [ ] `spec_version` incremented in spec.md
- [ ] No broken internal references between files
- [ ] All code examples properly formatted in tech-spec.md

## Notes

- API schemas are **always** moved to tech-spec.md (no borderline decisions)
- High-level data model descriptions (field names, types, relationships) can stay in spec.md if they're conceptual
- Database index specifications always move to tech-spec.md
- Service layer patterns and transaction handling always move to tech-spec.md
- Batch mode: One feature per invocation for careful review
