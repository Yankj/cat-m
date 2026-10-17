#!/usr/bin/env node
// Verifies every route served by live catpaw-api v22 still reaches a handler in
// the maintained runtime (test/fixtures/v22-routes.mjs), offline and in-memory.
// Usage: CATPAW_NPM_DIR=/path/node_modules node scripts/check-v22-routes.mjs
import {spawnSync} from 'node:child_process';import {fileURLToPath} from 'node:url';import {dirname,resolve} from 'node:path';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const r=spawnSync(process.execPath,['--import','./test/support/npm-stubs.mjs','--test','test/v22-route-coverage.test.mjs'],{cwd:root,stdio:'inherit'});
process.exit(r.status??1);
