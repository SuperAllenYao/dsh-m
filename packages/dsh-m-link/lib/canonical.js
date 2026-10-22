/**
 * canonical.js — RFC 8785 (JCS) subset used to sign the pairing payload.
 *
 * The payload contains only strings, integers, arrays and plain objects, so the
 * canonical form is: keys sorted by UTF-16 code units, no whitespace, strings
 * escaped with JSON.stringify, integers rendered in decimal (no floats, no
 * exponents). This is exactly the form the iOS client must reproduce before
 * verifying the host Ed25519 signature (see PAIRING.zh.md).
 */

/** Reject values JCS cannot represent unambiguously in this payload. */
function assertCanonicalValue(value, path) {
  if (value === null || typeof value === 'boolean') return;
  if (typeof value === 'string') return;
  if (typeof value === 'number') {
    if (!Number.isInteger(value)) throw new Error('canonical: non-integer number at ' + path);
    if (!Number.isSafeInteger(value)) throw new Error('canonical: unsafe integer at ' + path);
    return;
  }
  if (Array.isArray(value)) {
    value.forEach((entry, index) => assertCanonicalValue(entry, path + '[' + String(index) + ']'));
    return;
  }
  if (typeof value === 'object') {
    for (const [key, entry] of Object.entries(value)) {
      if (entry === undefined) throw new Error('canonical: undefined at ' + path + '.' + key);
      assertCanonicalValue(entry, path + '.' + key);
    }
    return;
  }
  throw new Error('canonical: unsupported ' + typeof value + ' at ' + path);
}

/** Canonical JSON text (RFC 8785 subset) for one payload value. */
export function canonicalJson(value) {
  assertCanonicalValue(value, '$');
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return '[' + value.map((entry) => canonicalJson(entry)).join(',') + ']';
  const keys = Object.keys(value).sort();
  return '{' + keys.map((key) => JSON.stringify(key) + ':' + canonicalJson(value[key])).join(',') + '}';
}
