import type { Config } from 'tailwindcss'

// Semantic tokens (bg-surface, bg-surface-inset, text-text-primary,
// text-text-secondary, text-text-muted, border-border) resolve to the CSS
// custom properties defined in src/styles/main.css — mockups can use them out
// of the box. To wire your own design system, replace this theme with your
// library's Tailwind preset (or extend `content` to include the library's
// source so its classes are generated).
export default {
  darkMode: 'class',
  content: [
    './index.html',
    './src/**/*.{vue,ts}',
    // EDIT ME (repo layout): the mockups tree, in sync with README.md
    '../.ai/features/**/mockups/*.vue',
  ],
  theme: {
    extend: {
      colors: {
        surface: 'rgb(var(--color-surface) / <alpha-value>)',
        'surface-inset': 'rgb(var(--color-surface-inset) / <alpha-value>)',
        border: 'rgb(var(--color-border) / <alpha-value>)',
        text: {
          primary: 'rgb(var(--color-text-primary) / <alpha-value>)',
          secondary: 'rgb(var(--color-text-secondary) / <alpha-value>)',
          muted: 'rgb(var(--color-text-muted) / <alpha-value>)',
          link: 'rgb(var(--color-text-link) / <alpha-value>)',
          'link-hover': 'rgb(var(--color-text-link-hover) / <alpha-value>)',
        },
      },
    },
  },
} satisfies Config
