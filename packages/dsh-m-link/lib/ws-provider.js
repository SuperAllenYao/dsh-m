/**
 * ws-provider.js — locate a WebSocket implementation without declaring an npm
 * dependency (M0 spike convenience).
 *
 * Resolution order:
 *   1. bare "ws" (works when the plugin is installed through pnpm with its own
 *      dependency on ws — the production shape);
 *   2. the ws copy shipped inside the running DeepSeek Harness installation
 *      (process.resourcesPath/app.asar/dsh/node_modules/ws), which the DSH
 *      runtime process can import through Electron's asar support.
 *
 * If both fail the plugin reports a loud, explicit error instead of silently
 * degrading — M0 records this as a known packaging risk.
 */

import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

let cached;
let loadedFrom;

/** Candidate absolute paths to the ws entry inside a DSH installation. */
function installationCandidates() {
  const candidates = [];
  const resources = process.resourcesPath;
  if (typeof resources === 'string' && resources.length > 0) {
    candidates.push(join(resources, 'app.asar', 'dsh', 'node_modules', 'ws', 'index.js'));
    candidates.push(join(resources, 'app.asar.unpacked', 'dsh', 'node_modules', 'ws', 'index.js'));
  }
  const execPath = process.execPath;
  if (typeof execPath === 'string' && execPath.includes('.app/Contents/MacOS/')) {
    const contents = execPath.slice(0, execPath.indexOf('/MacOS/'));
    candidates.push(join(contents, 'Resources', 'app.asar', 'dsh', 'node_modules', 'ws', 'index.js'));
  }
  return candidates;
}

/**
 * Load the ws module (CJS exports the WebSocket class with WebSocketServer
 * attached). Returns the module namespace; read the class through
 * {@link wsClass} / {@link wsServerClass}.
 */
export async function loadWs() {
  if (cached !== undefined) return cached;
  const attempts = [];
  // Test/CI hook: a plain-Node unit test cannot resolve the DSH-shipped `ws`
  // (it lives inside Electron's asar). Point this at a module file when
  // exercising LinkServer outside the DSH runtime; production leaves it unset.
  const envPath = process.env.DSH_M_LINK_WS_PATH;
  if (typeof envPath === 'string' && envPath.length > 0) {
    try {
      cached = await import(pathToFileURL(envPath).href);
      loadedFrom = envPath;
      return cached;
    } catch (error) {
      attempts.push({ specifier: envPath, message: error.message });
    }
  }
  try {
    cached = await import('ws');
    loadedFrom = 'ws';
    return cached;
  } catch (error) {
    attempts.push({ specifier: 'ws', message: error.message });
  }
  for (const file of installationCandidates()) {
    try {
      cached = await import(pathToFileURL(file).href);
      loadedFrom = file;
      return cached;
    } catch (error) {
      attempts.push({ specifier: file, message: error.message });
    }
  }
  throw new Error(
    'dsh-m-link: cannot load the "ws" package. Install it as a plugin dependency ' +
      'or run inside a DeepSeek Harness installation. Attempts: ' +
      JSON.stringify(attempts),
  );
}

/** Where the active ws implementation came from (for the startup log). */
export function wsLoadedFrom() {
  return loadedFrom ?? 'unresolved';
}

/** Extract the WebSocket client/server constructors from a ws module namespace. */
export function wsBindings(mod) {
  const root = mod.default ?? mod;
  const WebSocket = root.WebSocket ?? root;
  const WebSocketServer = root.WebSocketServer ?? mod.WebSocketServer;
  if (typeof WebSocket !== 'function') throw new Error('dsh-m-link: ws has no WebSocket constructor');
  return { WebSocket, WebSocketServer };
}