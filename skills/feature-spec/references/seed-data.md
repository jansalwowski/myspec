# Test Seed Data (`seed.json`)

Test data matching the feature's data model and scenarios. Needs `spec.md` (with the data model) and `scenarios.md`. Not for production data.

## Procedure

1. Read `${aiDir}/features/{feature}/spec.md`: every entity, its field types, constraints and relationships.
2. Read `${aiDir}/features/{feature}/scenarios.md`: the data each scenario needs, including edge-case data.
3. Create `${aiDir}/features/{feature}/seed.json`:

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

4. Cover every scenario:
   - **Happy path**: typical valid records, various valid states, related entity chains
   - **Edge cases**: empty/null values, maximum-length strings, maximum/minimum numbers, unicode, special characters
   - **Error cases**: invalid references, deleted parent records, orphaned records
5. Keep referential integrity across related entities:

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

6. Document each record's purpose with `_scenario` or `_comment`:

```json
{
  "id": "user-banned-1",
  "email": "banned@test.com",
  "bannedAt": "2024-01-01T00:00:00Z",
  "_scenario": "error-state-banned-user",
  "_comment": "User banned for testing access denial"
}
```

## Value conventions

| Kind | Rule |
|------|------|
| IDs | Consistent, memorable: `guide-1`, `guide-2`; `test-uuid-{purpose}` for specific scenarios |
| Dates | Fixed baseline `2024-01-01T00:00:00Z`; reference NOW for relative scenarios |
| Strings | Realistic but clearly test data ("Test Guide"); include unicode ("Test 🌍 Guide") and special characters ("Guide with 'quotes' & <tags>") |
| Numbers | Zero, one, typical and maximum values; negative where allowed |

## Checklist

- [ ] All entities from the data model have seed data
- [ ] Happy path, edge case and error scenarios all have data
- [ ] Relationships are valid
- [ ] JSON is valid syntax
- [ ] Each record has `_scenario` or `_comment`
- [ ] IDs are unique
- [ ] Required fields are present
