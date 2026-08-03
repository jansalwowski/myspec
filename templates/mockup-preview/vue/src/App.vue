<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { RouterLink, RouterView, useRoute } from 'vue-router'

import MockupFrame from '@/components/MockupFrame.vue'
import NavTree from '@/components/NavTree.vue'
import { navTree } from '@/lib/manifest'

const THEME_KEY = 'mockup-preview-theme'

const isDark = ref(false)
const route = useRoute()

const isFrameMode = new URLSearchParams(window.location.search).has('frame')

const themeLabel = computed((): string => {
  if (isDark.value) {
    return 'Light'
  }
  return 'Dark'
})

const currentSourcePath = computed((): string | null => {
  const sp = route.meta['sourcePath']
  if (typeof sp === 'string') {
    return sp
  }
  return null
})

// Resolve the current feature id from the route path. Feature ids may contain
// slashes (sub-features like `browser-extension/landing-page`), so a naive
// "first segment" pick is wrong. Match longest known feature id from navTree
// that is either equal to the path tail (README route) or a directory-prefix
// of it (mockup route — feature id + one slug segment after).
const currentFeature = computed((): string | null => {
  const tail = route.path.replace(/^\/+/, '')
  if (tail.length === 0) {
    return null
  }
  let best: string | null = null
  for (const node of navTree) {
    if (tail === node.feature) {
      if (best === null || node.feature.length > best.length) {
        best = node.feature
      }
      continue
    }
    if (tail.startsWith(`${node.feature}/`)) {
      const remainder = tail.slice(node.feature.length + 1)
      if (!remainder.includes('/')) {
        if (best === null || node.feature.length > best.length) {
          best = node.feature
        }
      }
    }
  }
  return best
})

const currentMockupFeature = computed((): string | null => {
  const segments = route.path.split('/').filter((s) => s.length > 0)
  if (segments.length < 2) {
    return null
  }
  return segments.slice(0, -1).join('/')
})

const currentSlug = computed((): string | null => {
  const segments = route.path.split('/').filter((s) => s.length > 0)
  const last = segments[segments.length - 1]
  if (last === undefined || segments.length < 2) {
    return null
  }
  return last
})

const showSidenav = computed((): boolean => currentFeature.value !== null)

function toggleTheme(): void {
  isDark.value = !isDark.value
  if (isDark.value) {
    document.documentElement.classList.add('dark')
    localStorage.setItem(THEME_KEY, 'dark')
  } else {
    document.documentElement.classList.remove('dark')
    localStorage.setItem(THEME_KEY, 'light')
  }
}

onMounted(() => {
  const saved = localStorage.getItem(THEME_KEY)
  if (saved === 'dark') {
    isDark.value = true
    document.documentElement.classList.add('dark')
  }
})
</script>

<template>
  <!-- Bare frame mode (rendered inside MockupFrame's iframe) — no chrome -->
  <RouterView v-if="isFrameMode" v-slot="{ Component }">
    <component :is="Component" />
  </RouterView>

  <!-- Normal mode -->
  <div v-else class="flex h-screen flex-col bg-white dark:bg-slate-900 text-slate-900 dark:text-slate-100">
    <header class="flex items-center justify-between border-b border-slate-200 dark:border-slate-700 px-4 py-3">
      <RouterLink
        to="/"
        class="text-lg font-semibold text-slate-900 dark:text-slate-100 hover:text-slate-600 dark:hover:text-slate-300"
      >
        Feature Mockups
      </RouterLink>
      <button
        type="button"
        class="rounded-md px-2.5 py-1.5 text-xs font-medium text-slate-600 hover:bg-slate-100 hover:text-slate-900 dark:text-slate-300 dark:hover:bg-slate-800 dark:hover:text-slate-100"
        @click="toggleTheme"
      >
        {{ themeLabel }}
      </button>
    </header>
    <div class="flex flex-1 overflow-hidden">
      <aside
        v-if="showSidenav"
        class="w-64 overflow-y-auto border-r border-slate-200 dark:border-slate-700 p-4"
      >
        <NavTree :tree="navTree" :current-feature="currentFeature" />
      </aside>
      <main class="flex-1 overflow-y-auto">
        <RouterView v-slot="{ Component }">
          <MockupFrame
            v-if="currentSourcePath !== null && currentMockupFeature !== null && currentSlug !== null"
            :feature="currentMockupFeature"
            :slug="currentSlug"
            :source-path="currentSourcePath"
          >
            <component :is="Component" />
          </MockupFrame>
          <component :is="Component" v-else />
        </RouterView>
      </main>
    </div>
  </div>
</template>

<style scoped>
</style>
