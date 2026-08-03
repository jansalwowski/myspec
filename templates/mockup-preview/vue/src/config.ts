// ── EDIT ME (repo layout) ────────────────────────────────────────────────────
// Path marker used to extract feature ids from discovered file paths. Must
// match your myspec aiDir ('.ai' by default; some projects use 'ai').
//
// import.meta.glob patterns cannot be built from this constant (Vite requires
// static literals) — if you change it, also update the globs in
// src/lib/manifest.ts and the other edit points listed in README.md.
// ─────────────────────────────────────────────────────────────────────────────
export const FEATURES_ROOT_MARKER = '.ai/features/'
