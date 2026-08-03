#!/usr/bin/env tsx
/**
 * mockup audit — surface duplicated self-rolled components across mockups so
 * they can be graduated to the design system (or to a feature's
 * `mockups/_components/` if not yet stable enough to ship).
 *
 * Strategy:
 *  1. Read every `{aiDir}/features/{feature}/mockups/**\/*.vue` (including
 *     `_`-prefixed shared scaffolding so the audit can flag *where* the
 *     canonical implementation is — and which features still re-roll it).
 *  2. For each file, parse `<script>` imports to classify each PascalCase
 *     symbol's source: `library | icons | shared | self`.
 *  3. Only `self`-classified usages (no import OR relative/@mockups import)
 *     are candidates. Already-shipped library components and icons are
 *     excluded.
 *  4. A component is a promotion candidate iff used across ≥2 features OR
 *     ≥3 distinct files.
 *
 * Output:
 *  - stdout: ranked human-readable list
 *  - audit.json (next to this app): machine-readable for tooling
 */

import { readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs'
import { dirname, join, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))

// ── EDIT ME (repo layout + design system) ────────────────────────────────────
// ROOT / FEATURES_DIR: keep in sync with the other edit points in README.md.
// LIBRARY_MODULES: module specifiers of your component library — imports from
//   these are "already canonical" and never flagged (e.g. ['@acme/uikit']).
// LIBRARY_EXPORT_INDEX: absolute path to your library's export index so
//   shipped component names are excluded even when used without an import
//   (auto-registered globals). null → no library configured.
const ROOT = resolve(__dirname, '../..')
const FEATURES_DIR = resolve(ROOT, '.ai/features')
const LIBRARY_MODULES: string[] = []
const LIBRARY_EXPORT_INDEX: string | null = null
// ─────────────────────────────────────────────────────────────────────────────

const OUTPUT_JSON = resolve(__dirname, '../audit.json')

type ImportSource = 'library' | 'icons' | 'shared' | 'self'

interface Usage {
  feature: string
  file: string
  count: number
  source: ImportSource
}

interface Candidate {
  component: string
  totalUsages: number
  features: string[]
  files: string[]
  sharedSources: string[]
  usages: Usage[]
}

function walkVueFiles(dir: string, acc: string[] = []): string[] {
  let entries: string[]
  try {
    entries = readdirSync(dir)
  } catch {
    return acc
  }
  for (const entry of entries) {
    const full = join(dir, entry)
    let st
    try {
      st = statSync(full)
    } catch {
      continue
    }
    if (st.isDirectory()) {
      walkVueFiles(full, acc)
    } else if (entry.endsWith('.vue') && full.includes('/mockups/')) {
      acc.push(full)
    }
  }
  return acc
}

function readLibraryExports(): Set<string> {
  const names = new Set<string>()
  if (LIBRARY_EXPORT_INDEX === null) {
    return names
  }
  let src: string
  try {
    src = readFileSync(LIBRARY_EXPORT_INDEX, 'utf-8')
  } catch {
    process.stderr.write(
      `[audit] LIBRARY_EXPORT_INDEX not readable: ${LIBRARY_EXPORT_INDEX}\n` +
      `[audit] Did a library upgrade move its layout? Update the constant in scripts/audit.ts.\n` +
      `[audit] Continuing with zero library exports — shipped components may be misreported as promotion candidates.\n`,
    )
    return names
  }
  // `export { default as Foo }` and `export { Foo, type Bar }`
  const exportBlock = /export\s*\{([^}]+)\}/g
  let m: RegExpExecArray | null
  while ((m = exportBlock.exec(src)) !== null) {
    const body = m[1]
    if (!body) {
      continue
    }
    for (const part of body.split(',')) {
      const trimmed = part.trim()
      if (trimmed === '') {
        continue
      }
      if (trimmed.startsWith('type ')) {
        continue
      }
      const asMatch = /\bas\s+([A-Za-z0-9_]+)/.exec(trimmed)
      if (asMatch?.[1]) {
        names.add(asMatch[1])
      } else {
        const direct = /^([A-Za-z0-9_]+)/.exec(trimmed)
        if (direct?.[1]) {
          names.add(direct[1])
        }
      }
    }
  }
  return names
}

function extractScript(source: string): string {
  const open = source.indexOf('<script')
  if (open === -1) {
    return ''
  }
  const tagEnd = source.indexOf('>', open)
  if (tagEnd === -1) {
    return ''
  }
  const close = source.indexOf('</script>', tagEnd)
  if (close === -1) {
    return ''
  }
  return source.slice(tagEnd + 1, close)
}

function classifySource(from: string): ImportSource {
  if (LIBRARY_MODULES.includes(from)) {
    return 'library'
  }
  if (from === 'lucide-vue-next') {
    return 'icons'
  }
  if (from.startsWith('@mockups/') || from.startsWith('./') || from.startsWith('../')) {
    return 'shared'
  }
  return 'self'
}

function classifyImports(script: string): Map<string, { source: ImportSource; from: string }> {
  const map = new Map<string, { source: ImportSource; from: string }>()
  // import Foo from 'X'
  // import { Foo, Bar as Baz } from 'X'
  // import Foo, { Bar } from 'X'
  const importRegex = /import\s+(?:(\w+)\s*,?\s*)?(?:\{([^}]+)\})?\s*from\s*['"]([^'"]+)['"]/g
  let m: RegExpExecArray | null
  while ((m = importRegex.exec(script)) !== null) {
    const defaultName = m[1]
    const namedBlock = m[2]
    const from = m[3] ?? ''
    const source = classifySource(from)
    if (defaultName !== undefined) {
      map.set(defaultName, { source, from })
    }
    if (namedBlock !== undefined) {
      for (const part of namedBlock.split(',')) {
        const t = part.trim().replace(/^type\s+/, '')
        if (t === '') {
          continue
        }
        const asMatch = /^(\w+)\s+as\s+(\w+)$/.exec(t)
        const local = asMatch !== null ? asMatch[2] : /^(\w+)/.exec(t)?.[1]
        if (local !== undefined) {
          map.set(local, { source, from })
        }
      }
    }
  }
  return map
}

function extractTemplate(source: string): string {
  const open = source.indexOf('<template')
  if (open === -1) {
    return ''
  }
  const tagEnd = source.indexOf('>', open)
  if (tagEnd === -1) {
    return ''
  }
  const close = source.lastIndexOf('</template>')
  if (close === -1) {
    return ''
  }
  return source.slice(tagEnd + 1, close)
}

const HTML_RESERVED = new Set([
  'Transition',
  'TransitionGroup',
  'KeepAlive',
  'Suspense',
  'Teleport',
  'Component',
  'RouterView',
  'RouterLink',
])

function extractComponentUsages(template: string): Map<string, number> {
  const usages = new Map<string, number>()
  // Match opening tags that start with capital letter: <PascalName ...>
  const tagRegex = /<([A-Z][A-Za-z0-9]*)(?=[\s/>])/g
  let m: RegExpExecArray | null
  while ((m = tagRegex.exec(template)) !== null) {
    const name = m[1]
    if (name === undefined || HTML_RESERVED.has(name)) {
      continue
    }
    usages.set(name, (usages.get(name) ?? 0) + 1)
  }
  return usages
}

function extractFeature(file: string): string {
  const rel = relative(FEATURES_DIR, file)
  const first = rel.split('/')[0]
  return first ?? '?'
}

function main(): void {
  const libraryExports = readLibraryExports()
  const files = walkVueFiles(FEATURES_DIR)
  const byComponent = new Map<string, Usage[]>()
  const sharedSourceMap = new Map<string, Set<string>>()

  for (const file of files) {
    const src = readFileSync(file, 'utf-8')
    const template = extractTemplate(src)
    if (template === '') {
      continue
    }
    const script = extractScript(src)
    const imports = classifyImports(script)
    const usages = extractComponentUsages(template)
    const feature = extractFeature(file)
    const relFile = relative(ROOT, file)
    for (const [name, count] of usages) {
      const importInfo = imports.get(name)
      if (importInfo !== undefined && (importInfo.source === 'library' || importInfo.source === 'icons')) {
        continue
      }
      const source: ImportSource = importInfo?.source ?? 'self'
      if (source === 'shared' && importInfo !== undefined) {
        const set = sharedSourceMap.get(name) ?? new Set<string>()
        set.add(importInfo.from)
        sharedSourceMap.set(name, set)
      }
      const list = byComponent.get(name) ?? []
      list.push({ feature, file: relFile, count, source })
      byComponent.set(name, list)
    }
  }

  // Split: components with at least one 'self' usage are PROMOTION CANDIDATES
  // (someone re-rolled instead of importing canonical). Components used only via
  // 'shared' imports are SHARED IN USE (canonical, healthy — informational).
  const candidates: Candidate[] = []
  const sharedInUse: Candidate[] = []
  for (const [component, usages] of byComponent) {
    if (libraryExports.has(component)) {
      continue
    }
    const features = Array.from(new Set(usages.map((u) => u.feature))).sort()
    const filesUsed = Array.from(new Set(usages.map((u) => u.file))).sort()
    const totalUsages = usages.reduce((acc, u) => acc + u.count, 0)
    if (features.length < 2 && filesUsed.length < 3) {
      continue
    }
    const sharedSources = Array.from(sharedSourceMap.get(component) ?? new Set<string>()).sort()
    const entry: Candidate = { component, totalUsages, features, files: filesUsed, sharedSources, usages }
    const hasSelf = usages.some((u): boolean => u.source === 'self')
    if (hasSelf) {
      candidates.push(entry)
    } else {
      sharedInUse.push(entry)
    }
  }

  function rank(a: Candidate, b: Candidate): number {
    if (b.features.length !== a.features.length) {
      return b.features.length - a.features.length
    }
    return b.totalUsages - a.totalUsages
  }
  candidates.sort(rank)
  sharedInUse.sort(rank)

  const out = {
    generated_at: new Date().toISOString(),
    library_exports: libraryExports.size,
    files_scanned: files.length,
    candidates,
    shared_in_use: sharedInUse,
  }
  writeFileSync(OUTPUT_JSON, JSON.stringify(out, null, 2))

  function printRow(c: Candidate): void {
    process.stdout.write(`  ${c.component.padEnd(28)}  ${String(c.features.length).padStart(2)} features · ${String(c.files.length).padStart(2)} files · ${String(c.totalUsages).padStart(3)} uses\n`)
    process.stdout.write(`  ${' '.repeat(28)}    ${c.features.slice(0, 6).join(', ')}${c.features.length > 6 ? ', …' : ''}\n`)
    if (c.sharedSources.length > 0) {
      process.stdout.write(`  ${' '.repeat(28)}    canonical: ${c.sharedSources.join(', ')}\n`)
    }
  }

  process.stdout.write(`\nMockups audit — ${String(files.length)} files scanned, ${String(libraryExports.size)} library exports\n\n`)
  process.stdout.write(`Promotion candidates: ${String(candidates.length)} (components with ≥1 self-rolled usage that should graduate)\n\n`)
  if (candidates.length === 0) {
    process.stdout.write('  (none — every cross-mockup repeat is already canonicalized via @mockups or shipped in the design system)\n\n')
  } else {
    for (const c of candidates.slice(0, 30)) {
      printRow(c)
    }
    if (candidates.length > 30) {
      process.stdout.write(`  … ${String(candidates.length - 30)} more (see audit.json)\n`)
    }
    process.stdout.write('\n')
  }

  process.stdout.write(`Shared components in use: ${String(sharedInUse.length)} (already-canonical components imported by ≥2 features)\n\n`)
  if (sharedInUse.length === 0) {
    process.stdout.write('  (none yet — add your first via {aiDir}/features/{feature}/mockups/_*.vue + the @mockups alias)\n\n')
  } else {
    for (const c of sharedInUse.slice(0, 20)) {
      printRow(c)
    }
    if (sharedInUse.length > 20) {
      process.stdout.write(`  … ${String(sharedInUse.length - 20)} more (see audit.json)\n`)
    }
    process.stdout.write('\n')
  }

  process.stdout.write(`Full report: ${relative(ROOT, OUTPUT_JSON)}\n\n`)
}

main()
