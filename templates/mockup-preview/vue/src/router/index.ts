import { defineAsyncComponent } from 'vue'
import { createRouter, createWebHashHistory, type RouteRecordRaw } from 'vue-router'

import type { NavTree } from '@/lib/discovery'
import { navTree } from '@/lib/manifest'

export function buildRoutes(tree: NavTree): RouteRecordRaw[] {
  const routes: RouteRecordRaw[] = [
    { path: '/', name: 'index', component: () => import('@/components/IndexView.vue') },
  ]

  for (const node of tree) {
    if (node.readme) {
      routes.push({
        path: `/${node.feature}`,
        name: `${node.feature}__readme`,
        component: () => import('@/components/ReadmeView.vue'),
        props: { entry: node.readme },
      })
    }
    for (const m of node.mockups) {
      routes.push({
        path: `/${node.feature}/${m.slug}`,
        name: `${node.feature}__${m.slug}`,
        component: defineAsyncComponent(m.loader as () => Promise<{ default: unknown }>),
        meta: { sourcePath: m.sourcePath, frontmatter: m.frontmatter },
      })
    }
  }

  routes.push({
    path: '/:catchAll(.*)',
    name: 'not-found',
    component: () => import('@/components/NotFoundView.vue'),
  })

  return routes
}

export const router = createRouter({
  history: createWebHashHistory(),
  routes: buildRoutes(navTree),
})
