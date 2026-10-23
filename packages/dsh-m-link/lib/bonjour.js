/**
 * bonjour.js — zero-dependency mDNS responder for LAN discovery (M2a).
 *
 * Advertises the link server as `_dshm._tcp.local` on 224.0.0.251:5353 so the
 * phone can browse for Macs (NWBrowser already declares `_dshm._tcp` in
 * apps/ios/project.yml) and pair with an 8-digit code without typing an IP.
 *
 * Records (TTL 120s, per m2-tunnel-design §5.3):
 *
 * PTR _dshm._tcp.local -> <hostName>-<hostId[0:8]>._dshm._tcp.local
 * SRV <instance> -> 0 0 <link port> <hostId[0:8]>.local
 * TXT <instance> -> v=1 hostId=.. hostName=.. proto=dsh-m/1
 * ver=.. pair=code [relay=<origin>]
 * A <hostId[0:8]>.local -> every non-loopback IPv4 address
 *
 * Security: `pair` is a **capability marker** (fixed `code`), never the current
 * 8-digit pairing code — broadcasting the code on mDNS would give anyone on the
 * LAN the "2-minute / 5-attempt / single-use / desktop-only" secret. TXT never
 * carries pins, tokens or secrets; relay is a public origin (not a secret).
 * Code changes therefore never touch the TXT record.
 *
 * Implementation notes:
 * - node:dgram only, no npm dependency, no mDNS library.
 * - No `_services._dns-sd._udp.local` meta-query support beyond a PTR answer
 * (NWBrowser queries the concrete service type).
 * - Every socket operation is best effort: a failure is logged / reported via
 * `onError` and never throws into plugin start (design §5.3: 失败只记
 * audit/log，不影响插件启动).
 * - `socketFactory` is injectable so the protocol/packet code can be unit
 * tested without touching the host's multicast sockets.
 */

import { createSocket } from 'node:dgram';

export const MDNS_ADDRESS = '224.0.0.251';
export const MDNS_PORT = 5353;
export const SERVICE_TYPE = '_dshm._tcp.local';
export const SERVICE_ENUM = '_services._dns-sd._udp.local';
export const DEFAULT_TTL_SECONDS = 120;

/**
 * TXT field whitelist. Security invariant: the record is a LAN-wide broadcast,
 * so it may only carry discovery metadata — never the pairing code value, pins,
 * tokens or secrets. `pair` is a capability marker (`code`/`1`), not a secret.
 */
export const TXT_KEYS = ['v', 'hostId', 'hostName', 'proto', 'ver', 'pair', 'relay'];
const PAIR_CAPABILITY_MARKERS = new Set(['code', '1']);

/** Drop anything outside the TXT whitelist; force `pair` to a capability marker. */
export function sanitizeTxt(pairs = {}) {
  const out = {};
  for (const key of TXT_KEYS) {
    const value = pairs[key];
    if (value === undefined || value === null) continue;
    const text = String(value);
    if (key === 'pair' && !PAIR_CAPABILITY_MARKERS.has(text)) continue;
    out[key] = text.slice(0, 255);
  }
  return out;
}

const DNS_TYPE = { A: 1, PTR: 12, TXT: 16, SRV: 33, ANY: 255 };
const DNS_CLASS_IN = 1;
const CACHE_FLUSH = 0x8000;
const MDNS_RESPONSE_FLAGS = 0x8400; // QR=1, AA=1
const MAX_PACKET = 9000;

/** DNS label-safe ASCII form of a display name (mDNS labels are bytes, but the
 * iOS browser and the macOS responder are happiest with ASCII). */
export function sanitizeLabel(value, fallback = 'dshm-mac', maxLength = 40) {
  const cleaned = String(value ?? '')
    .replace(/\.local\.?$/i, '')
    .replace(/[^A-Za-z0-9-]+/g, '-')
    .replace(/-+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, maxLength);
  return cleaned.length > 0 ? cleaned : fallback;
}

/** DNS wire name -> Buffer (labels, length-prefixed, terminated by 0). */
export function encodeName(name) {
  const labels = String(name).replace(/\.$/, '').split('.').filter((label) => label.length > 0);
  const parts = [];
  let total = 1;
  for (const label of labels) {
    const bytes = Buffer.from(label, 'utf8');
    if (bytes.length === 0 || bytes.length > 63) throw new Error('invalid DNS label: ' + label);
    total += bytes.length + 1;
    if (total > 255) throw new Error('DNS name too long: ' + name);
    parts.push(Buffer.from([bytes.length]), bytes);
  }
  parts.push(Buffer.from([0]));
  return Buffer.concat(parts);
}

/** Read a (possibly compressed) DNS name; returns {name, next}. */
export function readName(buffer, offset) {
  const labels = [];
  let cursor = offset;
  let next = undefined;
  let hops = 0;
  for (;;) {
    if (cursor >= buffer.length) throw new Error('truncated DNS name');
    const length = buffer[cursor];
    if (length === 0) {
      cursor += 1;
      if (next === undefined) next = cursor;
      break;
    }
    if ((length & 0xc0) === 0xc0) {
      if (cursor + 1 >= buffer.length) throw new Error('truncated DNS pointer');
      const pointer = ((length & 0x3f) << 8) | buffer[cursor + 1];
      if (next === undefined) next = cursor + 2;
      if (pointer >= cursor) throw new Error('DNS pointer loop');
      hops += 1;
      if (hops > 32) throw new Error('DNS pointer loop');
      cursor = pointer;
      continue;
    }
    if (cursor + 1 + length > buffer.length) throw new Error('truncated DNS label');
    labels.push(buffer.subarray(cursor + 1, cursor + 1 + length).toString('utf8'));
    cursor += 1 + length;
  }
  return { name: labels.join('.'), next };
}

/** Parse a DNS query packet into {id, flags, questions}. Throws on malformed input. */
export function parseQuestions(buffer) {
  if (buffer.length < 12) throw new Error('DNS packet too short');
  const id = buffer.readUInt16BE(0);
  const flags = buffer.readUInt16BE(2);
  const qdcount = buffer.readUInt16BE(4);
  const questions = [];
  let offset = 12;
  for (let index = 0; index < qdcount; index += 1) {
    const { name, next } = readName(buffer, offset);
    if (next + 4 > buffer.length) throw new Error('truncated DNS question');
    const type = buffer.readUInt16BE(next);
    const klass = buffer.readUInt16BE(next + 2) & 0x7fff;
    offset = next + 4;
    questions.push({ name: name.replace(/\.$/, ''), type, class: klass });
  }
  return { id, flags, questions };
}

function encodeTxt(pairs) {
  const strings = [];
  for (const [key, value] of Object.entries(pairs)) {
    if (value === undefined || value === null) continue;
    let bytes = Buffer.from(String(key) + '=' + String(value), 'utf8');
    if (bytes.length > 255) bytes = bytes.subarray(0, 255);
    strings.push(Buffer.from([bytes.length]), bytes);
  }
  return Buffer.concat(strings);
}

function buildRecord({ name, type, klass = DNS_CLASS_IN, ttl, rdata }) {
  const nameBytes = encodeName(name);
  const header = Buffer.alloc(10);
  header.writeUInt16BE(type, 0);
  header.writeUInt16BE(klass, 2);
  header.writeUInt32BE(ttl >>> 0, 4);
  header.writeUInt16BE(rdata.length, 8);
  return Buffer.concat([nameBytes, header, rdata]);
}

/** Build a DNS response packet (questions are never echoed; answers only). */
export function buildPacket(answers) {
  const header = Buffer.alloc(12);
  header.writeUInt16BE(0, 0); // mDNS uses ID 0
  header.writeUInt16BE(MDNS_RESPONSE_FLAGS, 2);
  header.writeUInt16BE(0, 4); // qdcount
  header.writeUInt16BE(answers.length, 6);
  header.writeUInt16BE(0, 8); // nscount
  header.writeUInt16BE(0, 10); // arcount
  const packet = Buffer.concat([header, ...answers]);
  if (packet.length > MAX_PACKET) throw new Error('mDNS packet too large');
  return packet;
}

const srvRdata = (port, target) => {
  const fixed = Buffer.alloc(6);
  fixed.writeUInt16BE(0, 0); // priority
  fixed.writeUInt16BE(0, 2); // weight
  fixed.writeUInt16BE(port & 0xffff, 4);
  return Buffer.concat([fixed, encodeName(target)]);
};

const aRdata = (ip) => {
  const parts = ip.split('.').map((part) => Number(part));
  if (parts.length !== 4 || parts.some((part) => !Number.isInteger(part) || part < 0 || part > 255)) {
    throw new Error('not an IPv4 address: ' + ip);
  }
  return Buffer.from(parts);
};

/**
 * mDNS responder for one link-server instance.
 *
 * The constructor does not touch the network; call start(). update() refreshes
 * the TXT record (new pairing code / relay origin) and re-announces.
 */
export class BonjourResponder {
 /**
 * @param {{
 * hostId: string,
 * hostName: string,
 * port: number,
 * addresses: string[],
 * txt?: Record<string, string|undefined>,
 * ttlSeconds?: number,
 * log?: (message: string) => void,
 * onError?: (error: Error) => void,
 * socketFactory?: (options: {type: string, reuseAddr: boolean}) => object,
 * }} options
 */
  constructor({ hostId, hostName, port, addresses, txt = {}, ttlSeconds = DEFAULT_TTL_SECONDS, log = () => {}, onError = () => {}, socketFactory = (options) => createSocket(options) }) {
    this.hostId = String(hostId ?? '');
    this.hostName = String(hostName ?? '');
    this.port = Number(port);
    this.addresses = (Array.isArray(addresses) ? addresses : []).filter((ip) => /^\d{1,3}(\.\d{1,3}){3}$/.test(ip));
    this.baseTxt = sanitizeTxt(txt);
    this.ttlSeconds = ttlSeconds;
    this.log = log;
    this.onError = onError;
    this.socketFactory = socketFactory;
    this.socket = undefined;
    this.started = false;
    this.failed = false;
    this.announceTimers = new Set();
    const hostSuffix = this.hostId.slice(0, 8) || 'unknown';
    this.instanceName = sanitizeLabel(this.hostName + '-' + hostSuffix, 'dshm-' + hostSuffix, 63);
    this.targetName = 'dshm-' + sanitizeLabel(hostSuffix, 'mac', 24);
  }

  get instanceFqdn() {
    return this.instanceName + '.' + SERVICE_TYPE;
  }

  get targetFqdn() {
    return this.targetName + '.local';
  }

 /** Current TXT values (pair / relay are refreshed by update()). */
  txtValues() {
    return { ...this.baseTxt };
  }

 /** How the record set looks right now (tests + logs; no secrets beyond the code). */
  descriptor() {
    return {
      service: SERVICE_TYPE,
      instance: this.instanceFqdn,
      target: this.targetFqdn,
      port: this.port,
      addresses: [...this.addresses],
      txt: this.txtValues(),
      ttlSeconds: this.ttlSeconds,
    };
  }

  buildAnswers({ ttl = this.ttlSeconds, includeMeta = true } = {}) {
    const answers = [];
    if (includeMeta) {
      answers.push(buildRecord({ name: SERVICE_ENUM, type: DNS_TYPE.PTR, ttl, rdata: encodeName(SERVICE_TYPE) }));
    }
    answers.push(buildRecord({ name: SERVICE_TYPE, type: DNS_TYPE.PTR, ttl, rdata: encodeName(this.instanceFqdn) }));
    answers.push(buildRecord({ name: this.instanceFqdn, type: DNS_TYPE.SRV, klass: DNS_CLASS_IN | CACHE_FLUSH, ttl, rdata: srvRdata(this.port, this.targetFqdn) }));
    answers.push(buildRecord({ name: this.instanceFqdn, type: DNS_TYPE.TXT, klass: DNS_CLASS_IN | CACHE_FLUSH, ttl, rdata: encodeTxt(this.txtValues()) }));
    for (const ip of this.addresses) {
      try {
        answers.push(buildRecord({ name: this.targetFqdn, type: DNS_TYPE.A, klass: DNS_CLASS_IN | CACHE_FLUSH, ttl, rdata: aRdata(ip) }));
      } catch (error) {
        this.log('bonjour: skipping bad address ' + ip + ': ' + String(error?.message ?? error));
      }
    }
    return answers;
  }

  buildAnnouncement({ ttl = this.ttlSeconds } = {}) {
    return buildPacket(this.buildAnswers({ ttl }));
  }

  buildGoodbye() {
    return buildPacket(this.buildAnswers({ ttl: 0 }));
  }

 /** Start listening/announcing. Never throws; returns {ok, error?}. */
  start() {
    if (this.started || this.failed) return { ok: this.started, error: this.failed ? this.failureReason : undefined };
    try {
      this.socket = this.socketFactory({ type: 'udp4', reuseAddr: true });
      this.socket.on('error', (error) => this.fail(error));
      this.socket.on('message', (message) => this.handleMessage(message));
      this.socket.bind(MDNS_PORT, '0.0.0.0', () => this.onBound());
      return { ok: true };
    } catch (error) {
      this.fail(error);
      return { ok: false, error: this.failureReason };
    }
  }

  onBound() {
    if (this.failed) return;
    try {
      this.socket.setMulticastTTL(255);
    } catch {
 /* not essential */
    }
    try {
      this.socket.setMulticastLoopback(true);
    } catch {
 /* not essential */
    }
    try {
      this.socket.addMembership(MDNS_ADDRESS);
    } catch (error) {
 // Some hosts/VPNs refuse multicast membership; the responder then only
 // sees unicast mDNS probes. Not fatal (design §5.3).
      this.log('bonjour: addMembership failed (continuing): ' + String(error?.message ?? error));
    }
    this.started = true;
    this.announce();
    this.scheduleAnnounce(1000);
    this.log('bonjour: advertising ' + this.instanceFqdn + ' on port ' + String(this.port) + ' (' + this.addresses.join(', ') + ')');
  }

  announce() {
    this.send(this.buildAnnouncement());
  }

  scheduleAnnounce(delayMs) {
    const timer = setTimeout(() => {
      this.announceTimers.delete(timer);
      if (this.started) this.announce();
    }, delayMs);
    if (typeof timer.unref === 'function') timer.unref();
    this.announceTimers.add(timer);
  }

  send(packet) {
    if (this.socket === undefined) return;
    try {
      this.socket.send(packet, 0, packet.length, MDNS_PORT, MDNS_ADDRESS, (error) => {
        if (error !== undefined && error !== null) this.log('bonjour: send failed: ' + String(error?.message ?? error));
      });
    } catch (error) {
      this.log('bonjour: send failed: ' + String(error?.message ?? error));
    }
  }

 /**
 * Refresh TXT values (relay origin appears after tunnel ready) and re-announce.
 *
 * real-device root-cause fix: `addresses` may also be refreshed here.
 * The responder used to capture the Mac's LAN IPs once at plugin start; after a
 * Wi-Fi/subnet change it kept answering A records for the stale addresses, so
 * the phone could never resolve/dial the Mac's *current* LAN origin and every
 * connection fell back to the relay (live evidence: 08:31+ LAN auths = 0).
 * `link-server.refreshLanEndpoints()` passes the freshly collected addresses.
 */
  update(partial = {}, options = {}) {
 // Sanitize the incoming patch before merging: callers may not widen the TXT
 // contract (an invalid/numeric `pair` value is silently ignored, keeping the
 // `pair=code` capability marker already in the record).
    this.baseTxt = { ...this.baseTxt, ...sanitizeTxt(partial) };
    if (Array.isArray(options.addresses)) {
      const next = [...new Set(options.addresses.filter(
        (ip) => typeof ip === 'string' && /^\d{1,3}(\.\d{1,3}){3}$/.test(ip)
      ))];
 // An empty set means "no non-loopback IPv4 right now" (Wi-Fi off). Keep the
 // previous answers rather than advertising nothing: the phone still has the
 // relay, and the next successful refresh replaces them.
      if (next.length > 0) this.addresses = next;
    }
    if (this.started) this.announce();
    return this.txtValues();
  }

  handleMessage(message) {
    if (!this.started || this.socket === undefined) return;
    let parsed;
    try {
      parsed = parseQuestions(message);
    } catch {
      return; // malformed/foreign packet: never crash the host
    }
    if ((parsed.flags & 0x8000) !== 0) return; // a response, not a query
    const questions = parsed.questions;
    if (questions.length === 0) return;
    let wantsPtr = false;
    let wantsSrvTxt = false;
    let wantsA = false;
    let wantsEnum = false;
    for (const question of questions) {
      const name = question.name.toLowerCase().replace(/\.$/, '');
      const any = question.type === DNS_TYPE.ANY || question.type === 0;
      if (name === SERVICE_TYPE.toLowerCase() && (any || question.type === DNS_TYPE.PTR)) wantsPtr = true;
      else if (name === SERVICE_ENUM.toLowerCase() && (any || question.type === DNS_TYPE.PTR)) wantsEnum = true;
      else if (name === this.instanceFqdn.toLowerCase() && (any || question.type === DNS_TYPE.SRV || question.type === DNS_TYPE.TXT)) wantsSrvTxt = true;
      else if (name === this.targetFqdn.toLowerCase() && (any || question.type === DNS_TYPE.A)) wantsA = true;
    }
    if (!wantsPtr && !wantsSrvTxt && !wantsA && !wantsEnum) return;
 // Answer with the full (small) record set for any of our names; mDNS clients
 // filter by their own question. This keeps the responder stateless and is
 // what makes a single PTR query resolve service -> SRV -> TXT -> A without
 // extra round trips on flaky Wi-Fi.
    this.send(buildPacket(this.buildAnswers()));
  }

  fail(error) {
    if (this.failed) return;
    this.failed = true;
    this.failureReason = String(error?.message ?? error);
    this.started = false;
    this.log('bonjour: disabled after error: ' + this.failureReason);
    try {
      this.onError?.(error instanceof Error ? error : new Error(this.failureReason));
    } catch {
 /* onError must not break teardown */
    }
    try {
      this.socket?.close?.();
    } catch {
 /* already closed */
    }
    this.socket = undefined;
  }

 /** Send goodbye (TTL=0) and close. Safe to call twice / before start. */
  close() {
    for (const timer of this.announceTimers) clearTimeout(timer);
    this.announceTimers.clear();
    if (this.started && this.socket !== undefined) {
      try {
        this.send(this.buildGoodbye());
      } catch (error) {
        this.log('bonjour: goodbye failed: ' + String(error?.message ?? error));
      }
    }
    this.started = false;
    this.failed = true;
    this.failureReason = this.failureReason ?? 'closed';
    const socket = this.socket;
    this.socket = undefined;
    if (socket !== undefined) {
      try {
 // Give the goodbye datagram a moment to leave before closing the socket.
        const timer = setTimeout(() => {
          try {
            socket.close?.();
          } catch {
 /* already closed */
          }
        }, 60);
        if (typeof timer.unref === 'function') timer.unref();
      } catch {
 /* best effort */
      }
    }
  }
}
