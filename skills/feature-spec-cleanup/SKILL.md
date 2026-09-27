---
name: "feature-spec-cleanup"
description: "Use when a spec.md has leaked implementation detail — SQL, code blocks, ORM patterns, indexes, file paths — that belongs in tech-spec.md. Keywords: spec cleanup, move code out of spec, spec hygiene. Do NOT use to create specs."
tags: [documentation, cleanup, maintenance, spec]
---

# Spec Cleanup

Clean up spec.md files that violate the business-vs-technical documentation separation by moving implementation details to tech-spec.md.

## Workflow

### 1. Load Context

Read the target feature's documentation:
- Read `${aiDir}/features/{feature}/spec.md`
- Read `${aiDir}/features/{feature}/tech-spec.md` (if exists)
- Read `.claude/rules/workflow.md` for documentation rules (if it exists)

### 2. Detect Violations

Scan spec.md for technical implementation content:

**Code blocks** with a language tag naming a programming, query, or schema language — any stack (`sql`, `ts`, `php`, `python`, `go`, `ruby`, `java`, `prisma`, `graphql`, `proto`, …). Prose and diagram tags (`mermaid`, `text`, `md`, `markdown`, `plaintext`) are not violations.

**SQL/database keywords** (case-insensitive):
- `SELECT`, `INSERT`, `UPDATE`, `DELETE`, `CREATE TABLE`, `ALTER TABLE`
- `DROP`, `TRUNCATE`, `BEGIN`, `COMMIT`, `ROLLBACK`

**ORM/database operation patterns** — take the ORM from `backbone.yml` `database:` or `${aiDir}/conventions/` and match its query and schema vocabulary. Common ones:
- Query builders / active record: `findMany`, `findUnique`, `upsert`, `createMany` (Prisma); `where(`, `find_by`, `has_many` (ActiveRecord); `objects.filter`, `ForeignKey` (Django); `session.query`, `relationship(` (SQLAlchemy); `createQueryBuilder`, `getRepository` (Doctrine, TypeORM); `Eloquent`, `hasMany` (Laravel); `db.Where`, `gorm:` tags (GORM)
- Schema annotations: `@@index`, `@relation` (Prisma); `#[ORM\Column]`, `@Entity`, `@Column`, `@Table` (Doctrine, JPA, TypeORM); `db_index=True` (Django)

**Database index specs**:
- `GIN`, `B-tree`, `BRIN`, `Hash`, `GiST`, `SP-GiST`
- `trigram`, `tsvector`, `gin_trgm_ops`

**File paths** — any repo-relative path with a source extension, whatever the layout (`src/`, `app/`, `lib/`, `internal/`, `apps/`…):
- Source extensions: `.ts`, `.vue`, `.php`, `.py`, `.rb`, `.go`, `.java`, `.cs`, etc.
- Import statements: `import`, `export`, `from`, `require()`, `use`, `include`

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

If tech-spec.md doesn't exist, create it with the canonical frontmatter (same schema as `/myspec:feature-tech-spec`):

```yaml
---
title: "{Feature Title} -- Technical Specification"
status: draft
based_on_spec_version: {spec_version from spec.md, after Step 7C's increment}
created: {TODAY}
last_updated: {TODAY}
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

Increment `spec_version` in spec.md frontmatter to indicate the change. Then set tech-spec.md's `based_on_spec_version` to the new value and update its `last_updated` — content was only relocated, not changed, so the tech-spec still reflects the spec. Skipping this manufactures the version-mismatch condition that feature-verify flags as Critical.

### 8. Verify Structure

Check that:
- spec.md contains only business/product content
- tech-spec.md contains all implementation details
- Both files have proper frontmatter
- `spec_version` incremented in spec.md
- tech-spec.md's `based_on_spec_version` equals spec.md's `spec_version`

## Detection Patterns Reference

Use these regex patterns for detection:

**Code fences**:
- ` ```([A-Za-z0-9_+#-]+) ` whose tag is not a prose or diagram tag (`mermaid`, `text`, `txt`, `md`, `markdown`, `plaintext`)

**SQL keywords** (word boundaries):
- `\b(SELECT|INSERT|UPDATE|DELETE|CREATE|ALTER|DROP|TRUNCATE)\b`

**ORM operations** — the project ORM's vocabulary (see the list in step 2), e.g.:
- `\b(findMany|findUnique|upsert|createMany|find_by|has_many|belongs_to|objects\.filter|session\.query|createQueryBuilder|getRepository|hasMany|belongsTo)\b`

**Database indexes**:
- `@@index|@@unique|@@id|#\[ORM\\|@(Entity|Table|Column|Index)\b|db_index=True|add_index`
- `\b(GIN|B-tree|BRIN|Hash|GiST|trigram|tsvector)\b`

**File paths**:
- `\b[a-zA-Z0-9_.-]+(/[a-zA-Z0-9_.-]+)+\.[a-z0-9]{1,5}\b` (a repo-relative path with an extension; skip URLs)

## Verification Checklist

After cleanup:

- [ ] Run project documentation audit command if configured
- [ ] spec.md contains only business content (no code blocks with language tags)
- [ ] tech-spec.md contains all moved technical content
- [ ] Both files have valid frontmatter
- [ ] `spec_version` incremented in spec.md; tech-spec.md `based_on_spec_version` matches it
- [ ] No broken internal references between files
- [ ] All code examples properly formatted in tech-spec.md

## Rules

- GraphQL schemas are **always** moved to tech-spec.md (no borderline decisions)
- High-level data model descriptions (field names, types, relationships) can stay in spec.md if they're conceptual
- Database index specifications always move to tech-spec.md
- Service layer patterns and transaction handling always move to tech-spec.md
- Batch mode: One feature per invocation for careful review
