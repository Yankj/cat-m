import { ActionService } from '../patched-openmuse/apps/server/src/actions.ts';
import { shape,check,clone } from './common.mjs';
// Mirrors the preview-only schema in the patch. Original email/calendar schemas stay upstream.
export function parsePreview(raw) {
  shape(raw,['kind','data']);check(raw.kind==='catpaw.preview',422,'external_write_denied');
  shape(raw.data,['artifactId','version','contentHash','title']);
  const d=raw.data;check(/^[a-f0-9]{64}$/.test(d.artifactId)&&/^[a-f0-9]{64}$/.test(d.contentHash)&&Number.isSafeInteger(d.version)&&d.version>0&&typeof d.title==='string'&&d.title.length>0&&d.title.length<=160,422,'schema_invalid');
  return clone(raw);
}
export function upstreamActionsFor(facade) {
  return tx=>new ActionService(tx,{parsePreview,connected:async()=>false,
    // Actual patched upstream ActionService decides/claims/records outcome. No Google call.
    execute:(owner,input)=>facade.previewEffect(tx,owner,input)});
}
