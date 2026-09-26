# Scratch isolation

Any probe that writes — a clickable demo, a real-engine run over a real corpus, a data probe — runs against scratch infrastructure, never the project's real database, bucket, or queue. Isolation fails quietly: a service falls back to its default when a variable is unset, or hardcodes the part of a connection string you changed. In one run (issue #92) a queue that hardcoded its Redis DB index kept feeding the real worker although `REDIS_URL` pointed at `/3`, and an unset `AWS_S3_BUCKET` fell back to the real bucket, where a demo overwrote 91 objects in an unversioned bucket.

`feature-implement`'s probe executor and phase reviewer cite this file. The tech-spec's `### Test Hooks` → *Scratch environment* line names the project's concrete values; this checklist says what those values must cover.

## Before the run

| # | Check | Why a partial version fails |
|---|-------|-----------------------------|
| 1 | **Separate database** — a different database name or instance, not a schema prefix on the real one. Print the resolved connection target before writing. | Migrations and seeds run against whatever the default URL resolves to. |
| 2 | **Separate storage bucket** — set *every* bucket-related variable explicitly (bucket name, endpoint, region, any per-feature bucket variables). List them from the code's config loader, not from memory. | An unset variable falls back to the real bucket's default. |
| 3 | **Separate queue port** — a separate queue/broker instance on its own port, not only a different DB index or key prefix on the real one. | Queue libraries often hardcode or override the DB index, so the real workers consume scratch jobs, or scratch workers consume real ones. |
| 4 | **Record a "before" fingerprint** of the real database, bucket, and queue: row count or max `updated_at` of a table the probe would write to, newest object `LastModified` in the real bucket, and queue length or last job id. Read-only commands only. | Without a baseline, check 5 cannot prove anything. |

If any check cannot be completed — a credential is missing, a variable's real default is unknown — the probe is **BLOCKED**. Say which check failed; never run the probe on partial isolation.

## After the run

| # | Check |
|---|-------|
| 5 | **Real systems untouched** — re-read the fingerprints from check 4 and compare. Any change the project's own traffic does not explain is a **FAIL** of the whole probe run, reported to the user before anything else. |
| 6 | **Scratch torn down or named** — stop scratch services, or report what is still running and where. |

Report checks 1–6 in the probe report, each with the command run and its literal output. A check reported without its output did not happen.
