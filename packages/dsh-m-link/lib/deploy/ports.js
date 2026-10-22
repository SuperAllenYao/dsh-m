/**
 * ports.js — control/bridge port selection for the one-click deploy.
 *
 * Rules (m2b-plan §2.2):
 *   - control port prefers 443 (best: no port in App config, cleanest firewall
 *     story), then 8443, 9443, then a deterministic-from-seed random high port;
 *   - the bridge pool is a contiguous TCP range the relay binds per host. We
 *     only pick a range whose every port is free, and never overlap the control
 *     port;
 *   - an existing relay config is reused as-is (upgrade must not move ports).
 *
 * All functions are pure and seedable so the fake-SSH unit tests are stable.
 */

export const DEFAULT_BRIDGE_RANGE_SIZE = 10;
export const CONTROL_PORT_CANDIDATES = [443, 8443, 9443];
export const BRIDGE_RANGE_CANDIDATES = [
  { start: 30000, end: 30009 },
  { start: 40000, end: 40009 },
  { start: 50000, end: 50009 },
  { start: 45000, end: 45009 },
];
/** Never auto-select these (well-known service ports) as a random fallback. */
export const RESERVED_PORTS = new Set([22, 53, 80, 123, 443, 3306, 5432, 6379, 8080, 8443, 9443, 27017]);

/** Deterministic PRNG (mulberry32) so tests can fix the fallback choice. */
export function createRng(seed = 1) {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/**
 * Parse `ss -lnt` / `ss -lntp` / `netstat -lnt` output into a set of listening
 * TCP ports. Handles `0.0.0.0:443`, `*:443`, `[::]:443`, `127.0.0.1:30000`,
 * `[::1]:53%lo` (scope suffix stripped), and the `LISTEN 0 128 ...` prefix.
 *
 * @param {string} output
 * @returns {Set<number>}
 */
export function parseListeningPorts(output) {
  /** @type {Set<number>} */
  const ports = new Set();
  for (const rawLine of String(output ?? '').split(/\r?\n/)) {
    const line = rawLine.trim();
    if (line.length === 0) continue;
    // `ss -H` output starts with the address; full `ss -lnt` has a State column.
    const withoutState = line.startsWith('LISTEN') ? line.replace(/^LISTEN\s+\S+\s+\S+\s+/u, '') : line;
    const address = withoutState.split(/\s+/u)[0];
    if (typeof address !== 'string' || address.length === 0) continue;
    const match = address.match(/:(\d{1,5})(?:%[\w.-]+)?$/u);
    if (match === null) continue;
    const port = Number(match[1]);
    if (port >= 1 && port <= 65535) ports.add(port);
  }
  return ports;
}

/** True when any port in [start, end] is in `occupied`. */
export function rangeOverlaps(occupied, start, end) {
  for (let port = start; port <= end; port += 1) {
    if (occupied.has(port)) return true;
  }
  return false;
}

/**
 * Pick a control port.
 *
 * @param {Set<number>} occupied
 * @param {{preferred?: number, rng?: () => number, attempts?: number}} [options]
 * @returns {number|undefined} undefined when no candidate is available
 */
export function pickControlPort(occupied, options = {}) {
  const rng = options.rng ?? createRng(1);
  if (Number.isInteger(options.preferred) && options.preferred > 0 && options.preferred < 65536) {
    return occupied.has(options.preferred) ? undefined : options.preferred;
  }
  for (const candidate of CONTROL_PORT_CANDIDATES) {
    if (!occupied.has(candidate)) return candidate;
  }
  const attempts = options.attempts ?? 40;
  for (let i = 0; i < attempts; i += 1) {
    const candidate = 20000 + Math.floor(rng() * 40000);
    if (candidate > 65535) continue;
    if (RESERVED_PORTS.has(candidate)) continue;
    if (!occupied.has(candidate)) return candidate;
  }
  return undefined;
}

/**
 * Pick a bridge port range.
 *
 * @param {Set<number>} occupied
 * @param {{start?: number, end?: number, size?: number, controlPort?: number, rng?: () => number, attempts?: number}} [options]
 * @returns {{start: number, end: number}|undefined}
 */
export function pickBridgeRange(occupied, options = {}) {
  const size = Number.isInteger(options.size) && options.size > 0 ? options.size : DEFAULT_BRIDGE_RANGE_SIZE;
  const blocked = new Set(occupied);
  if (Number.isInteger(options.controlPort)) blocked.add(options.controlPort);
  if (Number.isInteger(options.start) && Number.isInteger(options.end) && options.start >= 1 && options.end <= 65535 && options.start <= options.end) {
    if (rangeOverlaps(blocked, options.start, options.end)) return undefined;
    return { start: options.start, end: options.end };
  }
  for (const candidate of BRIDGE_RANGE_CANDIDATES) {
    if (!rangeOverlaps(blocked, candidate.start, candidate.end)) return { ...candidate };
  }
  const rng = options.rng ?? createRng(7);
  const attempts = options.attempts ?? 40;
  for (let i = 0; i < attempts; i += 1) {
    // Align to 100-port boundaries so the range looks deliberate in the firewall UI.
    const start = 20000 + Math.floor(rng() * 300) * 100;
    const end = start + size - 1;
    if (end > 65535) continue;
    if (rangeOverlaps(blocked, start, end)) continue;
    return { start, end };
  }
  return undefined;
}

/**
 * Parse a `start-end` string (advanced UI field).
 * @param {string} value
 * @returns {{start: number, end: number}|undefined}
 */
export function parsePortRange(value) {
  if (typeof value !== 'string') return undefined;
  const match = value.trim().match(/^(\d{2,5})\s*-\s*(\d{2,5})$/u);
  if (match === null) return undefined;
  const start = Number(match[1]);
  const end = Number(match[2]);
  if (start < 1 || end > 65535 || start > end) return undefined;
  return { start, end };
}

/** Parse the `publicHost` field from a relay.yaml text. */
export function parsePublicHostFromConfig(configText) {
  const match = String(configText ?? '').match(/^\s*publicHost:\s*"?([^"\n]+)"?\s*$/mu);
  return match === null ? undefined : match[1].trim();
}

/** Parse the `bridgePorts: [30000, 30009]` field from a relay.yaml text. */
export function parseBridgeRangeFromConfig(configText) {
  const match = String(configText ?? '').match(/^\s*bridgePorts:\s*\[\s*(\d{2,5})\s*,\s*(\d{2,5})\s*\]/mu);
  if (match === null) return undefined;
  const start = Number(match[1]);
  const end = Number(match[2]);
  if (start < 1 || end > 65535 || start > end) return undefined;
  return { start, end };
}

/** Parse the control port from a relay.yaml `listen: "0.0.0.0:443"` line. */
export function parseControlPortFromListen(listenValue) {
  const match = String(listenValue ?? '').match(/:(\d{1,5})$/u);
  if (match === null) return undefined;
  const port = Number(match[1]);
  return port >= 1 && port <= 65535 ? port : undefined;
}
