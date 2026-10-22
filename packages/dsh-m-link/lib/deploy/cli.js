/**
 * cli.js — headless runner for the one-click deploy engine.
 *
 * Purpose: run the SAME engine the settings card uses, without the desktop
 * plugin process. Used by the real-server acceptance script
 * and for manual debugging; it never
 * touches the live desktop plugin process.
 *
 * Usage:
 * node packages/dsh-m-link/lib/deploy/cli.js --input <json-file> [options]
 *
 * Input JSON (all fields except host/auth are optional):
 * {
 * "host": "relay.example.com", "sshPort": 22, "user": "root",
 * "auth": "key", "privateKeyFile": "<home>/.ssh/id_ed25519",
 * "controlPort": 0, "bridgeRange": "30000-30009", "installDir": "/usr/local/bin",
 * "forceReinstall": false, "acceptNewHostKey": false
 * }
 * Password auth reads the secret from the environment
 * `DSHM_DEPLOY_SSH_PASSWORD` (never argv/disk).
 *
 * Options:
 * --data-dir <dir> plugin data dir to write tunnel config into
 * (default: a temp dir, so an acceptance run leaves the
 * live desktop profile untouched)
 * --assets-dir <dir> relay asset dir override (default: package assets)
 * --yes auto-confirm the scanned host fingerprint (still scans
 * and records it; the interactive UI confirmation is
 * covered by the unit tests)
 * --dry-run read-only: SSH + fingerprint + preflight + plan, then
 * stop before uploading/installing anything
 * --verify <host:port:pin> only run the external healthz+TLS-pin check
 * --jsonout <path> write the final result JSON here (default stdout)
 * --quiet only errors on stderr
 *
 * Exit code: 0 success, 1 deploy failed, 2 usage/config error.
 */

import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { DeployEngine } from './engine.js';
import { loadAssets } from './assets.js';
import { externalSelfCheck } from './selfcheck.js';
import { applyPersistedTunnelConfig } from './tunnel-config.js';

function parseArgs(argv) {
  const options = { quiet: false, yes: false, verify: undefined, dataDir: undefined, assetsDir: undefined, input: undefined, jsonout: undefined };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--input') options.input = argv[++i];
    else if (arg === '--data-dir') options.dataDir = argv[++i];
    else if (arg === '--assets-dir') options.assetsDir = argv[++i];
    else if (arg === '--jsonout') options.jsonout = argv[++i];
    else if (arg === '--verify') options.verify = argv[++i];
    else if (arg === '--yes' || arg === '-y') options.yes = true;
    else if (arg === '--dry-run') options.dryRun = true;
    else if (arg === '--quiet') options.quiet = true;
    else if (arg === '--help' || arg === '-h') options.help = true;
    else {
      process.stderr.write('unknown argument: ' + arg + '\n');
      process.exit(2);
    }
  }
  return options;
}

function printHelp() {
  process.stderr.write(
    [
      'headless one-click relay deploy (M2b-1)',
      '  node lib/deploy/cli.js --input deploy.json [--dry-run] [--data-dir dir] [--assets-dir dir] [--yes] [--jsonout path]',
      '  node lib/deploy/cli.js --verify <host>:<port>:<pin>',
      '',
      'password auth: export DSHM_DEPLOY_SSH_PASSWORD=... (never passed in argv)',
      '',
    ].join('\n'),
  );
}

function readInput(options) {
  if (typeof options.input !== 'string') throw new Error('missing --input <json-file>');
  const raw = JSON.parse(readFileSync(options.input, 'utf8'));
  const input = { ...raw };
  if ((input.auth ?? 'key') === 'key' && typeof input.privateKeyFile === 'string') {
    input.privateKey = readFileSync(input.privateKeyFile, 'utf8');
  } else if ((input.auth ?? 'key') === 'password') {
    input.password = process.env.DSHM_DEPLOY_SSH_PASSWORD;
    if (typeof input.password !== 'string' || input.password.length === 0) throw new Error('password auth requires DSHM_DEPLOY_SSH_PASSWORD in the environment');
  }
  delete input.privateKeyFile;
  if (options.dryRun === true) input.dryRun = true;
  return input;
}

async function waitForCompletion(engine, deployId, { quiet, yes }) {
  let cursor = 0;
  let prompted = false;
  const startedAt = Date.now();
  while (true) {
    if (Date.now() - startedAt > 10 * 60 * 1000) throw new Error('deploy timed out (10 minutes)');
    const snapshot = engine.status({ deployId, since: cursor });
    for (const entry of snapshot.logs ?? []) {
      if (entry.level === 'debug' && quiet) continue;
      process.stderr.write('[' + entry.level + '] ' + entry.text + '\n');
    }
    cursor = snapshot.cursor ?? cursor;
    if (snapshot.prompt?.kind === 'host-fingerprint' && prompted === false) {
      prompted = true;
      process.stderr.write('\n[deploy] 服务器主机指纹: ' + String(snapshot.prompt.fingerprint) + ' (' + String(snapshot.prompt.keyType) + ')\n');
      if (yes !== true) {
        process.stderr.write('[deploy] 需要确认指纹：重新运行时加 --yes 自动确认（或使用桌面 UI 卡片交互）\n');
        engine.cancel({ deployId });
      } else {
        const result = engine.confirm({ deployId, fingerprint: snapshot.prompt.fingerprint, acceptNew: snapshot.prompt.mismatch === true });
        if (result.ok !== true) throw new Error('confirm failed: ' + String(result.message ?? result.error));
        process.stderr.write('[deploy] 已确认主机指纹\n');
      }
    }
    if (snapshot.active !== true) return snapshot;
    await new Promise((done) => setTimeout(done, 250));
  }
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help === true) {
    printHelp();
    return 0;
  }
  if (typeof options.verify === 'string') {
    const match = options.verify.match(/^([^:]+):(\d+):([A-Za-z0-9_-]+)$/u);
    if (match === null) throw new Error('--verify expects host:port:pin');
    const check = await externalSelfCheck({ host: match[1], port: Number(match[2]), pin: match[3], timeoutMs: 10_000 });
    const output = JSON.stringify({ ok: check.ok === true, pin: check.pin, health: check.health, error: check.error?.toJSON?.() ?? check.error }, null, 2);
    if (typeof options.jsonout === 'string') writeFileSync(options.jsonout, output + '\n', { mode: 0o600 });
    else process.stdout.write(output + '\n');
    return check.ok === true ? 0 : 1;
  }
  const dataDir = options.dataDir ?? mkdtempSync(join(tmpdir(), 'dshm-deploy-cli-'));
  const assets = options.assetsDir === undefined ? loadAssets() : loadAssets({ assetsDir: options.assetsDir });
  const engine = new DeployEngine({
    dataDir,
    assets,
    log: (level, text) => {
      if (options.quiet === true && level !== 'error') return;
      process.stderr.write('[engine] ' + text + '\n');
    },
  });
  const input = readInput(options);
  const start = engine.start(input);
  if (start.ok !== true) {
    process.stderr.write('deploy start failed: ' + String(start.message ?? start.error) + '\n');
    return 1;
  }
  const deployId = start.data.deployId;
  const snapshot = await waitForCompletion(engine, deployId, { quiet: options.quiet, yes: options.yes });
  const persistedTunnel = applyPersistedTunnelConfig({}, { dataDir });
  const output = {
    ok: snapshot.state === 'done',
    deployId,
    state: snapshot.state,
    dataDir,
    error: snapshot.error,
    rollback: snapshot.rollback,
    steps: snapshot.steps,
    result: snapshot.result,
 // Prove the persisted config activates the tunnel on the next plugin load
 // without leaking the secret (secretFile path only).
    persistedTunnel: persistedTunnel.tunnel === undefined ? undefined : { enabled: persistedTunnel.tunnel.enabled, controlOrigin: persistedTunnel.tunnel.controlOrigin, pin: persistedTunnel.tunnel.pin, secretFile: persistedTunnel.tunnel.secretFile },
  };
  const json = JSON.stringify(output, null, 2);
  if (typeof options.jsonout === 'string') writeFileSync(options.jsonout, json + '\n', { mode: 0o600 });
  else process.stdout.write(json + '\n');
  return snapshot.state === 'done' ? 0 : 1;
}

main()
  .then((code) => process.exit(code))
  .catch((error) => {
    process.stderr.write('deploy-cli error: ' + String(error?.stack ?? error) + '\n');
    process.exit(1);
  });
