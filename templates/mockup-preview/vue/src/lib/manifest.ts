import { buildNavTree, type NavTree } from './discovery'

// ── EDIT ME (repo layout) ────────────────────────────────────────────────────
// Vite requires static glob literals. These assume the app lives at
// <repo>/mockup-preview/ with aiDir `.ai` — keep all three patterns in sync
// with src/config.ts FEATURES_ROOT_MARKER and the edit points in README.md.
// ─────────────────────────────────────────────────────────────────────────────

const rawSources = import.meta.glob('../../../.ai/features/**/mockups/*.vue', {
  query: '?raw',
  import: 'default',
  eager: true,
})

const loaders = import.meta.glob('../../../.ai/features/**/mockups/*.vue', {
  eager: false,
})

const readmes = import.meta.glob('../../../.ai/features/**/mockups/README.md', {
  query: '?raw',
  import: 'default',
  eager: true,
})

export const navTree: NavTree = buildNavTree(
  rawSources as Record<string, string>,
  loaders,
  readmes as Record<string, string>,
)

export function collectMissingFrontmatter(tree: NavTree): string[] {
  const missing: string[] = []
  for (const node of tree) {
    for (const entry of node.mockups) {
      const title = entry.frontmatter.title
      const description = entry.frontmatter.description
      const titleMissing = title === undefined || title.length === 0
      const descMissing = description === undefined || description.length === 0
      if (titleMissing || descMissing) {
        missing.push(entry.sourcePath)
      }
    }
  }
  return missing
}

const missingFrontmatter = collectMissingFrontmatter(navTree)
for (const sourcePath of missingFrontmatter) {
  console.warn(`[mockups] missing frontmatter: ${sourcePath}`)
}
