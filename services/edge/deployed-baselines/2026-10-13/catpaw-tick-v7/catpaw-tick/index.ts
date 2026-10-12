import {edgeHandler} from '../_shared/bootstrap.ts';
Deno.serve(edgeHandler('tick',name=>Deno.env.get(name),()=>{}));
