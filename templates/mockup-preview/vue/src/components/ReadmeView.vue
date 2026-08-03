<script setup lang="ts">
import { computed } from 'vue'

import type { ReadmeEntry } from '@/lib/discovery'
import { md } from '@/lib/markdown'

const props = defineProps<{
  entry: ReadmeEntry
}>()

const html = computed((): string => md.render(props.entry.content))
</script>

<template>
  <!-- eslint-disable-next-line vue/no-v-html -- markdown-it html:false; content is repo-checked-in markdown only -->
  <article class="readme max-w-3xl p-8 text-text-primary" v-html="html" />
</template>

<style scoped>
.readme :deep(h1) {
  font-size: 1.875rem;
  font-weight: 700;
  letter-spacing: -0.02em;
  line-height: 1.2;
  margin: 0 0 1.25rem;
  padding-bottom: 0.5rem;
  border-bottom: 1px solid rgb(var(--color-border) / 1);
}
.readme :deep(h2) {
  font-size: 1.375rem;
  font-weight: 600;
  letter-spacing: -0.01em;
  line-height: 1.3;
  margin: 2rem 0 0.75rem;
}
.readme :deep(h3) {
  font-size: 1.125rem;
  font-weight: 600;
  line-height: 1.4;
  margin: 1.5rem 0 0.5rem;
}
.readme :deep(h4) {
  font-size: 1rem;
  font-weight: 600;
  margin: 1.25rem 0 0.5rem;
}
.readme :deep(p) {
  font-size: 0.9375rem;
  line-height: 1.65;
  color: rgb(var(--color-text-secondary) / 1);
  margin: 0.75rem 0;
}
.readme :deep(strong) {
  font-weight: 600;
  color: rgb(var(--color-text-primary) / 1);
}
.readme :deep(em) {
  font-style: italic;
}
.readme :deep(a) {
  color: rgb(var(--color-text-link) / 1);
  text-decoration: underline;
  text-underline-offset: 2px;
}
.readme :deep(a:hover) {
  color: rgb(var(--color-text-link-hover) / 1);
}
.readme :deep(ul),
.readme :deep(ol) {
  font-size: 0.9375rem;
  line-height: 1.65;
  color: rgb(var(--color-text-secondary) / 1);
  margin: 0.75rem 0;
  padding-left: 1.5rem;
}
.readme :deep(ul) { list-style: disc; }
.readme :deep(ol) { list-style: decimal; }
.readme :deep(li) { margin: 0.25rem 0; }
.readme :deep(li > p) { margin: 0.25rem 0; }
.readme :deep(code) {
  font-family: ui-monospace, 'SF Mono', Menlo, Consolas, monospace;
  font-size: 0.85em;
  padding: 0.125rem 0.375rem;
  border-radius: 0.25rem;
  background: rgb(var(--color-surface-inset) / 1);
  border: 1px solid rgb(var(--color-border) / 1);
  color: rgb(var(--color-text-primary) / 1);
}
.readme :deep(pre) {
  font-family: ui-monospace, 'SF Mono', Menlo, Consolas, monospace;
  font-size: 0.8125rem;
  line-height: 1.55;
  padding: 1rem;
  border-radius: 0.5rem;
  background: rgb(var(--color-surface-inset) / 1);
  border: 1px solid rgb(var(--color-border) / 1);
  margin: 1rem 0;
  overflow-x: auto;
}
.readme :deep(pre code) {
  background: transparent;
  border: 0;
  padding: 0;
  font-size: inherit;
}
.readme :deep(blockquote) {
  border-left: 3px solid rgb(var(--color-border) / 1);
  padding: 0.25rem 0 0.25rem 1rem;
  margin: 1rem 0;
  color: rgb(var(--color-text-secondary) / 1);
  font-style: italic;
}
.readme :deep(hr) {
  border: 0;
  border-top: 1px solid rgb(var(--color-border) / 1);
  margin: 2rem 0;
}
.readme :deep(table) {
  width: 100%;
  border-collapse: collapse;
  font-size: 0.875rem;
  margin: 1rem 0;
}
.readme :deep(th),
.readme :deep(td) {
  text-align: left;
  padding: 0.5rem 0.75rem;
  border-bottom: 1px solid rgb(var(--color-border) / 1);
}
.readme :deep(th) {
  font-weight: 600;
  color: rgb(var(--color-text-primary) / 1);
  background: rgb(var(--color-surface-inset) / 1);
}
.readme :deep(td) {
  color: rgb(var(--color-text-secondary) / 1);
}
.readme :deep(img) {
  max-width: 100%;
  border-radius: 0.5rem;
  margin: 1rem 0;
}
.readme :deep(:first-child) {
  margin-top: 0;
}
</style>
