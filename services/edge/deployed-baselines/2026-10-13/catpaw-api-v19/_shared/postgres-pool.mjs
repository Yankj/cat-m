// Postgres.js reserve pins BEGIN/statements/COMMIT to one connection; prepare:false for transaction pooler.
export function pgCompatiblePool(sql){return {async connect(){const reserved=await sql.reserve();let released=false;return {async query(text,parameters=[]){
 if(released)throw Error('connection_released');
 // The injected pg contract supplies JSON text. Bind those explicit casts as text (OID 25)
 // so Postgres.js cannot stringify them again after PostgreSQL describes a jsonb parameter.
 // SQL is owned by this runtime; UUID and other parameters retain their inferred types.
 const jsonPositions=new Set([...text.matchAll(/\$(\d+)\s*::\s*jsonb?\b/gi)].map(m=>Number(m[1])-1));
 const args=parameters.map((value,index)=>jsonPositions.has(index)&&typeof value==='string'?reserved.typed(value,25):value);
 const rows=await reserved.unsafe(text,args);return {rows:[...rows]};
},release(){if(!released){released=true;reserved.release();}}};}};}
export function boundedPool(pool){return {async connect(){const c=await pool.connect();return {async query(text,args=[]){const result=await c.query(text,args);if(/^BEGIN\b/i.test(text)){await c.query("SET LOCAL statement_timeout='5000ms'");await c.query("SET LOCAL lock_timeout='1500ms'");await c.query("SET LOCAL idle_in_transaction_session_timeout='8000ms'");}return result;},release:()=>c.release()};}};}

export async function verifyDedicatedPool(pool){const c=await pool.connect();try{
 const r=await c.query("SELECT r.rolsuper,r.rolbypassrls,c.relowner=r.oid AS owns_records,pg_has_role(current_user,'catpaw_records','USAGE') AS records_cap,pg_has_role(current_user,'catpaw_auth','USAGE') AS auth_cap FROM pg_roles r JOIN pg_class c ON c.oid='public.records'::regclass WHERE r.rolname=current_user");
 const row=r.rows[0];if(!row||row.rolsuper||row.rolbypassrls||row.owns_records||!row.records_cap||!row.auth_cap)throw Error('dedicated_database_login_required');
 // Same reserved connection/driver; fixed synthetic values only, no table writes or Auth identity.
 const probe=await c.query('SELECT jsonb_typeof($1::jsonb) AS object_type,jsonb_typeof($2::jsonb) AS array_type,jsonb_typeof($3::jsonb) AS string_type,jsonb_typeof($4::jsonb) AS null_type',[JSON.stringify({contract:1}),JSON.stringify([1]),JSON.stringify('contract'),JSON.stringify(null)]);
 const types=probe.rows[0];if(types?.object_type!=='object'||types.array_type!=='array'||types.string_type!=='string'||types.null_type!=='null')throw Error('postgres_json_binding_contract_failed');
 console.info(JSON.stringify({event:'catpaw_postgres_json_contract_checked',object_type:types.object_type,array_type:types.array_type,string_type:types.string_type,null_type:types.null_type}));
}finally{c.release();}}
