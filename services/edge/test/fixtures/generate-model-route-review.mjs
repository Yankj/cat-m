import {gemmaRouteReviewManifest} from '../../supabase/functions/_shared/model-route-review.mjs';
// Pure metadata: no credentials, runtime, network, configuration activation or writes.
if(import.meta.main)console.log(JSON.stringify(gemmaRouteReviewManifest(),null,2));
