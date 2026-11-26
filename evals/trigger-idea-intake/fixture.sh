#!/usr/bin/env bash
# Billing app with one idea already in PRIORITY-LISTING.md and a new idea file,
# recurring-invoices.md, that is not listed yet.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../_fixtures/lib.sh"
myspec_init
copy_tree project-billing
cat > .ai/ideas/bulk-reminder-emails.md <<'MD'
# Bulk reminder emails

Let account owners send a payment reminder to every customer with an overdue invoice in one click.
MD
perl -0pi -e 's/(## Medium Priority\n\n\| Status \| Idea \| File \| Dependencies \| Notes \|\n\|[-|]+\|\n)/$1| `[ ]` | Bulk reminder emails | bulk-reminder-emails.md | payment-reminders | asked for by 2 customers |\n/' .ai/ideas/PRIORITY-LISTING.md
perl -pi -e 's/^\| 0(      \| 0 )/| 1$1/' .ai/ideas/PRIORITY-LISTING.md
grep -q 'bulk-reminder-emails.md' .ai/ideas/PRIORITY-LISTING.md
cat > .ai/ideas/recurring-invoices.md <<'MD'
# Recurring invoices

Some customers bill the same amount every month (retainers, subscriptions).
They want to set up an invoice once and have the app issue it on a schedule,
for example on the 1st of each month, and email it to the client.

Notes:
- 5 of our 12 largest accounts asked for this in the last quarter.
- It needs the CSV export to include generated invoices like any other.
MD
git_commit_all "chore: billing app with a new idea file"
