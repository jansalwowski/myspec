// ESLint config for the JS this plugin ships (lib/ and its plugins/myspec/lib/
// mirror). Downstream projects commonly lint with eslint:recommended, and
// /myspec:update copies lib/ into them, so shipped code must pass it (#208).
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
    // Served to the browser as a classic script by the brainstorm server.
    files: ['**/brainstorm-server/helper.js'],
    languageOptions: { sourceType: 'script', globals: { ...globals.browser } },
  },
]
