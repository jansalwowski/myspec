<script setup lang="ts">
import { RouterLink } from 'vue-router'
</script>

<template>
  <div class="p-8">
    <div class="max-w-md rounded-lg border border-slate-200 bg-white p-6 shadow-sm dark:border-slate-700 dark:bg-slate-900">
      <h1 class="mb-2 text-lg font-semibold text-slate-900 dark:text-slate-100">Mockup not found</h1>
      <p class="mb-4 text-sm text-slate-500 dark:text-slate-400">
        The requested mockup does not exist. It may have been renamed or removed.
      </p>
      <RouterLink to="/" class="text-sm font-medium text-blue-600 hover:text-blue-700 dark:text-blue-400 dark:hover:text-blue-300">
        Back to index
      </RouterLink>
    </div>
  </div>
</template>

<style scoped>
</style>
