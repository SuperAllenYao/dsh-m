/**
 * devices.js — persistent device registry ($DSH_HOME/plugin-data/dsh-m-link/devices.json).
 *
 * Stores only what verification needs: the device public key (SPKI DER), a
 * hash of the long-term credential, display metadata and the revocation state.
 * Plaintext credentials never touch disk; a stolen devices.json cannot be used
 * to impersonate a phone (the private key lives in the phone's Secure Enclave,
 * the credential is only a lookup secret and is stored hashed here).
 */

import { createHash, createPublicKey, randomBytes, randomUUID, timingSafeEqual } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

/** sha256 fingerprint of an SPKI DER public key, colon-separated hex. */
export function keyFingerprint256(spkiDer) {
  const hex = createHash('sha256').update(spkiDer).digest('hex').toUpperCase();
  return hex.match(/.{2}/g).join(':');
}

/** sha256 fingerprint of an SPKI DER public key, base64url (pin form). */
export function keyPin(spkiDer) {
  return createHash('sha256').update(spkiDer).digest('base64url');
}

/** Normalize a submitted public key to SPKI DER; accepts DER or X9.63 point. */
export function normalizeDevicePublicKey(input) {
  if (typeof input !== 'string' || input.length === 0) throw new Error('device public key missing');
  let bytes;
  try {
    bytes = Buffer.from(input, 'base64url');
  } catch {
    throw new Error('device public key is not base64url');
  }
  if (bytes.length === 0) throw new Error('device public key is empty');
  if (bytes.length === 65 && bytes[0] === 0x04) {
    // Uncompressed X9.63 P-256 point (what SecKeyCopyExternalRepresentation
    // returns for an EC public key): wrap it in a P-256 SPKI header.
    const header = Buffer.from('3059301306072a8648ce3d020106082a8648ce3d030107034200', 'hex');
    bytes = Buffer.concat([header, bytes]);
  } else if (!(bytes[0] === 0x30)) {
    throw new Error('device public key must be a P-256 SPKI DER or an X9.63 uncompressed point');
  }
  const key = createPublicKey({ key: bytes, format: 'der', type: 'spki' });
  if (key.asymmetricKeyType !== 'ec') throw new Error('device public key is not an EC key');
  if (key.asymmetricKeyDetails?.namedCurve !== 'prime256v1') throw new Error('device public key is not P-256');
  return bytes;
}

function sha256(value) {
  return createHash('sha256').update(value).digest('base64url');
}

/**
 * Serialize exactly the durable device fields.
 *
 * The in-memory device object carries runtime state added by the link server
 * (idleTimer, peer, downstream WebSocket). idleTimer is a Node Timeout with
 * circular _idlePrev/_idleNext links, so JSON.stringify(device) throws
 * "Converting circular structure to JSON" — that is the M1 regression the iOS
 * E2E hit as /auth/verify 500. Never serialize the live object: only the
 * whitelisted fields below reach disk.
 */
export function toPersistedDevice(device) {
  const record = {
    deviceId: device.deviceId,
    name: device.name,
    publicKey: device.publicKey,
    keyId: device.keyId,
    platform: device.platform,
    credentialHash: device.credentialHash,
    createdAt: device.createdAt,
    lastSeenAt: device.lastSeenAt,
    lastIp: device.lastIp,
  };
  if (device.revokedAt !== undefined) {
    record.revokedAt = device.revokedAt;
    record.revokedReason = device.revokedReason;
  }
  if (device.pushToken !== undefined) {
    record.pushToken = device.pushToken;
    record.pushEnvironment = device.pushEnvironment;
  }
  return record;
}

/** Persisted device registry. */
export class DeviceStore {
  /** @param {{dir: string, hostId: string, log?: (message: string) => void}} options */
  constructor({ dir, hostId, log = () => {} }) {
    this.dir = dir;
    this.file = join(dir, 'devices.json');
    this.hostId = hostId;
    this.log = log;
    this.devices = new Map();
    this.loaded = false;
  }

  load() {
    mkdirSync(this.dir, { recursive: true });
    if (!existsSync(this.file)) {
      this.loaded = true;
      return this;
    }
    let parsed;
    try {
      parsed = JSON.parse(readFileSync(this.file, 'utf8'));
    } catch (error) {
      const backup = this.file + '.corrupt-' + Date.now();
      try {
        renameSync(this.file, backup);
      } catch {
        /* best effort */
      }
      this.log('devices.json is corrupt (' + String(error?.message ?? error) + '); moved to ' + backup + ' and starting empty (all devices must re-pair)');
      this.loaded = true;
      return this;
    }
    if (!Array.isArray(parsed.devices)) {
      this.log('devices.json has no devices array; ignoring');
      this.loaded = true;
      return this;
    }
    for (const raw of parsed.devices) {
      if (typeof raw?.deviceId !== 'string' || typeof raw?.publicKey !== 'string') continue;
      const device = {
        deviceId: raw.deviceId,
        name: typeof raw.name === 'string' ? raw.name : 'iOS device',
        publicKey: raw.publicKey,
        keyId: typeof raw.keyId === 'string' ? raw.keyId : keyPin(Buffer.from(raw.publicKey, 'base64url')),
        platform: typeof raw.platform === 'string' ? raw.platform : undefined,
        credentialHash: typeof raw.credentialHash === 'string' ? raw.credentialHash : undefined,
        createdAt: Number.isFinite(raw.createdAt) ? raw.createdAt : Date.now(),
        lastSeenAt: Number.isFinite(raw.lastSeenAt) ? raw.lastSeenAt : Date.now(),
        lastIp: typeof raw.lastIp === 'string' ? raw.lastIp : undefined,
        revokedAt: Number.isFinite(raw.revokedAt) ? raw.revokedAt : undefined,
        revokedReason: typeof raw.revokedReason === 'string' ? raw.revokedReason : undefined,
        pushToken: typeof raw.pushToken === 'string' ? raw.pushToken : undefined,
        pushEnvironment: typeof raw.pushEnvironment === 'string' ? raw.pushEnvironment : undefined,
      };
      this.devices.set(device.deviceId, device);
    }
    this.loaded = true;
    return this;
  }

  size() {
    return this.devices.size;
  }

  active() {
    return [...this.devices.values()].filter((device) => device.revokedAt === undefined);
  }

  get(deviceId) {
    return this.devices.get(deviceId);
  }

  /** Persist atomically (tmp + rename), never world-readable. */
  save() {
    mkdirSync(this.dir, { recursive: true });
    const payload = {
      version: 1,
      hostId: this.hostId,
      updatedAt: new Date().toISOString(),
      // Whitelist only: runtime fields (idleTimer/peer/downstream) must never
      // reach the file, and idleTimer is not even JSON-serializable.
      devices: [...this.devices.values()].map(toPersistedDevice),
    };
    const tmp = this.file + '.tmp-' + randomBytes(4).toString('hex');
    writeFileSync(tmp, JSON.stringify(payload, null, 2) + '\n', { mode: 0o600 });
    renameSync(tmp, this.file);
  }

  /**
   * Register a freshly paired device.
   * @param {{deviceId?: string, name: string, publicKey: Buffer, platform?: string, credential: string, ip?: string}} input
   */
  create({ deviceId = randomUUID(), name, publicKey, platform, credential, ip }) {
    const device = {
      deviceId,
      name,
      publicKey: publicKey.toString('base64url'),
      keyId: keyPin(publicKey),
      platform,
      credentialHash: sha256(credential),
      createdAt: Date.now(),
      lastSeenAt: Date.now(),
      lastIp: ip,
      revokedAt: undefined,
      revokedReason: undefined,
      pushToken: undefined,
      pushEnvironment: undefined,
    };
    this.devices.set(deviceId, device);
    this.save();
    return device;
  }

  /** Look up an active device by its long-term credential (compared by hash). */
  findByCredential(credential) {
    if (typeof credential !== 'string' || credential.length === 0) return undefined;
    const hash = sha256(credential);
    for (const device of this.devices.values()) {
      if (typeof device.credentialHash !== 'string') continue;
      const left = Buffer.from(device.credentialHash);
      const right = Buffer.from(hash);
      if (left.length === right.length && timingSafeEqual(left, right)) return device;
    }
    return undefined;
  }

  touch(device, ip) {
    device.lastSeenAt = Date.now();
    if (typeof ip === 'string' && ip.length > 0) device.lastIp = ip;
    this.save();
  }

  /** Remove a device record entirely (used when pairing cannot finish). */
  remove(deviceId) {
    const existed = this.devices.delete(deviceId);
    if (existed) this.save();
    return existed;
  }

  /** Mark one device revoked; returns the updated record or undefined. */
  revoke(deviceId, reason) {
    const device = this.devices.get(deviceId);
    if (device === undefined) return undefined;
    if (device.revokedAt !== undefined) return device;
    device.revokedAt = Date.now();
    device.revokedReason = reason;
    this.save();
    return device;
  }

  revokeAll(reason) {
    const revoked = [];
    for (const device of this.devices.values()) {
      if (device.revokedAt !== undefined) continue;
      device.revokedAt = Date.now();
      device.revokedReason = reason;
      revoked.push(device);
    }
    if (revoked.length > 0) this.save();
    return revoked;
  }

  /** Attach/remove the APNs device token for a paired phone. */
  setPushToken(deviceId, token, environment) {
    const device = this.devices.get(deviceId);
    if (device === undefined) return undefined;
    if (typeof token === 'string' && token.length > 0) {
      device.pushToken = token;
      device.pushEnvironment = environment;
    } else {
      device.pushToken = undefined;
      device.pushEnvironment = undefined;
    }
    this.save();
    return device;
  }

  /** Public projection for the admin UI (never exposes credential hashes). */
  publicList() {
    return [...this.devices.values()].map((device) => ({
      deviceId: device.deviceId,
      name: device.name,
      platform: device.platform,
      keyId: device.keyId,
      createdAt: device.createdAt,
      lastSeenAt: device.lastSeenAt,
      lastIp: device.lastIp,
      revoked: device.revokedAt !== undefined,
      revokedAt: device.revokedAt,
      revokedReason: device.revokedReason,
      hasPushToken: device.pushToken !== undefined,
      // Only a short fingerprint ever leaves the store; the raw APNs token is
      // needed for delivery and stays in devices.json (0600) alone.
      pushTokenFingerprint: device.pushToken === undefined ? undefined : createHash('sha256').update(device.pushToken).digest('hex').slice(0, 10),
    }));
  }
}