/* Catpaw UX R4 — presentation-only motion primitives, no network or effect authority.
 *
 * spring({ initial, stiffness=420, damping=38, mass=1, precision=.1,
 *          velocityPrecision=1, reducedMotion, onUpdate, onSettle })
 *   .to(target[, velocity]) preserves velocity when the second argument is omitted.
 *   .set(value) moves immediately, clears velocity and cancels the prior destination.
 *   .stop() freezes at the current position. .destroy() also releases callbacks.
 *   Read-only properties: value, velocity, target, moving.
 *   onUpdate(value, velocity, spring); onSettle(value, spring).
 *
 * pan(element, { axis='x', shouldStart, onStart, onMove, onEnd, onCancel })
 *   onStart runs only AFTER directional intent is accepted, followed by onMove.
 *   Every callback receives { dx, dy, vx, vy, x, y, startX, startY, event }.
 *   onStart may return false to decline the gesture. onCancel also has reason.
 *   Keep touch-action:pan-y on horizontal surfaces and touch-action:none on a
 *   dedicated vertical sheet grabber. The engine does not change scrolling CSS.
 *   Return value has .cancel(), .destroy(), .active and .pending.
 *
 * Neither an animation settling nor a gesture ending is an approval or receipt.
 */
(function (global) {
  'use strict';

  const now = () => global.performance && global.performance.now
    ? global.performance.now() : Date.now();
  const requestFrame = global.requestAnimationFrame
    ? callback => global.requestAnimationFrame(callback)
    : callback => global.setTimeout(() => callback(now()), 16);
  const cancelFrame = global.cancelAnimationFrame
    ? id => global.cancelAnimationFrame(id) : id => global.clearTimeout(id);
  const reducedQuery = global.matchMedia
    ? global.matchMedia('(prefers-reduced-motion: reduce)') : null;
  const finite = (value, fallback) => Number.isFinite(Number(value)) ? Number(value) : fallback;
  const clamp = (value, low, high) => Math.max(low, Math.min(high, value));

  // Exact integration of m*x'' + c*x' + k*(x-target) = 0. Unlike an Euler
  // integrator, a late browser frame cannot inject energy or explode the spring.
  function integrate(position, velocity, target, seconds, stiffness, damping, mass) {
    if (seconds <= 0) return [position, velocity];
    const displacement = position - target;
    const alpha = damping / (2 * mass);
    const omegaSquared = stiffness / mass;
    const discriminant = alpha * alpha - omegaSquared;
    const epsilon = omegaSquared * 1e-8;
    let nextDisplacement;
    let nextVelocity;

    if (discriminant < -epsilon) {
      const omega = Math.sqrt(-discriminant);
      const cosine = Math.cos(omega * seconds);
      const sine = Math.sin(omega * seconds);
      const attenuation = Math.exp(-alpha * seconds);
      const b = (velocity + alpha * displacement) / omega;
      nextDisplacement = attenuation * (displacement * cosine + b * sine);
      nextVelocity = attenuation * (
        -alpha * (displacement * cosine + b * sine)
        - displacement * omega * sine + b * omega * cosine
      );
    } else if (discriminant > epsilon) {
      const root = Math.sqrt(discriminant);
      const r1 = -alpha + root;
      const r2 = -alpha - root;
      const a = (velocity - r2 * displacement) / (r1 - r2);
      const b = displacement - a;
      const e1 = Math.exp(r1 * seconds);
      const e2 = Math.exp(r2 * seconds);
      nextDisplacement = a * e1 + b * e2;
      nextVelocity = a * r1 * e1 + b * r2 * e2;
    } else {
      const b = velocity + alpha * displacement;
      const attenuation = Math.exp(-alpha * seconds);
      nextDisplacement = (displacement + b * seconds) * attenuation;
      nextVelocity = (b - alpha * (displacement + b * seconds)) * attenuation;
    }
    return [target + nextDisplacement, nextVelocity];
  }

  class Spring {
    constructor(options = {}) {
      this._value = finite(options.initial, 0);
      this._velocity = 0;
      this._target = this._value;
      this.stiffness = Math.max(.001, finite(options.stiffness, 420));
      this.damping = Math.max(.001, finite(options.damping, 38));
      this.mass = Math.max(.001, finite(options.mass, 1));
      this.precision = Math.max(.00001, finite(options.precision, .1));
      this.velocityPrecision = Math.max(.00001, finite(options.velocityPrecision, 1));
      this.onUpdate = typeof options.onUpdate === 'function' ? options.onUpdate : null;
      this.onSettle = typeof options.onSettle === 'function' ? options.onSettle : null;
      this._reduce = options.reducedMotion;
      this._moving = false;
      this._frame = null;
      this._time = 0;
      this._generation = 0;
      this._tick = timestamp => this._advance(timestamp);
    }

    get value() { return this._value; }
    get velocity() { return this._velocity; }
    get target() { return this._target; }
    get moving() { return this._moving; }

    _reduced() {
      return typeof this._reduce === 'function' ? !!this._reduce()
        : typeof this._reduce === 'boolean' ? this._reduce : !!(reducedQuery && reducedQuery.matches);
    }

    _sample(timestamp) {
      if (!this._moving) return;
      const seconds = Math.max(0, timestamp - this._time) / 1000;
      const [value, velocity] = integrate(
        this._value, this._velocity, this._target, seconds,
        this.stiffness, this.damping, this.mass
      );
      this._value = value;
      this._velocity = velocity;
      this._time = timestamp;
    }

    _emit() {
      if (this.onUpdate) this.onUpdate(this._value, this._velocity, this);
    }

    _settle() {
      this._value = this._target;
      this._velocity = 0;
      this._moving = false;
      this._frame = null;
      // A render callback may immediately start another animation. Its new
      // generation must not receive the old destination's completion callback.
      const generation = this._generation;
      this._emit();
      if (generation === this._generation && !this._moving && this.onSettle) {
        this.onSettle(this._value, this);
      }
    }

    _advance(timestamp) {
      this._frame = null;
      if (!this._moving) return;
      if (this._reduced()) { this._settle(); return; }
      this._sample(timestamp);
      if (Math.abs(this._value - this._target) <= this.precision
          && Math.abs(this._velocity) <= this.velocityPrecision) {
        this._settle();
        return;
      }
      const generation = this._generation;
      this._emit();
      if (this._moving && generation === this._generation && this._frame === null) {
        this._frame = requestFrame(this._tick);
      }
    }

    set(value) {
      if (!Number.isFinite(Number(value))) return this;
      this._generation++;
      if (this._frame !== null) cancelFrame(this._frame);
      this._frame = null;
      this._moving = false;
      this._value = this._target = Number(value);
      this._velocity = 0;
      this._time = now();
      this._emit();
      return this;
    }

    to(target, velocity) {
      if (!Number.isFinite(Number(target))) return this;
      const timestamp = now();
      this._sample(timestamp);
      this._generation++;
      this._target = Number(target);
      if (velocity !== undefined && Number.isFinite(Number(velocity))) this._velocity = Number(velocity);
      this._time = timestamp;
      if (this._reduced() || (
        Math.abs(this._value - this._target) <= this.precision
        && Math.abs(this._velocity) <= this.velocityPrecision
      )) {
        if (this._frame !== null) cancelFrame(this._frame);
        this._settle();
      } else {
        this._moving = true;
        if (this._frame === null) this._frame = requestFrame(this._tick);
      }
      return this;
    }

    stop() {
      this._sample(now());
      this._generation++;
      if (this._frame !== null) cancelFrame(this._frame);
      this._frame = null;
      this._moving = false;
      this._target = this._value;
      this._velocity = 0;
      this._emit();
      return this;
    }

    destroy() {
      this.stop();
      this.onUpdate = this.onSettle = null;
    }
  }

  function rubberBand(distance, dimension, coefficient = .55) {
    const sign = Math.sign(finite(distance, 0));
    const amount = Math.abs(finite(distance, 0));
    const size = Math.max(1, finite(dimension, 1));
    const resistance = Math.max(.001, finite(coefficient, .55));
    return sign * (size * resistance * amount) / (size + resistance * amount);
  }

  // Deceleration is per millisecond, matching UIScrollView's commonly quoted
  // unit. This is a projection helper, not a replacement for native scrolling.
  function project(value, velocity, deceleration = .998) {
    const rate = clamp(finite(deceleration, .998), .001, .9999);
    return finite(value, 0) + finite(velocity, 0) / 1000 * rate / (1 - rate);
  }

  function decideSnap(value, velocity, points, projectionSeconds = .18) {
    const validPoints = Array.from(new Set((points || []).map(Number).filter(Number.isFinite)))
      .sort((a, b) => a - b);
    if (!validPoints.length) return finite(value, 0);
    const predicted = finite(value, 0) + finite(velocity, 0)
      * Math.max(0, finite(projectionSeconds, .18));
    return validPoints.reduce((best, point) => {
      const currentDistance = Math.abs(point - predicted);
      const bestDistance = Math.abs(best - predicted);
      if (Math.abs(currentDistance - bestDistance) < 1e-9) {
        return velocity > 0 ? Math.max(best, point) : Math.min(best, point);
      }
      return currentDistance < bestDistance ? point : best;
    }, validPoints[0]);
  }

  function bindPan(element, options = {}) {
    if (!element || !element.addEventListener) throw new TypeError('pan requires an Element');
    const axis = options.axis === 'y' ? 'y' : 'x';
    const threshold = Math.max(1, finite(options.threshold, 6));
    const ratio = Math.max(1, finite(options.axisRatio, 1.25));
    let gesture = null;
    let destroyed = false;

    function timestamp(event) { return finite(event.timeStamp, now()); }
    function addSample(event) {
      const t = timestamp(event);
      const x = finite(event.clientX, gesture.x);
      const y = finite(event.clientY, gesture.y);
      if (x !== gesture.x || y !== gesture.y) gesture.lastMovement = t;
      gesture.x = x;
      gesture.y = y;
      const last = gesture.samples[gesture.samples.length - 1];
      if (last && t <= last.t) {
        if (t === last.t) { last.x = x; last.y = y; }
        return;
      }
      gesture.samples.push({ t, x, y });
      while (gesture.samples.length > 2 && t - gesture.samples[0].t > 90) gesture.samples.shift();
    }

    function velocities(event) {
      const samples = gesture.samples;
      if (timestamp(event) - gesture.lastMovement > 90 || samples.length < 2) return [0, 0];
      // A short least-squares window is less sensitive to event batching than
      // the final single move, while preserving deliberate release direction.
      const origin = samples[0].t;
      const times = samples.map(sample => (sample.t - origin) / 1000);
      const meanTime = times.reduce((sum, t) => sum + t, 0) / times.length;
      const meanX = samples.reduce((sum, sample) => sum + sample.x, 0) / samples.length;
      const meanY = samples.reduce((sum, sample) => sum + sample.y, 0) / samples.length;
      let denominator = 0;
      let numeratorX = 0;
      let numeratorY = 0;
      samples.forEach((sample, index) => {
        const timeDelta = times[index] - meanTime;
        denominator += timeDelta * timeDelta;
        numeratorX += timeDelta * (sample.x - meanX);
        numeratorY += timeDelta * (sample.y - meanY);
      });
      return denominator > 1e-8 ? [numeratorX / denominator, numeratorY / denominator] : [0, 0];
    }

    function payload(event, reason) {
      const [vx, vy] = velocities(event);
      return {
        dx: gesture.x - gesture.startX, dy: gesture.y - gesture.startY,
        vx, vy, x: gesture.x, y: gesture.y,
        startX: gesture.startX, startY: gesture.startY,
        pointerId: gesture.id, pointerType: gesture.pointerType,
        event, ...(reason ? { reason } : {})
      };
    }

    function clear() {
      if (!gesture) return;
      const id = gesture.id;
      gesture = null;
      if (element.hasPointerCapture && element.hasPointerCapture(id)) {
        try { element.releasePointerCapture(id); } catch (_) { /* Pointer already ended. */ }
      }
    }

    function cancel(event, reason = 'cancel') {
      if (!gesture) return;
      const data = payload(event || gesture.lastEvent, reason);
      const accepted = gesture.accepted;
      clear();
      if (accepted && typeof options.onCancel === 'function') options.onCancel(data);
    }

    function down(event) {
      if (destroyed || gesture || event.isPrimary === false
          || (event.pointerType === 'mouse' && event.button !== 0)) return;
      if (typeof options.shouldStart === 'function' && !options.shouldStart(event)) return;
      const t = timestamp(event);
      gesture = {
        id: event.pointerId, pointerType: event.pointerType,
        startX: event.clientX, startY: event.clientY,
        x: event.clientX, y: event.clientY, accepted: false,
        lastMovement: t, lastEvent: event,
        samples: [{ t, x: event.clientX, y: event.clientY }]
      };
      // No preventDefault and no capture while vertical scrolling can still win.
    }

    function move(event) {
      if (!gesture || event.pointerId !== gesture.id) return;
      gesture.lastEvent = event;
      const coalesced = typeof event.getCoalescedEvents === 'function' ? event.getCoalescedEvents() : [];
      coalesced.forEach(sample => addSample(sample));
      addSample(event);
      const dx = gesture.x - gesture.startX;
      const dy = gesture.y - gesture.startY;
      if (!gesture.accepted) {
        const primary = Math.abs(axis === 'x' ? dx : dy);
        const perpendicular = Math.abs(axis === 'x' ? dy : dx);
        if (perpendicular > threshold && perpendicular > primary * ratio) { clear(); return; }
        if (primary <= threshold || primary < perpendicular * ratio) return;
        gesture.accepted = true;
        const start = payload(event);
        if (typeof options.onStart === 'function' && options.onStart(start) === false) { clear(); return; }
        // The start callback may cancel or destroy this binding.
        if (!gesture) return;
        if (element.setPointerCapture) {
          try { element.setPointerCapture(event.pointerId); } catch (_) { /* Detached target. */ }
        }
      }
      if (event.cancelable) event.preventDefault();
      if (typeof options.onMove === 'function') options.onMove(payload(event));
    }

    function up(event) {
      if (!gesture || event.pointerId !== gesture.id) return;
      addSample(event);
      const data = payload(event);
      const accepted = gesture.accepted;
      clear();
      if (accepted && typeof options.onEnd === 'function') options.onEnd(data);
    }

    function pointerCancel(event) {
      if (gesture && event.pointerId === gesture.id) cancel(event, 'pointercancel');
    }

    function lostCapture(event) {
      if (gesture && gesture.accepted && event.pointerId === gesture.id) cancel(event, 'lostpointercapture');
    }

    function blur() { cancel(null, 'blur'); }
    element.addEventListener('pointerdown', down, { passive: true });
    element.addEventListener('lostpointercapture', lostCapture);
    global.addEventListener('pointermove', move, { passive: false });
    global.addEventListener('pointerup', up);
    global.addEventListener('pointercancel', pointerCancel);
    global.addEventListener('blur', blur);

    return {
      get active() { return !!(gesture && gesture.accepted); },
      get pending() { return !!(gesture && !gesture.accepted); },
      cancel() { cancel(null, 'programmatic'); },
      destroy() {
        if (destroyed) return;
        cancel(null, 'destroy');
        destroyed = true;
        element.removeEventListener('pointerdown', down);
        element.removeEventListener('lostpointercapture', lostCapture);
        global.removeEventListener('pointermove', move);
        global.removeEventListener('pointerup', up);
        global.removeEventListener('pointercancel', pointerCancel);
        global.removeEventListener('blur', blur);
      }
    };
  }

  global.CatpawMotion = Object.freeze({
    Spring, spring: options => new Spring(options),
    bindPan, pan: bindPan, rubberBand, project, decideSnap,
    prefersReducedMotion: () => !!(reducedQuery && reducedQuery.matches)
  });
})(typeof window !== 'undefined' ? window : globalThis);
