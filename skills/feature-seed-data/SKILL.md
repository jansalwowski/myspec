---
name: "feature-seed-data"
description: "Use to create test seed data for a feature. Generates seed.json matching the data models and scenarios. Requires scenarios.md. Do NOT use for production data."
tags: [testing, seed, json, data]
---

# Generate Seed Data

Create test seed data files for a feature.

## Prerequisites

- `${aiDir}/features/{feature}/spec.md` exists with data model
- `${aiDir}/features/{feature}/scenarios.md` exists with test cases

## Workflow

### Step 1: Analyze Data Model

1. Read `${aiDir}/features/{feature}/spec.md`
2. Extract all entity definitions
3. Note field types and constraints
4. Identify relationships

### Step 2: Review Scenarios

1. Read `${aiDir}/features/{feature}/scenarios.md`
2. List data needed for each scenario
3. Identify edge case data requirements

### Step 3: Create seed.json

Create `${aiDir}/features/{feature}/seed.json`:

```json
{
  "_meta": {
    "feature": "{feature-name}",
    "version": 1,
    "created": "YYYY-MM-DD"
  },
  "entityName": [
    {
      "id": "uuid-1",
      "field1": "value1",
      "field2": 123,
      "_scenario": "happy-path-basic"
    },
    {
      "id": "uuid-2",
      "field1": "",
      "field2": 0,
      "_scenario": "edge-case-empty-values"
    },
    {
      "id": "uuid-3",
      "field1": "very long value that tests max length...",
      "field2": 999999,
      "_scenario": "edge-case-max-values"
    }
  ]
}
```

### Step 4: Cover All Scenarios

Create seed data for:

**Happy Path Data**
- Typical valid records
- Various valid states
- Related entity chains

**Edge Case Data**
- Empty/null values
- Maximum length strings
- Maximum/minimum numbers
- Unicode characters
- Special characters

**Error Case Data**
- Invalid references
- Deleted parent records
- Orphaned records

### Step 5: Add Relationships

For related entities, ensure referential integrity:

```json
{
  "guides": [
    { "id": "guide-1", "title": "Test Guide" }
  ],
  "sections": [
    { "id": "section-1", "guideId": "guide-1", "title": "Test Section" }
  ],
  "items": [
    { "id": "item-1", "sectionId": "section-1", "title": "Test Item" }
  ]
}
```

### Step 6: Document Purpose

Add `_scenario` or `_comment` fields to explain each record's purpose:

```json
{
  "id": "user-banned-1",
  "email": "banned@test.com",
  "bannedAt": "2024-01-01T00:00:00Z",
  "_scenario": "error-state-banned-user",
  "_comment": "User banned for testing access denial"
}
```

## Data Generation Guidelines

### UUIDs
Use consistent, memorable IDs:
- `guide-1`, `guide-2` for simple references
- `test-uuid-{purpose}` for specific scenarios

### Dates
Use relative or fixed test dates:
- `2024-01-01T00:00:00Z` - baseline date
- Reference NOW for relative scenarios

### Strings
- Use realistic but clearly test data: "Test Guide", "Sample Section"
- Include emoji/unicode: "Test 🌍 Guide"
- Include special chars: "Guide with 'quotes' & <tags>"

### Numbers
- Include zero, one, typical, and maximum values
- Include negative where allowed

## Verification Checklist

- [ ] All entities from data model have seed data
- [ ] Happy path scenarios have data
- [ ] Edge cases have data
- [ ] Error scenarios have data
- [ ] Relationships are valid
- [ ] JSON is valid syntax
- [ ] Each record has `_scenario` or `_comment`
- [ ] UUIDs are unique
- [ ] Required fields are present
