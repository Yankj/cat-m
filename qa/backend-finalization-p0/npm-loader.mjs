import {pathToFileURL} from 'node:url';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
const root=path.dirname(fileURLToPath(import.meta.url));
export function resolve(specifier,context,nextResolve) {
  if(specifier==='npm:jose@6.2.12')return {url:pathToFileURL(path.join(root,'build/npm/jose/dist/webapi/index.js')).href,shortCircuit:true};
  if(specifier.startsWith('npm:')||/^https?:/.test(specifier))throw Error('Unapproved external dependency');
  return nextResolve(specifier,context);
}
