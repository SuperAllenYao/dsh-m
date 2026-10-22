/**
 * tunnel-config.js — persist the deployed relay into the Mac-side plugin config.
 *
 * The deploy engine finishes by writing the same tunnel settings that a manual
 * `relay init` + `cordis.patch.yml` edit would produce (m2b-plan §2.2 step 5):
 *
 * <plugin-data>/dsh-m-link/tunnel.secret 0600 relay HMAC secret
 * <plugin-data>/dsh-m-link/deploy/tunnel.json 0600 tunnel {enabled,controlOrigin,pin}
 *
 * `lib/index.js` merges this persisted file into the plugin config at load time
 * (explicit profile `tunnel.*` settings always win), so activating a fresh
 * deployment needs a plugin reload / DSH restart — never a hot edit of a live
 * plugin context.
 *
 * Writing the profile's cordis.patch.yml automatically is deliberately NOT done:
 * editing it live triggers an in-place plugin reload (HMR) which the project
 * rules forbid for the in-use desktop plugin. The UI shows the exact snippet to
 * paste instead, and the reload/restart window is coordinated with the Lead.
 */

import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

export const TUNNEL_STATE_VERSION = 1;

/** @param {{dataDir: string}} options */
export function tunnelPaths({ dataDir }) {
  return {
    deployDir: join(dataDir, 'deploy'),
    tunnelStateFile: join(dataDir, 'deploy', 'tunnel.json'),
    secretFile: join(dataDir, 'tunnel.secret'),
    knownHostsFile: join(dataDir, 'deploy', 'known_hosts'),
    lastDeployFile: join(dataDir, 'deploy', 'last-deploy.json'),
    workDir: join(dataDir, 'deploy', 'work'),
  };
}

/** Atomic write with an explicit mode (0600 by default for config/secrets). */
export function writeFileAtomic(path, content, mode = 0o600) {
  mkdirSync(join(path, '..'), { recursive: true, mode: 0o700 });
  const tmp = path + '.tmp-' + String(process.pid) + '-' + String(Date.now());
  writeFileSync(tmp, content, { mode });
  try {
    chmodSync(tmp, mode);
  } catch {
 /* best effort (umask on some FS) */
  }
  renameSync(tmp, path);
  try {
    chmodSync(path, mode);
  } catch {
 /* best effort */
  }
}

/**
 * Persist the freshly deployed relay configuration.
 *
 * @param {{
 * dataDir: string,
 * controlOrigin: string,
 * pin: string,
 * secret: string,
 * publicHost: string,
 * controlPort: number,
 * bridgePorts?: string,
 * appConfig?: string,
 * relayVersion?: string,
 * mode?: 'fresh'|'upgrade',
 * deployedAt?: string,
 * }} input
 * @returns {{tunnelStateFile: string, secretFile: string, state: Record<string, unknown>}}
 */
export function writeTunnelState(input) {
  const paths = tunnelPaths({ dataDir: input.dataDir });
  if (typeof input.secret !== 'string' || input.secret.length < 16) {
    throw new Error('refusing to persist an empty/too-short relay secret');
  }
  const state = {
    version: TUNNEL_STATE_VERSION,
    enabled: true,
    controlOrigin: input.controlOrigin,
    pin: input.pin,
    secretFile: paths.secretFile,
    publicHost: input.publicHost,
    controlPort: input.controlPort,
    ...(input.bridgePorts === undefined ? {} : { bridgePorts: input.bridgePorts }),
    ...(input.appConfig === undefined ? {} : { appConfig: input.appConfig }),
    ...(input.relayVersion === undefined ? {} : { relayVersion: input.relayVersion }),
    mode: input.mode ?? 'fresh',
    deployedAt: input.deployedAt ?? new Date().toISOString(),
  };
  writeFileAtomic(paths.secretFile, input.secret.trim() + '\n', 0o600);
  writeFileAtomic(paths.tunnelStateFile, JSON.stringify(state, null, 2) + '\n', 0o600);
  return { tunnelStateFile: paths.tunnelStateFile, secretFile: paths.secretFile, state };
}

/**
 * Read the persisted tunnel state.
 * @param {{dataDir: string}} options
 * @returns {{ok: boolean, state?: Record<string, any>, path: string, error?: string}}
 */
export function readTunnelState({ dataDir }) {
  const paths = tunnelPaths({ dataDir });
  if (!existsSync(paths.tunnelStateFile)) return { ok: false, path: paths.tunnelStateFile };
  try {
    const parsed = JSON.parse(readFileSync(paths.tunnelStateFile, 'utf8'));
    if (parsed === null || typeof parsed !== 'object' || parsed.version !== TUNNEL_STATE_VERSION) {
      return { ok: false, path: paths.tunnelStateFile, error: 'unsupported tunnel state version' };
    }
    return { ok: true, state: parsed, path: paths.tunnelStateFile };
  } catch (error) {
    return { ok: false, path: paths.tunnelStateFile, error: String(error?.message ?? error) };
  }
}

/**
 * Merge persisted tunnel settings into the plugin config for `new LinkServer()`.
 *
 * Explicit profile config wins: if the user already has `tunnel.enabled: true`
 * in `cordis.patch.yml`, this function is a no-op (byte-for-byte M1/M2a
 * behaviour). Otherwise a successfully deployed relay is activated on the next
 * plugin load.
 *
 * @param {Record<string, any>} rawConfig the config passed to `apply(ctx, config)`
 * @param {{dataDir?: string}} options
 * @returns {Record<string, any>}
 */
export function applyPersistedTunnelConfig(rawConfig, options = {}) {
  const base = rawConfig !== null && typeof rawConfig === 'object' ? rawConfig : {};
  const explicitTunnel = base.tunnel;
  if (explicitTunnel !== null && typeof explicitTunnel === 'object' && explicitTunnel.enabled === true) return base;
  const dataDir = options.dataDir;
  if (typeof dataDir !== 'string' || dataDir.length === 0) return base;
  const persisted = readTunnelState({ dataDir });
  if (persisted.ok !== true || persisted.state === undefined) return base;
  const state = persisted.state;
  if (typeof state.controlOrigin !== 'string' || state.controlOrigin.length === 0) return base;
  if (typeof state.pin !== 'string' || state.pin.length === 0) return base;
  const secretFile = typeof state.secretFile === 'string' && state.secretFile.length > 0 ? state.secretFile : tunnelPaths({ dataDir }).secretFile;
  return {
    ...base,
    tunnel: {
      ...(explicitTunnel !== null && typeof explicitTunnel === 'object' ? explicitTunnel : {}),
      enabled: true,
      controlOrigin: state.controlOrigin,
      pin: state.pin,
      secretFile,
      ...(Number.isInteger(state.wantPort) && state.wantPort > 0 ? { wantPort: state.wantPort } : {}),
    },
  };
}

/**
 * YAML snippet for users who prefer to keep the config in the profile patch
 * file (the UI offers it as copy-paste; the engine does not edit the profile).
 * @param {{dataDir: string, controlOrigin: string, pin: string, secretFile?: string}} options
 */
export function buildProfileSnippet({ dataDir, controlOrigin, pin, secretFile }) {
  const file = secretFile ?? tunnelPaths({ dataDir }).secretFile;
  return [
    '        tunnel:',
    '          enabled: true',
    '          controlOrigin: "' + controlOrigin + '"',
    '          pin: "' + pin + '"',
    '          secretFile: ' + file,
    '',
  ].join('\n');
}

/** Remove persisted tunnel config (uninstall path; other plugin data untouched). */
export function clearTunnelState({ dataDir }) {
  const paths = tunnelPaths({ dataDir });
  for (const path of [paths.secretFile, paths.tunnelStateFile]) {
    try {
      rmSync(path, { force: true });
    } catch {
 /* best effort */
    }
  }
}
