import test from 'node:test';import assert from 'node:assert/strict';
import {score,strip} from './score.mjs';
test('CER ignores punctuation, spaces and case; the pause note is not part of the reference',()=>{
 assert.equal(score('明天上午九点提醒我给妈妈打电话。','明天上午9点提醒我给妈妈打电话','zh-CN').cer,1/15);
 assert.equal(score('Set a timer for twenty five minutes.','set a timer for 25 minutes','en-US').wer,2/7);
 assert.equal(strip('帮我订票。（停顿两秒）要明天的'),'帮我订票要明天的');
 assert.equal(score('你好。','你好','zh-CN').cer,0);assert.equal(score('你好','','zh-CN').cer,1);
});
