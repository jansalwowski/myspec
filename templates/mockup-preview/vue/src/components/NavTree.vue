<script setup lang="ts">
import { ArrowLeft } from 'lucide-vue-next'
import { computed } from 'vue'
import { RouterLink, useRoute } from 'vue-router'

import type { FeatureNode, NavTree } from '@/lib/discovery'
import { getChildIds, getParentId } from '@/lib/discovery'

const props = defineProps<{
  tree: NavTree
  currentFeature: string | null
}>()

const route = useRoute()

const focusedNode = computed((): FeatureNode | null => {
  if (props.currentFeature === null) {
    return null
  }
  return props.tree.find((n) => n.feature === props.currentFeature) ?? null
})

const parentId = computed((): string | null => {
  if (props.currentFeature === null) {
    return null
  }
  return getParentId(props.currentFeature)
})

const childIds = computed((): string[] => {
  if (props.currentFeature === null) {
    return []
  }
  return getChildIds(props.tree, props.currentFeature)
})

function featureReadmePath(feature: string): string {
  return `/${feature}`
}

function mockupPath(feature: string, slug: string): string {
  return `/${feature}/${slug}`
}

function isReadmeActive(feature: string): boolean {
  return route.path === featureReadmePath(feature)
}

function isMockupActive(feature: string, slug: string): boolean {
  return route.path === mockupPath(feature, slug)
}

function mockupLabel(title: string | undefined, slug: string): string {
  if (title !== undefined && title !== '') {
    return title
  }
  return slug
}

function parentLinkLabel(id: string): string {
  return `← Parent: ${id}`
}
</script>

<template>
  <nav>
    <RouterLink
      to="/"
      class="mb-3 flex items-center gap-2 rounded px-2 py-1 text-xs font-medium text-slate-500 hover:bg-slate-100 hover:text-slate-700 dark:text-slate-400 dark:hover:bg-slate-800 dark:hover:text-slate-200"
    >
      <ArrowLeft :size="14" />
      All features
    </RouterLink>

    <section v-if="focusedNode !== null" class="mb-4">
      <RouterLink
        v-if="parentId !== null"
        :to="featureReadmePath(parentId)"
        class="mb-2 block rounded px-2 py-1 text-xs font-medium text-slate-500 hover:bg-slate-100 hover:text-slate-700 dark:text-slate-400 dark:hover:bg-slate-800 dark:hover:text-slate-200"
      >
        {{ parentLinkLabel(parentId) }}
      </RouterLink>
      <p class="mb-1 px-2 text-xs font-semibold uppercase tracking-wide text-slate-500 dark:text-slate-400">
        {{ focusedNode.feature }}
      </p>
      <RouterLink
        v-if="focusedNode.readme"
        :to="featureReadmePath(focusedNode.feature)"
        :data-active="isReadmeActive(focusedNode.feature)"
        class="block rounded px-2 py-1 text-sm text-slate-700 hover:bg-slate-100 dark:text-slate-300 dark:hover:bg-slate-800"
        :class="{ 'bg-slate-100 font-medium dark:bg-slate-800': isReadmeActive(focusedNode.feature) }"
      >
        Overview
      </RouterLink>
      <RouterLink
        v-for="mockup in focusedNode.mockups"
        :key="mockup.slug"
        :to="mockupPath(focusedNode.feature, mockup.slug)"
        :data-active="isMockupActive(focusedNode.feature, mockup.slug)"
        class="block rounded px-2 py-1 text-sm text-slate-700 hover:bg-slate-100 dark:text-slate-300 dark:hover:bg-slate-800"
        :class="{ 'bg-slate-100 font-medium dark:bg-slate-800': isMockupActive(focusedNode.feature, mockup.slug) }"
      >
        {{ mockupLabel(mockup.frontmatter.title, mockup.slug) }}
      </RouterLink>

      <div v-if="childIds.length > 0" class="mt-4">
        <p class="mb-1 px-2 text-xs font-semibold uppercase tracking-wide text-slate-500 dark:text-slate-400">
          Sub-features
        </p>
        <RouterLink
          v-for="childId in childIds"
          :key="childId"
          :to="featureReadmePath(childId)"
          class="block rounded px-2 py-1 text-sm text-slate-700 hover:bg-slate-100 dark:text-slate-300 dark:hover:bg-slate-800"
        >
          {{ childId }}
        </RouterLink>
      </div>
    </section>

    <p
      v-else
      class="px-2 text-sm text-slate-500 dark:text-slate-400"
    >
      Feature not found.
    </p>
  </nav>
</template>

<style scoped>
</style>
