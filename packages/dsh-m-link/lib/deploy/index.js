/**
 * deploy/index.js — public surface of the M2b-1 one-click relay deploy.
 *
 * Used by lib/index.js (route registration + persisted tunnel config merge) and
 * by test/m2b-deploy.mjs (headless
 * engine runs, which do not need the desktop plugin process).
 */

export { registerDeployRoute, DEPLOY_ADMIN_PATH } from './admin.js';
export { DeployEngine, normalizeInput, normalizeHostInput, publicInput, STEP_DEFINITIONS } from './engine.js';
export { loadAssets, DEFAULT_ASSETS_DIR, sha256File } from './assets.js';
export { CODES, DeployError, toDeployError } from './errors.js';
export { SecretMasker, maskText } from './mask.js';
export { applyPersistedTunnelConfig, buildProfileSnippet, clearTunnelState, readTunnelState, tunnelPaths, writeTunnelState } from './tunnel-config.js';
export { resolveDataDir, resolveDshHome } from './home.js';
export {
  assessPreflight,
  parseExistingRelayConfig,
  parsePreflightOutput,
  parseSnapshotOutput,
  PREFLIGHT_SCRIPT,
  SNAPSHOT_SCRIPT,
} from './preflight.js';
export { externalSelfCheck, probeHttpsHealthz, probeTcp, probeTlsPin, certPin } from './selfcheck.js';
export {
  buildRemoteLayout,
  cleanupRemoteTemp,
  diffSnapshots,
  pushBundle,
  rollbackFreshInstall,
  runRemoteInstaller,
} from './install.js';
export {
  buildScpArgs,
  buildSshArgs,
  classifyHostKey,
  createProcessRunner,
  forgetKnownHostKey,
  knownHostsHostPart,
  parseKeyscanOutput,
  parseKnownHosts,
  SshTransport,
  keyFingerprint,
  shellQuote,
} from './ssh.js';
