import { resolve } from 'path'

import vue from '@vitejs/plugin-vue'
import { defineConfig } from 'vite'

const APP_DIR = import.meta.dirname

// ── EDIT ME (repo layout) ────────────────────────────────────────────────────
// The template assumes this app lives one level below the repo root (e.g.
// <repo>/mockup-preview/) and that myspec's aiDir is `.ai`. Adjust both
// constants if your layout differs, and keep them in sync with the other edit
// points listed in README.md.
const REPO_ROOT = resolve(APP_DIR, '..')
const FEATURES_DIR = resolve(REPO_ROOT, '.ai/features')
// ─────────────────────────────────────────────────────────────────────────────

export default defineConfig({
  plugins: [vue()],
  resolve: {
    alias: {
      '@': resolve(APP_DIR, 'src'),
      // Cross-mockup imports: any mockup may import shared scaffolding from a
      // sibling feature (e.g. `import Navbar from '@mockups/navbar/mockups/_Navbar.vue'`).
      // Files whose mockup-relative path starts with `_` are excluded from
      // sidenav discovery — see src/lib/discovery.ts.
      '@mockups': FEATURES_DIR,
      // Mockup files live under the features dir, outside this app.
      // Resolve their bare imports against this app's node_modules.
      'lucide-vue-next': resolve(APP_DIR, 'node_modules/lucide-vue-next'),
      'vue': resolve(APP_DIR, 'node_modules/vue'),
      // ── Design-system slot ─────────────────────────────────────────────────
      // Wire your component library here so mockups can import it, e.g.:
      // '@acme/uikit': resolve(REPO_ROOT, 'packages/uikit/src/index.ts'),
      // ───────────────────────────────────────────────────────────────────────
    },
  },
  server: {
    fs: {
      allow: [REPO_ROOT],
    },
  },
})
