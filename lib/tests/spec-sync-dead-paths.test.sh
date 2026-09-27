#!/usr/bin/env bash
# Regression fixture for feature-spec-sync/dead-paths.mjs.
#
# Two things have to hold: every live-doc reference that no longer resolves is
# reported with doc:line (MISSING, or MOVED when the tree has one unique match),
# and nothing that is not a live repo path is reported — history, placeholders,
# URLs, globs, plans. A check that cries wolf gets ignored, so every exclusion
# below sits next to a positive control in the same doc.
#
# Usage: spec-sync-dead-paths.test.sh [path-to-script]

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${1:-$HERE/../feature-spec-sync/dead-paths.mjs}"
[ -f "$SCRIPT" ] || { echo "FATAL: script not found: $SCRIPT" >&2; exit 1; }

export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

ROOT=$(cd "$(mktemp -d)" && pwd -P)
REPO="$ROOT/proj"
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }
expect_line()    { if grep -Eq -- "$1" <<<"$OUTPUT"; then ok; else fail "$2 (no line matching: $1)"; fi; }
expect_no_line() { if grep -Eq -- "$1" <<<"$OUTPUT"; then fail "$2 (unexpected line matching: $1)"; else ok; fi; }
expect_exit()    { if [ "$STATUS" -eq "$1" ]; then ok; else fail "$2 (exit $STATUS, want $1)"; fi; }
run() { OUTPUT=$(cd "$REPO" && node "$SCRIPT" "$@" 2>&1); STATUS=$?; [ -z "${DEBUG:-}" ] || printf "%s\n" "$OUTPUT" >&2; }

build_fixture() {
  rm -rf "$REPO"
  mkdir -p "$REPO"/{app/services,app/components/Modal,server/routes,config,.ai/features/invites/plans,.ai/features/invites/sub,.ai/features/clean}
  cd "$REPO" || exit 1
  echo '{ "aiDir": ".ai" }' > .myspec.json
  echo 'x' > app/services/invite.ts
  echo 'x' > app/services/mailer.ts
  echo 'x' > app/components/Modal/index.vue
  echo 'x' > app/components/Card.vue
  echo 'x' > server/routes/invites.ts
  echo 'x' > server/routes/relocated-handler.ts
  echo 'x' > config/app.yml
  mkdir -p app/models app/Http internal/queue lib/models
  echo 'x' > app/models/user.py
  echo 'x' > app/Http/UserController.php
  echo 'x' > internal/queue/worker.go
  echo 'x' > lib/models/account.rb
  echo '# log' > .ai/features/invites/CHANGELOG.md

  cat > .ai/features/invites/spec.md <<'MD'
---
title: invites
source: app/frontmatter-only.ts
---
# Invites

Service lives in `app/services/invite.ts`, mailer in `app/services/mailer`.
Modal is `app/components/Modal`, card is `app/components/Card`, routes in `server/routes/`.
Config at `config/app.yml:12` and `./app/services/invite.ts`.
Gone: `app/services/legacy.ts` and `app/utils/format`.
Renamed on disk: `app/services/mailer.js` and `server/routes/relocated-handler.ts`.
Ambiguous: `app/old/index.ts`.
Non-JS modules: `app/models/user`, `app/Http/UserController`, `internal/queue/worker`; moved: `app/models/account`.

Not paths: `${aiDir}/features/x/spec.md`, `{feature}/spec.md`, `<repo_root>/app/x.ts`,
`https://example.com/app/x.ts`, `app/**/*.ts`, `/api/invites`, `@/components/Nope.vue`,
`application/json`, `feature/branch-name`, `npm run app/dead.ts`, `~~`app/struck.ts`~~`.
Arrow: `app/services/was-here.ts` → `app/services/invite.ts`.

```ts
import x from 'app/in-fence.ts'  // `app/in-fence-tick.ts`
```

## Rename history

| Old | New |
|-----|-----|
| `app/history-section.ts` | `app/services/invite.ts` |

## Components

| Before | After |
|--------|-------|
| `app/history-table.ts` | `app/services/invite.ts` |

| File | Purpose |
|------|---------|
| `app/services/table-dead.ts` | live table row |
MD

  cat > .ai/features/invites/tech-spec.md <<'MD'
---
title: invites tech
---
Uses `server/legacy/router` (deleted top-level-known dir) and `gone/thing` (unknown dir, no ext).
MD

  cat > .ai/features/invites/index.yaml <<'YAML'
sub-features:
  - name: sub
    entry: app/yaml-dead.ts   # comment app/yaml-comment.ts
    files: [app/services/invite.ts, "app/yaml-quoted-dead.vue"]
YAML

  cat > .ai/features/invites/sub/seed.json <<'JSON'
{ "fixture": "app/seed-dead.json", "ok": "config/app.yml", "mime": "application/json" }
JSON

  cat > .ai/features/invites/sub/scenarios.md <<'MD'
---
title: s
---
Given the file `app/scenario-dead.ts`
MD

  echo '`app/plan-dead.ts`' > .ai/features/invites/plans/2026-01-01-plan.md
  echo '`app/plan-dead.ts`' > .ai/features/invites/implementation-plan.md
  printf -- '---\ntitle: c\n---\nSee `app/services/invite.ts`.\n' > .ai/features/clean/spec.md

  mkdir -p app/old lib/handlers other/old
  echo 'x' > other/old/index.ts
  echo 'x' > lib/handlers/relocated-handler.ts
  rm server/routes/relocated-handler.ts
  rm -rf app/old
  mkdir -p app2/old && echo x > app2/old/index.ts
  git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm init
}

build_fixture

# ── positives ────────────────────────────────────────────────────────────────
run --only=invites
expect_exit 1 "dead paths exit 1"
S='\.ai/features/invites/spec\.md'
expect_line "^MISSING +$S:10  app/services/legacy\.ts$" "missing file with extension, doc:line"
expect_line "^MISSING +$S:10  app/utils/format$" "missing extension-less path under an existing top-level dir"
expect_line "^MOVED +$S:11  app/services/mailer\.js -> app/services/mailer\.ts$" "js -> ts swap in the same dir is MOVED"
expect_line "^MOVED +$S:11  server/routes/relocated-handler\.ts -> lib/handlers/relocated-handler\.ts$" "unique basename elsewhere in the tree is MOVED"
expect_line "^MISSING +$S:12  app/old/index\.ts +\([0-9]+ basename matches, ambiguous\)$" "two basename matches stay MISSING, flagged ambiguous"
expect_line "^MISSING +$S:[0-9]+  app/services/table-dead\.ts$" "a path in an ordinary table is checked"
expect_line "tech-spec\.md:4  server/legacy/router$" "extension-less path under an existing top-level dir"
expect_line "^MISSING +\.ai/features/invites/index\.yaml:3  app/yaml-dead\.ts$" "index.yaml bare scalar"
expect_line "index\.yaml:4  app/yaml-quoted-dead\.vue$" "index.yaml quoted list item"
expect_line "sub/seed\.json:1  app/seed-dead\.json$" "seed.json in a sub-feature dir"
expect_line "sub/scenarios\.md:4  app/scenario-dead\.ts$" "scenarios.md in a sub-feature dir"

expect_line "^MOVED +\.ai/features/invites/spec\.md:[0-9]+  app/models/account -> lib/models/account\.rb$" "extension-less path relocated to a non-JS module"

# ── resolving references are silent ──────────────────────────────────────────
for p in 'app/models/user$' 'app/Http/UserController$' 'internal/queue/worker$' 'app/services/invite\.ts' 'app/services/mailer$' 'app/components/Modal' 'app/components/Card' 'server/routes/$' 'config/app\.yml'; do
  expect_no_line "  $p" "resolving path is not reported: $p"
done

# ── exclusions ───────────────────────────────────────────────────────────────
for p in frontmatter-only in-fence struck was-here history-section history-table plan-dead yaml-comment ' app/dead\\.ts' Nope 'gone/thing' 'application/json' 'feature/branch' 'example\.com' '/api/'; do
  expect_no_line "$p" "excluded token is not reported: $p"
done

# ── --prefix covers a deleted top-level dir ─────────────────────────────────
run --only=invites --prefix=gone
expect_line "tech-spec\.md:4  gone/thing$" "--prefix makes an extension-less path under a missing top-level dir checkable"

# ── clean feature, json, errors ─────────────────────────────────────────────
run --only=clean
expect_exit 0 "a feature whose paths all resolve exits 0"
expect_line "No dead paths\." "clean run says so"

run --only=invites --json
expect_line '"status": "MOVED"' "--json emits findings"
expect_line '"to": "app/services/mailer.ts"' "--json carries the MOVED target"

run
expect_line "clean/spec\.md|invites/spec\.md" "no --only scans every feature"

run --only=nope
expect_exit 3 "unknown feature exits 3"

(cd "$REPO" && rm -rf .ai/features)
run
expect_exit 3 "missing features dir exits 3"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
