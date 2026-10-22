/**
 * host-identity.js — long-lived Ed25519 host key whose public half is embedded
 * in the QR pairing payload (see PAIRING.zh.md).
 *
 * The phone treats the QR content as the out-of-band trust anchor, so the host
 * key lets it verify that the payload fields (endpoints, pins, pair token) were
 * not spliced together by an attacker. The key is generated once per install
 * and stored under $DSH_HOME/plugin-data/dsh-m-link/host-identity.json with
 * 0600 permissions; it never leaves the Mac.
 */

import { createHash, createPrivateKey, createPublicKey, generateKeyPairSync, sign } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

import { canonicalJson } from './canonical.js';

function rawPublicKey(publicKeyObject) {
  // For Ed25519 the SPKI DER ends with the 32-byte raw key: 12-byte header.
  const der = publicKeyObject.export({ type: 'spki', format: 'der' });
  return der.subarray(der.length - 32);
}

/** Load the host identity from disk, generating it on first use. */
export function ensureHostIdentity({ dir, log = () => {} }) {
  mkdirSync(dir, { recursive: true });
  const file = join(dir, 'host-identity.json');
  let record;
  if (existsSync(file)) {
    try {
      record = JSON.parse(readFileSync(file, 'utf8'));
    } catch (error) {
      throw new Error('dsh-m-link: cannot parse ' + file + ': ' + String(error?.message ?? error));
    }
  } else {
    const { publicKey, privateKey } = generateKeyPairSync('ed25519');
    record = {
      version: 1,
      createdAt: new Date().toISOString(),
      publicKey: rawPublicKey(publicKey).toString('base64url'),
      privateKey: privateKey.export({ type: 'pkcs8', format: 'der' }).toString('base64url'),
    };
    writeFileSync(file, JSON.stringify(record, null, 2) + '\n', { mode: 0o600 });
    log('generated Ed25519 host identity');
  }
  const rawPublic = Buffer.from(record.publicKey, 'base64url');
  if (rawPublic.length !== 32) throw new Error('dsh-m-link: host identity public key is not 32 bytes');
  const key = createPrivateKey({ key: Buffer.from(record.privateKey, 'base64url'), format: 'der', type: 'pkcs8' });
  const publicKeyObject = createPublicKey(key);
  const derived = rawPublicKey(publicKeyObject);
  if (!derived.equals(rawPublic)) throw new Error('dsh-m-link: host identity key pair does not match');
  return {
    publicKeyRaw: rawPublic,
    publicKeyBase64Url: rawPublic.toString('base64url'),
    /** host.id = first 8 bytes of sha256(raw public key), lowercase hex. */
    hostId: createHash('sha256').update(rawPublic).digest('hex').slice(0, 16),
    sign: (message) => sign(null, Buffer.from(message, 'utf8'), key).toString('base64url'),
    canonicalJson,
  };
}
