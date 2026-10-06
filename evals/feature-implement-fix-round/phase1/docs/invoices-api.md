# Invoice API

`GET /invoices/<number>` returns one invoice.

| Field | Meaning |
|-------|---------|
| `due_date` | Issue date plus the customer's payment terms (14 days when none), ISO 8601 |
| `overdue` | `true` for an issued invoice from its due date onwards; a paid invoice is never overdue |
