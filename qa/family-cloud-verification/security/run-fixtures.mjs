import assert from 'node:assert/strict';
import {metadata,cases,proposedPolicy} from './permission-fixtures.mjs';
const results=cases.map(c=>{const actual=proposedPolicy(c.input);assert.deepEqual(actual,c.expected,c.id);return {id:c.id,name:c.name,fixture_check:'PASS',acceptance_status:'NOT_RUN',actual};});
assert.ok(cases.length>=20);assert.equal(new Set(cases.map(c=>c.id)).size,cases.length);
console.log(JSON.stringify({...metadata,scope:'proposed-policy fixture consistency only',product_authorization_verified:false,postgres_rls_verified:false,real_auth_verified:false,total:results.length,passed:results.length,results},null,2));
