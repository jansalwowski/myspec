import { FEATURES_ROOT_MARKER } from '@/config'

export interface MockupFrontmatter {
  title?: string
  description?: string
}

export interface MockupEntry {
  /**
   * Slash-joined feature id between the features root and `/mockups/` on disk.
   * For a sub-feature, this contains `/` (e.g. `browser-extension/landing-page`).
   */
  feature: string
  slug: string
  sourcePath: string
  frontmatter: MockupFrontmatter
  loader: () => Promise<unknown>
}

export interface ReadmeEntry {
  /** Same shape as MockupEntry.feature — may contain `/` for sub-features. */
  feature: string
  sourcePath: string
  content: string
}

export interface FeatureNode {
  feature: string
  readme: ReadmeEntry | null
  mockups: MockupEntry[]
}

export type NavTree = FeatureNode[]

const FRONTMATTER_REGEX = /^\s*<!--\s*([\s\S]*?)\s*-->/

export function parseFrontmatter(source: string): MockupFrontmatter {
  const match = FRONTMATTER_REGEX.exec(source)
  if (!match) {
    return {}
  }

  const body = match[1]
  if (!body) {
    return {}
  }

  const result: MockupFrontmatter = {}
  const lines = body.split('\n')

  for (const line of lines) {
    const colonIndex = line.indexOf(':')
    if (colonIndex === -1) {
      continue
    }
    const key = line.slice(0, colonIndex).trim()
    const value = line.slice(colonIndex + 1).trim()

    if (key === 'title') {
      result.title = value
    } else if (key === 'description') {
      result.description = value
    }
  }

  return result
}

export function extractFeatureFromPath(path: string): string | null {
  const featuresIndex = path.indexOf(FEATURES_ROOT_MARKER)
  const mockupsIndex = path.indexOf('/mockups/')
  if (featuresIndex === -1 || mockupsIndex === -1) {
    return null
  }
  const start = featuresIndex + FEATURES_ROOT_MARKER.length
  if (mockupsIndex <= start) {
    return null
  }
  return path.slice(start, mockupsIndex)
}

export function getParentId(featureId: string): string | null {
  const slash = featureId.lastIndexOf('/')
  if (slash === -1) {
    return null
  }
  return featureId.slice(0, slash)
}

export function getChildIds(tree: NavTree, featureId: string): string[] {
  const prefix = `${featureId}/`
  const out: string[] = []
  for (const node of tree) {
    if (!node.feature.startsWith(prefix)) {
      continue
    }
    const tail = node.feature.slice(prefix.length)
    if (tail.includes('/')) {
      continue
    }
    out.push(node.feature)
  }
  out.sort((a, b) => a.localeCompare(b))
  return out
}

function extractSlug(path: string): string {
  const filename = path.slice(path.lastIndexOf('/') + 1)
  const dotIndex = filename.lastIndexOf('.')
  if (dotIndex === -1) {
    return filename
  }
  return filename.slice(0, dotIndex)
}

// Files whose path segment starts with `_` are private/shared scaffolding
// (e.g. `_Navbar.vue`, `_components/Card.vue`) — they are importable from
// other mockups but never appear as routable pages in the sidenav.
function isPrivatePath(path: string): boolean {
  const mockupsIndex = path.indexOf('/mockups/')
  if (mockupsIndex === -1) {
    return false
  }
  const remainder = path.slice(mockupsIndex + '/mockups/'.length)
  return remainder.split('/').some((segment) => segment.startsWith('_'))
}

export function buildNavTree(
  vueFiles: Record<string, string>,
  vueLoaders: Record<string, () => Promise<unknown>>,
  readmeFiles: Record<string, string>,
): NavTree {
  const featureMap = new Map<string, FeatureNode>()

  for (const [path, content] of Object.entries(vueFiles)) {
    if (isPrivatePath(path)) {
      continue
    }
    const feature = extractFeatureFromPath(path)
    if (!feature) {
      continue
    }

    const slug = extractSlug(path)
    const frontmatter = parseFrontmatter(content)
    const loader = vueLoaders[path] ?? (() => Promise.resolve({}))

    const entry: MockupEntry = {
      feature,
      slug,
      sourcePath: path,
      frontmatter,
      loader,
    }

    const existing = featureMap.get(feature)
    if (existing) {
      existing.mockups.push(entry)
    } else {
      featureMap.set(feature, {
        feature,
        readme: null,
        mockups: [entry],
      })
    }
  }

  for (const [path, content] of Object.entries(readmeFiles)) {
    const feature = extractFeatureFromPath(path)
    if (!feature) {
      continue
    }

    const readmeEntry: ReadmeEntry = {
      feature,
      sourcePath: path,
      content,
    }

    const existing = featureMap.get(feature)
    if (existing) {
      existing.readme = readmeEntry
    } else {
      featureMap.set(feature, {
        feature,
        readme: readmeEntry,
        mockups: [],
      })
    }
  }

  const nodes = Array.from(featureMap.values())

  nodes.sort((a, b) => a.feature.localeCompare(b.feature))

  for (const node of nodes) {
    node.mockups.sort((a, b) => a.slug.localeCompare(b.slug))
  }

  return nodes
}
