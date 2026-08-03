import { createApp } from 'vue'

import App from '@/App.vue'
import { router } from '@/router'
import '@/styles/main.css'
// ── Design-system slot ───────────────────────────────────────────────────────
// Import your component library's stylesheet here so mockups render with real
// design-system styling, e.g.:
// import '../../packages/uikit/src/styles/main.css'
// ─────────────────────────────────────────────────────────────────────────────

createApp(App).use(router).mount('#app')
