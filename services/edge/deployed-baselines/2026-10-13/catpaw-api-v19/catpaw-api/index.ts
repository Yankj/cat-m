import {edgeHandler} from '../_shared/bootstrap.ts';
declare const EdgeRuntime:{waitUntil(promise:Promise<unknown>):void};
Deno.serve(edgeHandler('api',name=>Deno.env.get(name),promise=>EdgeRuntime.waitUntil(promise)));
