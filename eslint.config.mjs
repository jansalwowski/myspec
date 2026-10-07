// ESLint config for the JS this plugin ships (lib/, workflows/), held to eslint:recommended
// (#208). The hooks and skills run lib/ from the plugin in every consumer's
// sessions (since 3.0 it is no longer copied into projects, #272), so a defect
// here ships everywhere.
//
// The repo has no package.json: CI and pre-commit run a pinned
// `npx -p eslint -p @eslint/js -p globals eslint`. A bare `import '@eslint/js'`
// would resolve from this file's directory and fail, so the two packages are
// resolved from wherever the running eslint was installed (the npx cache, or
// a local install).
import { createRequire } from 'node:module'

const require = createRequire(process.argv[1])
const js = require('@eslint/js')
const globals = require('globals')

export default [
  { ignores: ['**/node_modules/**'] },
  js.configs.recommended,
  {
    files: ['**/*.mjs', '**/*.js'],
    languageOptions: { ecmaVersion: 'latest', sourceType: 'module', globals: { ...globals.node } },
  },
  {
    files: ['**/*.cjs'],
    languageOptions: { ecmaVersion: 'latest', sourceType: 'commonjs', globals: { ...globals.node } },
  },
  {
    // Plugin Workflow scripts (#247). scripts/lint-js.sh feeds each one
    // wrapped in an async function; these are the globals the Workflow
    // runtime provides, and it has no Node API.
    files: ['**/workflows/*.js'],
    languageOptions: {
      sourceType: 'module',
      globals: {
        args: 'readonly', agent: 'readonly', parallel: 'readonly', pipeline: 'readonly',
        phase: 'readonly', log: 'readonly', budget: 'readonly', workflow: 'readonly',
        meta: 'writable', // the shim turns `export const meta =` into `meta =`
      },
    },
  },
  {
    // Served to the browser as a classic script by the brainstorm server.
    files: ['**/brainstorm-server/helper.js'],
    languageOptions: { sourceType: 'script', globals: { ...globals.browser } },
  },
]
