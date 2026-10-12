import { validateReportPolicy } from './report-completion.mjs';
import { TaskWorker } from '../integration/edge-adapter/vendor/openmuse/runtime/engine/worker.mjs';
import { FencedWorkerStore } from '../facade-r2/src/fenced-worker-store.mjs';
import { ApiError } from '../facade-r2/src/common.mjs';
import { LocalOutputFacade } from './local-output-facade.mjs';
import { ChatService } from './chat-service.mjs';
import { modelHandler } from './model-handler.mjs';
import { OpenRouterProvider } from './openrouter-provider.mjs';
export async function createChatRuntime({repository,authenticate=()=>{throw new ApiError(503,'session_verifier_not_configured');},provider=new OpenRouterProvider(),workerOptions={},integration=null,recoverOnStart=true,chatOptions={},handlerOptions={},completionPolicy=null,completionAuthorizer=null}){
  let worker;
  const facade=new LocalOutputFacade({repository,authenticate,executionLayer:'native_chat_provider_ready_unverified',modelConfiguration:structuredClone(provider.identity),abortTask:id=>worker?.abort(id)});
  facade.completionPolicy=validateReportPolicy(completionPolicy);
  if(completionAuthorizer!==null&&typeof completionAuthorizer!=='function')throw new ApiError(422,'invalid_completion_authorizer');facade.completionAuthorizer=completionAuthorizer;
  const store=new FencedWorkerStore(facade),chat=new ChatService({facade,provider,integration,...chatOptions});
  worker=new TaskWorker(store,modelHandler(facade,provider,handlerOptions),workerOptions);
  if(!integration&&recoverOnStart)await chat.recover();
  return {repository,facade,store,worker,chat,provider};
}
