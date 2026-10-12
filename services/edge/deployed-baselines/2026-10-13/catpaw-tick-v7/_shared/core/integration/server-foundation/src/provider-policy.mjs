import { ensure, clone, FoundationError } from './common.mjs';

/** Trusted gateway wrapper. No keys, no fetch, no default live provider. Apply to chat/extract/retry/fallback/embedding. */
export class ProviderGateway {
  constructor({ routes, complete }) { ensure(routes && typeof complete === 'function'); this.routes = clone(routes); this.transport = complete; }
  async complete(request) {
    ensure(request && ['chat', 'memory_extract', 'embedding'].includes(request.purpose));
    // Classification is supplied by the authenticated composition root/ContextBundle, not the model's metadata.
    const route = this.routes[request.allowed_route_policy_id]; ensure(route, 'PRIVACY_ROUTE_BLOCKED', 403);
    ensure(['synthetic', 'private'].includes(request.data_class), 'PRIVACY_ROUTE_BLOCKED', 403);
    ensure(route.data_classes?.includes(request.data_class), 'PRIVACY_ROUTE_BLOCKED', 403);
    ensure(request.sensitivity === 'low' || route.allow_sensitive === true, 'PRIVACY_ROUTE_BLOCKED', 403);
    if(route.synthetic_only)ensure(request.data_class==='synthetic','PRIVACY_ROUTE_BLOCKED',403);
    if(route.free&&request.data_class==='private')ensure(route.allow_private_with_consent===true&&request.consent_verified===true,'PRIVACY_ROUTE_BLOCKED',403);
    // No fallback: a block/error is terminal for this request; never downgrade to a free route.
    try { return await this.transport(clone(request), clone(route)); }
    catch {
      // Transport errors may contain echoed prompt/headers; never expose the raw message/cause.
      // Once transport was entered the caller must reconcile its durable dispatch checkpoint, never auto-failover.
      const safe = new FoundationError('PROVIDER_OUTCOME_UNKNOWN', 503); safe.reconciliation_required = true; throw safe;
    }
  }
}
