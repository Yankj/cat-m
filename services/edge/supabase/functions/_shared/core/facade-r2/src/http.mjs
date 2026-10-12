import { ApiError,check,shape } from './common.mjs';
export function createFetchHandler(facade) {
  return async request=>{
    try {
      const u=new URL(request.url),auth=request.headers.get('authorization'),method=request.method;
      const body=async()=>{check(Number(request.headers.get('content-length')??0)<=32768,413,'request_too_large');const text=await request.text();check(Buffer.byteLength(text)<=32768,413,'request_too_large');try{return JSON.parse(text);}catch{throw new ApiError(422,'schema_invalid');}};
      let result,status=200;
      if(method==='GET'&&u.pathname==='/catpaw/v1/capabilities')result=await facade.capabilities(auth);
      else {
        const parts=u.pathname.split('/').filter(Boolean);check(parts[0]==='catpaw'&&parts[1]==='v1'&&parts[2]==='scopes'&&parts[3],404,'not_found');
        const scope=parts[3],tail=parts.slice(4);
        if(method==='POST'&&tail.length===1&&tail[0]==='delegations'){result=await facade.createDelegation(auth,scope,await body());status=201;}
        else if(method==='GET'&&tail.length===2&&tail[0]==='delegations')result=await facade.readDelegation(auth,scope,tail[1]);
        else if(method==='POST'&&tail.length===3&&tail[0]==='delegations'&&tail[2]==='runs'){result=await facade.createRun(auth,scope,tail[1],await body());status=result.idempotent?200:201;}
        else if(method==='POST'&&tail.length===3&&tail[0]==='delegations'&&tail[2]==='control')result=await facade.control(auth,scope,tail[1],await body());
        else if(method==='GET'&&tail.length===2&&tail[0]==='runs')result=await facade.readRun(auth,scope,tail[1]);
        else if(method==='GET'&&tail.length===2&&tail[0]==='operations')result=await facade.readOperation(auth,scope,tail[1]);
        else if(method==='GET'&&tail.length===4&&tail[0]==='artifacts'&&tail[2]==='versions')result=await facade.readArtifact(auth,scope,tail[1],Number(tail[3]));
        else if(method==='GET'&&tail.length===2&&tail[0]==='approvals')result=await facade.readApproval(auth,scope,tail[1]);
        else if(method==='POST'&&tail.length===3&&tail[0]==='approvals'&&tail[2]==='decisions')result=await facade.decide(auth,scope,tail[1],await body());
        else if(method==='POST'&&tail.length===3&&tail[0]==='approvals'&&tail[2]==='reconciliation-checks'){const b=await body();shape(b,[]);result=await facade.reconcile(auth,scope,tail[1]);}
        else throw new ApiError(404,'not_found');
      }
      return Response.json(result,{status,headers:{'Cache-Control':'no-store','X-Content-Type-Options':'nosniff'}});
    } catch(e) {
      const known=e instanceof ApiError;
      return Response.json({schema_version:1,error:{code:known?e.code:'internal_error',message:known?e.code:'Request failed',retryable:false,reconciliation_required:known?e.reconciliation:false}},{status:known?e.status:500,headers:{'Cache-Control':'no-store'}});
    }
  };
}
