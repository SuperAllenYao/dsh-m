/**
 * audit.js — append-only, redacted audit log for dsh-m-link.
 *
 * Every line is one JSON object and contains only metadata: timestamps,
 * device ids, short key fingerprints, event names and coarse reasons. Tokens,
 * nonces, signatures, credentials, cookies, message bodies and APNs device
 * tokens never reach this file (enforced by construction: call sites only pass
 * whitelisted fields through {@link AuditLog#record}).
 */

import { appendFileSync, mkdirSync, renameSync, statSync } from 'node:fs';
import { join } from 'node:path';

const MAX_FILE_BYTES = 5 * 1024 * 1024;

/** Short, non-reversible label for public keys / tokens used in logs. */
export function shortFingerprint(value) {
  if (typeof value !== 'string' || value.length === 0) return undefined;
  // Cheap FNV-1a is enough for log correlation; real fingerprints use sha256.
  let hash = 0x811c9dc5;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash.toString(16).padStart(8, '0');
}

export class AuditLog {
  /** @param {{dir: string, enabled?: boolean, log?: (message: string) => void}} options */
  constructor({ dir, enabled = true, log = () => {} }) {
    this.dir = dir;
    this.enabled = enabled;
    this.log = log;
    this.file = join(dir, 'audit.log');
    this.previous = join(dir, 'audit.log.1');
    this.ready = false;
  }

  ensureDir() {
    if (this.ready) return;
    mkdirSync(this.dir, { recursive: true });
    this.ready = true;
  }

  /** Rotate once the segment grows past the cap; keep exactly one previous file. */
  rotateIfNeeded() {
    try {
      const size = statSync(this.file).size;
      if (size < MAX_FILE_BYTES) return;
      renameSync(this.file, this.previous);
    } catch {
      /* no file yet */
    }
  }

  /**
   * Append one metadata-only event.
   * @param {string} event dotted event name, e.g. "pair.redeemed"
   * @param {Record<string, unknown>} [fields] whitelisted metadata
   */
  record(event, fields = {}) {
    if (!this.enabled) return;
    const entry = { ts: new Date().toISOString(), event, ...fields };
    const line = JSON.stringify(entry);
    try {
      this.ensureDir();
      this.rotateIfNeeded();
      appendFileSync(this.file, line + '\n', { mode: 0o600 });
    } catch (error) {
      this.log('audit write failed: ' + String(error?.message ?? error));
    }
  }
}
