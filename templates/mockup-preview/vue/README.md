# Mockup Preview (Vue)

A standalone Vite + Vue 3 preview app for feature-level UX mockups, built for the
`/myspec:feature-mockup` and `/myspec:feature-mockup-review` skills. Mockups are
colocated with feature specs under `{aiDir}/features/{feature}/mockups/` and are
auto-discovered — no registration required.

Installed by `/myspec:setup mockup` (or copy this directory manually).

## Install

1. Copy this directory into the consuming repo — the default assumption is
   `<repo_root>/mockup-preview/` with myspec's `aiDir` set to `.ai`.
2. If your layout differs, update every **edit point** (all marked `EDIT ME`):

   | File | What to adjust |
   |---|---|
   | `src/lib/manifest.ts` | the three `import.meta.glob` literals |
   | `src/config.ts` | `FEATURES_ROOT_MARKER` |
   | `vite.config.ts` | `REPO_ROOT` / `FEATURES_DIR` |
   | `tsconfig.json` | `@mockups/*` path + the mockups `include` entry |
   | `tailwind.config.ts` | the mockups `content` glob |
   | `scripts/audit.ts` | `ROOT` / `FEATURES_DIR` (+ design-system constants) |

3. Install dependencies: `npm install` (or pnpm/yarn/bun).
4. Record the commands in `.myspec.json` so the skills can run them:

```json
{
  "mockups": {
    "extension": ".vue",
    "commands": {
      "verify": "npm --prefix mockup-preview run typecheck",
      "preview": "npm --prefix mockup-preview run dev",
      "compileCheck": "curl -s \"http://localhost:{port}/@fs{absPath}\" -o /dev/null -w \"%{http_code}\"",
      "audit": "npm --prefix mockup-preview run audit"
    }
  }
}
```

`verify` typechecks the app **and every mockup file** (the mockups tree is in
`tsconfig.json` include). `compileCheck` asks the running dev server to
transform one file — 200 means it compiles; on failure the dev-server log names
the error.

## Running

```sh
npm run dev        # boot the preview
npm run typecheck  # vue-tsc over the app + all mockups
npm run audit      # list cross-feature promotion candidates (writes audit.json)
```

The shell uses **drill-down navigation**: at `/` every feature appears as
tiles (with `/`-triggered search); click a feature and the sidenav shows only
that feature's mockups plus an "All features" back-link. The frame toolbar
offers mobile / tablet / desktop / full viewports (constrained widths render in
an iframe so media queries fire) and light/dark theme.

## How to add a mockup

1. Drop a Vue SFC at `{aiDir}/features/{feature}/mockups/YourMockup.vue`
2. Start it with the HTML-comment frontmatter block:

   ```vue
   <!--
   title: Your Mockup Title
   description: One sentence describing the mockup
   -->
   ```

3. Import only from the allowed list in `{aiDir}/conventions/mockup-design.md`
4. Refresh the browser — the mockup appears immediately, no restart needed

Missing `title`/`description` logs a console warning; if `title` is absent the
filename is used as the display name.

## Sharing components across mockups

Shared scaffolding lives in `_`-prefixed files (`_Navbar.vue`, or grouped under
`_components/`) — any path segment under `mockups/` starting with `_` is
excluded from discovery but importable from any mockup via the `@mockups`
alias:

```ts
import Navbar from '@mockups/navbar/mockups/_Navbar.vue'
```

Run `npm run audit` before re-rolling chrome — it lists every cross-feature
self-rolled component (≥2 features or ≥3 files) and where the canonical
implementation lives.

## Wiring your design system

Out of the box, mockups get a neutral semantic-token baseline (`bg-surface`,
`bg-surface-inset`, `text-text-primary`, `text-text-secondary`,
`text-text-muted`, `border-border`) defined in `src/styles/main.css`. To swap
in your component library:

1. **vite.config.ts** — add the library alias in the design-system slot so
   mockups can import it.
2. **tsconfig.json** — add the matching `paths` entry for its types.
3. **src/main.ts** — import the library's stylesheet in the design-system slot.
4. **tailwind.config.ts** — replace the token theme with your library's preset,
   or add its source to `content` (skip entirely if the library doesn't use
   Tailwind).
5. **scripts/audit.ts** — set `LIBRARY_MODULES` (and `LIBRARY_EXPORT_INDEX` if
   available) so shipped components aren't flagged as promotion candidates.
6. Record the library in the *Allowed imports* and *Component library* sections
   of `{aiDir}/conventions/mockup-design.md`.

## Boundaries

Mockups must never be reachable from production builds — the glob discovery is
local to this app. Keep production forbidden imports (API client, state store,
router, ORM) out of mockups; the review skill checks this against
`{aiDir}/conventions/mockup-design.md`.
