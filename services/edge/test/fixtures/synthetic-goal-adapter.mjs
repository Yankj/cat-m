// Only synthetic data. No network, model, credentials, timers or user-content access.
export class SyntheticGoalAdapter {
  constructor({ effects = [], loseAcknowledgement = false, beforeEffect = async () => {}, afterEffect = async () => {} } = {}) {
    this.schema_version = 1; this.synthetic = true; this.effects = new Map(structuredClone(effects));
    this.loseAcknowledgement = loseAcknowledgement; this.beforeEffect = beforeEffect; this.afterEffect = afterEffect;
    this.dispatch_calls = 0; this.effect_calls = 0; this.reconcile_calls = 0;
  }
  async dispatch({ action, beforeEffect }) {
    this.dispatch_calls++;
    await this.beforeEffect();
    await beforeEffect(); // Fresh goal/permission/version/lease/control immediately before synchronous effect.
    const receipt = { schema_version: 1, synthetic: true, state: 'confirmed', effect_key: action.effect_key,
      observation: action.data.operation === 'send_report' ? 'provider_accepted' : 'plan_prepared' };
    if (!this.effects.has(action.effect_key)) { this.effect_calls++; this.effects.set(action.effect_key, receipt); }
    await this.afterEffect();
    if (this.loseAcknowledgement) throw new Error('synthetic_acknowledgement_lost');
    return structuredClone(this.effects.get(action.effect_key));
  }
  async reconcile({ effect_key }) {
    this.reconcile_calls++;
    return structuredClone(this.effects.get(effect_key) ?? { schema_version: 1, synthetic: true, effect_key, state: 'unknown' });
  }
  snapshot() { return structuredClone([...this.effects]); }
}
