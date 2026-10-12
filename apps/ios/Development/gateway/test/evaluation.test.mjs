import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {DurableStore} from '../src/store.mjs';
import {evaluate} from '../scripts/evaluate.mjs';
test('four candidates each run five mock tasks; persisted ledger refuses a fourth invocation per task', async () => {
  const path=join(mkdtempSync(join(tmpdir(),'catpaw-eval-')),'ledger.json');
  for(let iteration=1;iteration<=3;iteration++) {
    const result=await evaluate({store:new DurableStore(path)});
    assert.equal(result.results.length,20);assert.ok(result.results.every(x=>x.contract_pass&&x.calls_reserved===iteration));
    assert.equal(result.real_api_calls,0);assert.equal(result.quality_ranking,'not_measured');
  }
  const refused=await evaluate({store:new DurableStore(path)});
  assert.ok(refused.results.every(x=>x.blocked==='call_limit'));
  const real=await evaluate({store:new DurableStore(path),real:true});
  assert.ok(real.results.every(x=>x.blocked==='free_protection_unverified'));
});
