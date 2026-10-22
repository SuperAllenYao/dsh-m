/**
 * mask.js — log redaction for the deploy engine.
 *
 * Non-negotiable rule (m2b-plan §2.3): the deploy log / UI must never echo the
 * SSH password, a private-key body, the relay HMAC secret or a freshly minted
 * App config's secret material. Everything that reaches the log ring buffer or
 * an error message goes through this masker first.
 *
 * Design notes:
 *   - secrets are registered before use; masking is a plain substring replace
 *     (the engine never needs to mask unregistered values),
 *   - short values (< 4 chars) are ignored to avoid mangling normal log text,
 *   - private keys are registered as their full PEM text as well as every
 *     non-trivial line, because some tools (ssh-keygen error messages) may echo
 *     only one line of the key,
 *   - the password is also registered per-character-run safe: exact substring
 *     only, so masked text keeps its shape.
 */

export class SecretMasker {
  constructor() {
    /** @type {Set<string>} */
    this.secrets = new Set();
  }

  /**
   * Register a secret value to redact from now on.
   * @param {unknown} value
   * @returns {SecretMasker}
   */
  add(value) {
    if (typeof value !== 'string') return this;
    const candidates = [value];
    if (value.includes('-----BEGIN')) {
      for (const line of value.split(/\r?\n/)) {
        if (line.length >= 8 && !line.startsWith('-----')) candidates.push(line);
      }
    }
    for (const candidate of candidates) {
      if (candidate.length >= 4) this.secrets.add(candidate);
    }
    return this;
  }

  /** Redact every registered secret from `text`. */
  mask(text) {
    let output = typeof text === 'string' ? text : String(text ?? '');
    for (const secret of this.secrets) {
      if (secret.length === 0) continue;
      if (output.includes(secret)) output = output.split(secret).join('***');
    }
    return output;
  }

  /** Mask a structured value by masking only strings (defensive, not for logs). */
  maskValue(value) {
    if (typeof value === 'string') return this.mask(value);
    if (Array.isArray(value)) return value.map((entry) => this.maskValue(entry));
    if (value !== null && typeof value === 'object') {
      /** @type {Record<string, unknown>} */
      const output = {};
      for (const [key, entry] of Object.entries(value)) output[key] = this.maskValue(entry);
      return output;
    }
    return value;
  }

  get size() {
    return this.secrets.size;
  }
}

/** Convenience: mask a single string with an ad-hoc set of secrets. */
export function maskText(text, secrets = []) {
  return secrets
    .filter((secret) => typeof secret === 'string' && secret.length >= 4)
    .reduce((acc, secret) => acc.split(secret).join('***'), String(text ?? ''));
}

/**
 * Render a value safe for a log line: numbers/booleans pass through, strings
 * are masked, everything else is JSON-stringified with masking applied after.
 */
export function safeLogValue(value, masker) {
  if (typeof value === 'string') return masker.mask(value);
  try {
    return masker.mask(JSON.stringify(value));
  } catch {
    return '[unserializable]';
  }
}
