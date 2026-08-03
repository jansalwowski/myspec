<script setup lang="ts">
import { Maximize2, Monitor, Smartphone, Tablet } from 'lucide-vue-next'
import { computed, onMounted, ref } from 'vue'
import { RouterLink, useRoute } from 'vue-router'

const props = defineProps<{
  feature: string
  slug: string
  sourcePath: string
}>()

const route = useRoute()

interface BreadcrumbItem {
  label: string
  to: string | null
}

function humanize(segment: string): string {
  return segment
    .split('-')
    .map((word) => {
      if (word.length === 0) {
        return word
      }
      return word.charAt(0).toUpperCase() + word.slice(1)
    })
    .join(' ')
}

const breadcrumb = computed((): BreadcrumbItem[] => {
  const items: BreadcrumbItem[] = []
  const segments = props.feature.split('/')
  let cumulative = ''
  for (const seg of segments) {
    if (cumulative.length > 0) {
      cumulative += '/'
    }
    cumulative += seg
    items.push({ label: humanize(seg), to: `/${cumulative}` })
  }
  items.push({ label: props.slug, to: null })
  return items
})

const iframeSrc = computed<string>(() => {
  return `${window.location.origin}${window.location.pathname}?frame=1#${route.fullPath}`
})

type Viewport = 'mobile' | 'tablet' | 'desktop' | 'full'

interface ViewportOption {
  value: Viewport
  label: string
  width: number | null
  icon: typeof Monitor
}

const STORAGE_KEY = 'mockup-preview-viewport'

const viewportOptions: ViewportOption[] = [
  { value: 'mobile',  label: 'Mobile',  width: 375,  icon: Smartphone },
  { value: 'tablet',  label: 'Tablet',  width: 768,  icon: Tablet },
  { value: 'desktop', label: 'Desktop', width: 1280, icon: Monitor },
  { value: 'full',    label: 'Full',    width: null, icon: Maximize2 },
]

const viewport = ref<Viewport>('full')

const fullOption: ViewportOption = viewportOptions[viewportOptions.length - 1] ?? {
  value: 'full',
  label: 'Full',
  width: null,
  icon: Maximize2,
}

const activeOption = computed<ViewportOption>(() => {
  const found = viewportOptions.find((o) => o.value === viewport.value)
  if (found) {
    return found
  }
  return fullOption
})

const frameStyle = computed<string>(() => {
  const w = activeOption.value.width
  if (w === null) {
    return 'width: 100%; height: 100%;'
  }
  return `width: ${String(w)}px; max-width: 100%;`
})

const isConstrained = computed<boolean>(() => activeOption.value.width !== null)

function viewportButtonClass(value: Viewport): string {
  if (viewport.value === value) {
    return 'bg-white dark:bg-slate-900 text-slate-900 dark:text-slate-100 shadow-sm'
  }
  return 'text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100'
}

function selectViewport(value: Viewport): void {
  viewport.value = value
  localStorage.setItem(STORAGE_KEY, value)
}

function isViewport(value: string): value is Viewport {
  return value === 'mobile' || value === 'tablet' || value === 'desktop' || value === 'full'
}

onMounted(() => {
  const saved = localStorage.getItem(STORAGE_KEY)
  if (saved !== null && isViewport(saved)) {
    viewport.value = saved
  }
})
</script>

<template>
  <div class="flex h-full flex-col">
    <div class="flex items-center justify-between gap-4 border-b border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800 px-4 py-2">
      <div class="flex min-w-0 flex-col gap-0.5">
        <nav
          aria-label="Breadcrumb"
          class="flex items-center gap-1 text-sm text-slate-600 dark:text-slate-400"
        >
          <template v-for="(item, idx) in breadcrumb" :key="idx">
            <span v-if="idx > 0" class="text-slate-400">›</span>
            <RouterLink
              v-if="item.to !== null"
              :to="item.to"
              class="hover:text-slate-900 dark:hover:text-slate-200"
            >
              {{ item.label }}
            </RouterLink>
            <span v-else class="font-medium text-slate-900 dark:text-slate-100">
              {{ item.label }}
            </span>
          </template>
        </nav>
        <span class="select-text truncate font-mono text-xs text-slate-500 dark:text-slate-400">
          {{ sourcePath }}
        </span>
      </div>
      <div class="flex shrink-0 items-center gap-2">
        <span v-if="isConstrained" class="font-mono text-xs tabular-nums text-slate-400 dark:text-slate-500">
          {{ activeOption.width }}px
        </span>
        <div class="flex items-center gap-0.5 rounded-md bg-slate-200/70 p-0.5 dark:bg-slate-700/70">
          <button
            v-for="opt in viewportOptions"
            :key="opt.value"
            type="button"
            class="flex items-center gap-1.5 rounded px-2 py-1 text-xs font-medium transition-colors"
            :class="viewportButtonClass(opt.value)"
            :title="`${opt.label}${opt.width === null ? '' : ` (${String(opt.width)}px)`}`"
            @click="selectViewport(opt.value)"
          >
            <component :is="opt.icon" class="h-3.5 w-3.5" />
            <span class="hidden sm:inline">{{ opt.label }}</span>
          </button>
        </div>
      </div>
    </div>
    <!-- Constrained: render in an iframe so CSS media queries fire on the constrained width -->
    <div
      v-if="isConstrained"
      class="flex flex-1 justify-center overflow-hidden bg-slate-100 p-4 dark:bg-slate-950"
    >
      <iframe
        :src="iframeSrc"
        :style="frameStyle"
        class="h-full overflow-hidden rounded-lg border border-slate-300 bg-white shadow-md dark:border-slate-700 dark:bg-slate-900"
        title="Mockup viewport"
      />
    </div>

    <!-- Full: render the slotted component directly (no iframe) -->
    <div v-else class="flex-1 overflow-auto">
      <div class="h-full">
        <Suspense>
          <slot />
          <template #fallback>
            <div class="flex items-center justify-center p-8 text-slate-400 dark:text-slate-500">
              Loading mockup…
            </div>
          </template>
        </Suspense>
      </div>
    </div>
  </div>
</template>

<style scoped>
</style>
