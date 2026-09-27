# Scratch isolation

Any probe that writes — a clickable demo, a real-engine run over a real corpus, a data probe — runs against scratch infrastructure, never the project's real database, bucket, or queue. Isolation fails quietly: a service falls back to its default when a variable is unset, or hardcodes the part of a connection string you changed. In one run (issue #92) a queue client that hardcoded its broker's DB index kept feeding the real worker although the queue URL pointed at another index, and an unset bucket variable fell back to the real bucket, where a demo overwrote 91 objects in an unversioned bucket.

`feature-implement`'s probe executor and phase reviewer cite this file. The tech-spec's `### Test Hooks` → *Scratch environment* line names the project's concrete values; this checklist says what those values must cover.

## Before the run

| # | Check | Why a partial version fails |
|---|-------|-----------------------------|
| 1 | **Separate database** — a different database name or instance, not a schema prefix on the real one. Print the resolved connection target before writing. | Migrations and seeds run against whatever the default URL resolves to. |
| 2 | **Separate storage bucket** — set *every* bucket-related variable explicitly (bucket name, endpoint, region, any per-feature bucket variables). List them from the code's config loader, not from memory. | An unset variable falls back to the real bucket's default. |
| 3 | **Separate queue** — real workers cannot reach scratch jobs, and scratch workers cannot reach real ones. A networked broker needs its own instance, not only a different DB index or key prefix on the real one; a queue stored in the database is covered by check 1; a hosted queue needs its own queue or topic name. | Queue libraries often hardcode or override the DB index, so the real workers consume scratch jobs, or scratch workers consume real ones. |
| 4 | **Record a "before" fingerprint** of the real database, bucket, and queue, scoped to what the probes write: the count of rows matching the probe's fixture values in each table it writes to, the objects under the key prefix it writes, and the jobs of the type it enqueues. Read-only commands only. | Without a baseline, check 5 cannot prove anything. A whole-table timestamp or queue length moves with background traffic and proves nothing either way. |

A check whose system the project does not have — no object storage, no queue — is **not applicable**: report it as such, with the config file or loader that shows the system is absent. If any other check cannot be completed — a credential is missing, a variable's real default is unknown — the probe is **BLOCKED**. Say which check failed; never run the probe on partial isolation.

## After the run

| # | Check |
|---|-------|
| 5 | **Real systems untouched** — re-read the fingerprints from check 4 and compare. Any change is a **FAIL** of the whole probe run, reported to the user before anything else. |
| 6 | **Scratch torn down or named** — stop scratch services, or report what is still running and where. |

Report checks 1–6 in the probe report, each with the command run and its literal output. A check reported without its output did not happen.
