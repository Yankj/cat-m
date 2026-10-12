// Closed telemetry schema: no IDs, content, URLs, arguments, headers or error messages.
const phases=new Set(['request_auth','accept_commit','dispatch_admission','provider_admission','provider_first_delta','text_commit','observer_snapshot','observer_gate','sse_enqueue','terminal_commit','database_connect','database_transaction']);
export function createChatMetrics({sink=entry=>console.info(JSON.stringify(entry)),now=()=>performance.now()}={}){
  return {
    now,
    record(phase,start,{count=0,bytes=0,db_ms=null}={}){
      if(!phases.has(phase))return;
      const entry={event:'catpaw_chat_phase',phase,elapsed_ms:Math.max(0,Math.round((now()-start)*100)/100)};
      if(Number.isSafeInteger(count)&&count>0)entry.count=count;
      if(Number.isSafeInteger(bytes)&&bytes>0)entry.bytes=bytes;
      if(typeof db_ms==='number'&&Number.isFinite(db_ms)&&db_ms>=0)entry.db_ms=Math.round(db_ms*100)/100;
      try{sink(entry);}catch{/* diagnostics never change request outcomes */}
    }
  };
}
