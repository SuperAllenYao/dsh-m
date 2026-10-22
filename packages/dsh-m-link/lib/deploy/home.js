/**
 * home.js — resolve the DSH home directory the same way the host plugin does.
 *
 * `lib/link-server.js` resolves the data dir from `ctx.get('dshHomePath')` with
 * a `DSH_HOME` env fallback. This module keeps the deploy engine independent of
 * the (large) link-server module while matching those semantics, so both end up
 * at the same `plugin-data/dsh-m-link` directory.
 */

import { homedir } from 'node:os';
import { join } from 'node:path';

export const PLUGIN_NAME = 'dsh-m-link';

/**
 * @param {{get?: (name: string) => unknown}} [ctx]
 * @param {Record<string, string | undefined>} [env]
 * @returns {string}
 */
export function resolveDshHome(ctx, env = process.env) {
  if (ctx !== undefined && typeof ctx?.get === 'function') {
    try {
      const provider = ctx.get('dshHomePath');
      if (typeof provider === 'function') {
        const value = provider();
        if (typeof value === 'string' && value.length > 0) return value;
      } else if (typeof provider === 'string' && provider.length > 0) {
        return provider;
      }
    } catch {
      /* service not available yet; fall through to env/home */
    }
  }
  const fromEnv = env.DSH_HOME;
  if (typeof fromEnv === 'string' && fromEnv.length > 0) return fromEnv;
  return join(homedir(), '.dsh');
}

/** Absolute plugin data dir (`<dshHome>/plugin-data/dsh-m-link`). */
export function resolveDataDir(ctx, env = process.env) {
  return join(resolveDshHome(ctx, env), 'plugin-data', PLUGIN_NAME);
}
