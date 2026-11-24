# `/myspec:research` — examples

Sourced research in five steps: size the task, write a brief, split it into sub-questions for parallel search agents, check the key claims with a verifier that never sees the draft, and write the answer in one pass. The evidence behind each rule is in `skills/research/references/evidence.md`.

**Contents**

- [Library behaviour question answered from the pinned version](#library-behaviour-question-answered-from-the-pinned-version) — the version comes from the lockfile, the user's guess is tested instead of adopted, and patch-level bugs show up that a quick answer misses

---

## Library behaviour question answered from the pinned version

### Setup

A PHP service uses the Symfony Messenger Doctrine transport on MySQL 8. Since the team scaled the workers to 4 pods, some messages are handled twice. The user suspects the redelivery timeout.

### Invocation

```
/myspec:research We sometimes process the same Messenger message twice since we scaled our workers to 4 pods. I think it's the redelivery timeout. Why does it happen and what's the proper fix?
```

### Skill flow

#### 0. Size

A "why does X happen" question: 3 search agents and 1 verifier.

#### 1. Brief

The agent reads `composer.lock` and finds `symfony/messenger` and `symfony/doctrine-messenger` at 6.4.20. It writes the brief to a notes file and shows it in a few lines:

> Question: why does the 6.4 Doctrine transport handle a message twice with 4 workers, and what is the fix?
> Decision: what to change (config, handler code, upgrade).
> Done when: the mechanism is confirmed in the 6.4 source, other causes are listed with evidence, and the fixes are ranked.
> Guess to test: the redelivery timeout.

The guess stays in the brief. The search agents get a neutral question instead: "which conditions make the transport deliver a row again?"

#### 2-3. Plan and search

Three search agents run in parallel: the redelivery mechanics, the fixes and upgrade options, and other causes of duplicates (the agent that looks for the opposite). Each gets the source order for code questions: the installed source, the docs for 6.4, the changelog, the library source at the 6.4 tags, then issues and PRs.

The controller reads `Connection.php` at the 6.4 tag itself. A worker claims a row with `SELECT … FOR UPDATE` and the ack is a `DELETE`. So two pods cannot take the same new row. A row comes back only when it is still in the table after `redeliver_timeout`.

#### 4. Verify

The verifier gets 7 claims as neutral statements with their URLs. It gets no draft and no mention of the user's guess. All 7 come back SUPPORTED, each with a quote.

#### 5. Report

> **Answer:** The timeout is only part of it. A message runs twice when its row is still in the table after `redeliver_timeout`. That happens when a handler runs longer than the timeout, or when the ack is lost: a pod killed mid-handler, a dropped connection, or, before 6.4.49, a single deadlock on the `DELETE`, because the ack retry never ran. More pods mean more deadlocks, which fits "since we scaled".
>
> **Fix, in order:** upgrade from 6.4.20 to the latest 6.4 patch; set `redeliver_timeout` above the longest handler; set the pod grace period above the longest handler; make handlers idempotent with a business key and a unique constraint.
>
> **Evidence:** each claim with its link (source at the 6.4 tag, the 6.4 docs, the fixing PRs) and a confidence label.
>
> **Dropped:** clock skew between pods (it would need a skew larger than the timeout); `DeduplicateStamp` (7.3 and later, and it stops duplicate dispatch, not redelivery).
>
> **Open:** the longest handler duration and the pod kill history decide which cause applies.

A quick answer without the skill confirmed the timeout guess and missed the patch-level ack bug. Here the bug decides the first fix.
