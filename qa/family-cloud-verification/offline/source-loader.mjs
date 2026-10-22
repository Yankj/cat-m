import {readFile} from 'node:fs/promises';
import {stripTypeScriptTypes} from 'node:module';
import {fileURLToPath} from 'node:url';

export async function resolve(specifier, context, next) {
  if (specifier === 'npm:postgres@3.4.7') return {url: new URL('./postgres-boundary.mjs', import.meta.url).href, shortCircuit: true};
  if (specifier === 'npm:jose@6.2.12') return {url: new URL('./jose-boundary.mjs', import.meta.url).href, shortCircuit: true};
  if (/^(npm:|https?:)/.test(specifier)) throw Error('family_qa_unreviewed_external_import');
  return next(specifier, context);
}
export async function load(url, context, next) {
  if (url.startsWith('file:') && url.endsWith('.ts')) {
    return {format: 'module', source: stripTypeScriptTypes(await readFile(fileURLToPath(url), 'utf8'), {mode: 'transform'}), shortCircuit: true};
  }
  return next(url, context);
}
