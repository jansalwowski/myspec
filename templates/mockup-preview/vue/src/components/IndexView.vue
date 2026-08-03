<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { RouterLink, useRoute, useRouter } from 'vue-router'

import type { MockupEntry } from '@/lib/discovery'
import { navTree } from '@/lib/manifest'

interface FlatResult {
  feature: string
  mockup: MockupEntry
}

const route = useRoute()
const router = useRouter()
const searchInput = ref<HTMLInputElement | null>(null)
const query = ref('')
const syncingFromUrl = ref(false)

// URL -> state
watch(
  () => route.query.q,
  (next): void => {
    let incoming = ''
    if (typeof next === 'string') {
      incoming = next
    }
    if (incoming === query.value) {
      return
    }
    syncingFromUrl.value = true
    query.value = incoming
  },
  { immediate: true },
)

// state -> URL (guarded)
watch(query, (next): void => {
  if (syncingFromUrl.value) {
    syncingFromUrl.value = false
    return
  }
  let nextQ: string | undefined = next
  if (next.length === 0) {
    nextQ = undefined
  }
  const nextQuery = { ...route.query, q: nextQ }
  void router.replace({ query: nextQuery })
})

const normalizedQuery = computed((): string => query.value.trim().toLowerCase())

const filteredMockups = computed((): FlatResult[] | null => {
  if (normalizedQuery.value.length === 0) {
    return null
  }
  const out: FlatResult[] = []
  for (const node of navTree) {
    for (const mockup of node.mockups) {
      const title = mockup.frontmatter.title ?? ''
      const description = mockup.frontmatter.description ?? ''
      const hay = `${node.feature} ${mockup.slug} ${title} ${description}`.toLowerCase()
      if (hay.includes(normalizedQuery.value)) {
        out.push({ feature: node.feature, mockup })
      }
    }
  }
  return out
})

function tilePath(feature: string, slug: string): string {
  return `/${feature}/${slug}`
}

function tileTitle(mockup: MockupEntry): string {
  const title = mockup.frontmatter.title
  if (title !== undefined && title.length > 0) {
    return title
  }
  return mockup.slug
}

function tileDescription(mockup: MockupEntry): string {
  return mockup.frontmatter.description ?? ''
}

function resultKey(result: FlatResult): string {
  return `${result.feature}/${result.mockup.slug}`
}

function onKeydown(event: KeyboardEvent): void {
  if (event.key !== '/') {
    return
  }
  const active = document.activeElement
  if (active instanceof HTMLInputElement || active instanceof HTMLTextAreaElement) {
    return
  }
  if (active instanceof HTMLElement && active.isContentEditable) {
    return
  }
  event.preventDefault()
  searchInput.value?.focus()
}

onMounted((): void => {
  document.addEventListener('keydown', onKeydown)
})

onBeforeUnmount((): void => {
  document.removeEventListener('keydown', onKeydown)
})
</script>

<template>
  <div class="p-8">
    <h1 class="mb-6 text-2xl font-bold text-slate-900 dark:text-slate-100">Mockups</h1>

    <input
      ref="searchInput"
      v-model="query"
      type="search"
      placeholder="Search mockups…"
      aria-label="Search mockups"
      class="mb-6 w-full max-w-md rounded border border-slate-300 bg-white px-3 py-2 text-sm text-slate-900 placeholder:text-slate-400 dark:border-slate-700 dark:bg-slate-900 dark:text-slate-100"
    />

    <p v-if="navTree.length === 0" class="text-slate-500 dark:text-slate-400">
      No mockups yet. Drop a <code>.vue</code> file in <code>{aiDir}/features/{feature}/mockups/</code>.
    </p>

    <!-- Active-search state: flat result list -->
    <div v-else-if="filteredMockups !== null">
      <p v-if="filteredMockups.length === 0" class="text-sm text-slate-500 dark:text-slate-400">
        No mockups match "{{ query }}".
      </p>
      <div v-else class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
        <RouterLink
          v-for="result in filteredMockups"
          :key="resultKey(result)"
          :to="tilePath(result.feature, result.mockup.slug)"
          class="block no-underline"
        >
          <div class="rounded-lg border border-slate-200 bg-white p-4 shadow-sm transition-shadow hover:shadow-md dark:border-slate-700 dark:bg-slate-900">
            <p class="text-xs text-slate-500 dark:text-slate-400">{{ result.feature }}</p>
            <p class="mt-1 font-semibold text-slate-900 dark:text-slate-100">{{ tileTitle(result.mockup) }}</p>
            <p class="mt-1 line-clamp-2 text-sm text-slate-500 dark:text-slate-400">{{ tileDescription(result.mockup) }}</p>
          </div>
        </RouterLink>
      </div>
    </div>

    <!-- Empty-query state: grouped grid -->
    <div v-else class="space-y-8">
      <section v-for="node in navTree" :key="node.feature">
        <h2 class="mb-2 px-1 text-xs font-semibold uppercase tracking-wide text-slate-500 dark:text-slate-400">
          {{ node.feature }}
        </h2>
        <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
          <RouterLink
            v-for="mockup in node.mockups"
            :key="mockup.slug"
            :to="tilePath(node.feature, mockup.slug)"
            class="block no-underline"
          >
            <div class="rounded-lg border border-slate-200 bg-white p-4 shadow-sm transition-shadow hover:shadow-md dark:border-slate-700 dark:bg-slate-900">
              <p class="font-semibold text-slate-900 dark:text-slate-100">{{ tileTitle(mockup) }}</p>
              <p class="mt-1 line-clamp-2 text-sm text-slate-500 dark:text-slate-400">{{ tileDescription(mockup) }}</p>
            </div>
          </RouterLink>
        </div>
      </section>
    </div>
  </div>
</template>

<style scoped>
</style>
