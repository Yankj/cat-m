# Backend rules

- Maintenance source is `supabase/functions/`; its present entry is `catpaw-api/index.ts` plus `_shared`. The hosted tick entry exists in deployed snapshots, not yet in the maintenance tree. Do not invent catpaw-worker/tick paths or deploy this tree as if it matched both hosted functions.
- `deployed-baselines/` is immutable received source. v19 API and v7 tick differ in 14 shared files; select/reconcile sources and test both entries before a future deployment. Never overwrite a dated baseline or manifest.
- Domain/store transactions own scoped facts, revisions, leases, approvals/effects, artifacts and recovery. Tools and adapters use those ports; no second scheduler/store hidden in UI or a framework SDK.
- Effects need specific authority and durable outcome. Timeout/unknown is reconciled; result saved, stream closed and task completed are different states.
- Preserve current model/price/consent policies and frozen HTTP contracts. Version any compatible extension; maintain readable fallback for old clients.
- Source, offline tests, real PG/concurrency, hosted model and deployment are separate evidence layers. Existing dependency caches only; no production requests or deployment implied by a check.
