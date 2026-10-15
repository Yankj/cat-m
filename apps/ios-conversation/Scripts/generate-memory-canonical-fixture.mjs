// Offline protocol goldens from the actual maintained service canonical encoder.
import {readFile,writeFile} from 'node:fs/promises';
import {canonical,hash} from '../../../services/edge/supabase/functions/_shared/core/facade-r2/src/common.mjs';

const [probePath,outputPath]=process.argv.slice(2);
if(!probePath||!outputPath)throw Error('Expected the frozen numeric probe and a new golden output path');
const probe=JSON.parse(await readFile(probePath,'utf8'));
if(hash(probe.request)!==probe.request_hash)throw Error('Recorded numeric probe does not match the service canonical hash');
const inputs=[
 {name:'recorded_memory_numeric_request',raw:JSON.stringify(probe.request)},
 {name:'ecmascript_number_boundaries',raw:'{"numbers":[1e-7,1e-6,1e20,1e21,-0,5e-324,1.7976931348623157e+308,-5e-324,-1.7976931348623157e+308,3.14159],"negative_zero":-0}'},
 {name:'utf16_key_order_and_distinct_combining_keys',raw:'{"\\uE000":"private-use","😀":"emoji","é":"composed","e\\u0301":"combining","\\uD800\\uDC00":"non-BMP","A":"ASCII"}'},
 {name:'escaping_and_data_never_code',raw:JSON.stringify({slash:'/a/b',quote:'"',backslash:'\\',controls:'\b\f\n\r\t\u0000',separators:'\u2028\u2029',text:'"); globalThis.CATPAW_CANONICAL_SENTINEL = true; ("',nonBMP:'𝄞😀e\u0301'})},
 {name:'nested_types_and_prototype_named_keys',raw:'{"z":[true,false,null,{"b":2,"a":1}],"a":{"__proto__":"plain data","constructor":"plain data","1":1,"01":2}}'},
];
const cases=inputs.map(({name,raw})=>{const value=JSON.parse(raw);return {name,raw,canonical:canonical(value),sha256:hash(value)};});
const invalid=[
 {name:'escaped_duplicate_key',raw:'{"x":1,"\\u0078":2}'},
 {name:'nonfinite_number',raw:'{"x":1e400}'},
 {name:'excessive_depth',raw:'{"x":'.repeat(70)+'0'+'}'.repeat(70)},
 {name:'root_must_be_object',raw:'[]'},
 {name:'trailing_value',raw:'{} false'},
 {name:'payload_byte_limit',raw:'{}',max_bytes:1},
];
await writeFile(outputPath,JSON.stringify({schema_version:1,fixture_kind:'maintained_service_ecmascript_canonical_goldens',service_encoder:'services/edge/supabase/functions/_shared/core/facade-r2/src/common.mjs',original_numeric_request_hash:probe.request_hash,cases,invalid},null,2)+'\n');
console.log(JSON.stringify({goldens:cases.length,rejections:invalid.length,original_numeric_request_hash:probe.request_hash}));
