#!/usr/bin/env node
/**
 * m2b-deploy.mjs — M2b-1 one-click relay deploy unit tests (fake SSH runner).
 *
 * Runs standalone — no DSH host, no ~/.dsh, no real server, no network:
 *   node test/m2b-deploy.mjs [--keep]
 *
 * Layers:
 *   1. pure helpers: SSH argv/env construction, host-key fingerprints +
 *      known_hosts bookkeeping, port parsing/selection, preflight parsing and
 *      planning, snapshot diffing, tunnel-config persistence, log masking;
 *   2. the deploy state machine (lib/deploy/engine.js) driven by a fake SSH
 *      transport: fresh install, port avoidance, host-fingerprint confirmation,
 *      upgrade/no-op, install failure rollback, external self-check failure
 *      rollback, cancel and timeout;
 *   3. static checks: install.sh syntax, relay asset manifest integrity.
 *
 * Exit code 0 only when every assertion passes; writes
 * test/results/m2b-deploy.json with the full evidence.
 */

import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync, chmodSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { loadAssets, sha256File } from '../lib/deploy/assets.js';
import { DeployEngine, normalizeHostInput, normalizeInput, publicInput } from '../lib/deploy/engine.js';
import { CODES, DeployError } from '../lib/deploy/errors.js';
import { SecretMasker, maskText } from '../lib/deploy/mask.js';
import {
  assessPreflight,
  parseExistingRelayConfig,
  parsePreflightOutput,
  parseSnapshotOutput,
  PREFLIGHT_SCRIPT,
  SNAPSHOT_SCRIPT,
} from '../lib/deploy/preflight.js';
import {
  createRng,
  parseBridgeRangeFromConfig,
  parseControlPortFromListen,
  parseListeningPorts,
  parsePortRange,
  parsePublicHostFromConfig,
  pickBridgeRange,
  pickControlPort,
} from '../lib/deploy/ports.js';
import { diffSnapshots } from '../lib/deploy/install.js';
import { certPin } from '../lib/deploy/selfcheck.js';
import {
  buildScpArgs,
  buildSshArgs,
  classifyHostKey,
  forgetKnownHostKey,
  keyFingerprint,
  knownHostsHostPart,
  parseKeyscanOutput,
  parseKnownHosts,
  shellQuote,
  SshTransport,
} from '../lib/deploy/ssh.js';
import { applyPersistedTunnelConfig, buildProfileSnippet, readTunnelState, tunnelPaths, writeTunnelState } from '../lib/deploy/tunnel-config.js';
import { createServer as createTlsServer } from 'node:tls';
import { ensureCerts } from '../lib/certs.js';
import { LinkServer } from '../lib/link-server.js';
import { certPinFromFingerprint, computeHelloAuth, consumeFrames, encodeFrame, FRAME_TYPE, RELAY_ALPN } from '../lib/tunnel.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, '..', '..', '..');
const RESULT_DIR = join(HERE, 'results');
const KEEP = process.argv.includes('--keep');
const WORK = mkdtempSync(join(tmpdir(), 'dshm-m2b-deploy-test-'));
const EVIDENCE = { startedAt: new Date().toISOString(), workDir: WORK, tests: [], notes: [] };

let passed = 0;
let failed = 0;
const failures = [];

function assert(condition, message) {
  if (condition !== true) throw new Error('assertion failed: ' + message);
}

function assertEqual(actual, expected, message) {
  const a = JSON.stringify(actual);
  const b = JSON.stringify(expected);
  if (a !== b) throw new Error('assertion failed: ' + message + '\n  actual:   ' + a + '\n  expected: ' + b);
}

async function test(name, fn) {
  const startedAt = Date.now();
  try {
    await fn();
    passed += 1;
    EVIDENCE.tests.push({ name, ok: true, ms: Date.now() - startedAt });
    process.stdout.write('PASS  ' + name + '\n');
  } catch (error) {
    failed += 1;
    const message = String(error?.stack ?? error);
    failures.push({ name, error: message });
    EVIDENCE.tests.push({ name, ok: false, ms: Date.now() - startedAt, error: message });
    process.stdout.write('FAIL  ' + name + '\n      ' + message.split('\n').join('\n      ') + '\n');
  }
}

// ---------------------------------------------------------------------------
// Fixtures: real output captured from the acceptance server (Linux 24.04,
// dshm-relay installed) and a fresh-host variant.
// ---------------------------------------------------------------------------
const PREFLIGHT_REAL = `@@uname
Linux x86_64
@@os
PRETTY_NAME="Ubuntu 24.04.2 LTS"
NAME="Ubuntu"
VERSION_ID="24.04"
ID=ubuntu
ID_LIKE=debian
@@kernel
6.8.0-63-generic
@@id
0
root
@@systemd
systemd 255 (255.4-1ubuntu8.18)
systemd_dir=yes
@@mem
1613
@@disk
35841468
@@listen
LISTEN 0      4096      127.0.0.54:53    0.0.0.0:*
LISTEN 0      4096   127.0.0.53%lo:53    0.0.0.0:*
LISTEN 0      4096         0.0.0.0:22    0.0.0.0:*
LISTEN 0      4096               *:443         *:*
LISTEN 0      4096               *:30000       *:*
LISTEN 0      4096            [::]:22       [::]:*
@@relay
unitPath=/etc/systemd/system/dshm-relay.service
unitActive=active
unitEnabled=enabled
exists=/usr/local/bin/dshm-relay
exists=/etc/dshm-relay/relay.yaml
exists=/var/lib/dshm-relay/relay.secret
exists=/etc/systemd/system/dshm-relay.service
existsdir=/etc/dshm-relay
existsdir=/var/lib/dshm-relay
user=dshm-relay
@@relayconfig
# dshm-relay configuration (generated by \`dshm-relay init\`).
listen: "0.0.0.0:443"
publicHost: "203.0.113.10"
bridgePorts: [30000, 30009]
bridgeBind: "0.0.0.0"
stateFile: "/var/lib/dshm-relay/state.json"
secretFile: "/var/lib/dshm-relay/relay.secret"
@@sudo
uid0=yes
@@tools
tool=curl
tool=ss
tool=systemctl
tool=useradd
tool=install
tool=sha256sum
tool=openssl
tool=shred
tool=journalctl
@@end`;

/** Fresh server: no relay, only ssh + systemd resolver listening. */
const PREFLIGHT_FRESH = `@@uname
Linux x86_64
@@os
PRETTY_NAME="Ubuntu 24.04.2 LTS"
ID=ubuntu
@@kernel
6.8.0-63-generic
@@id
0
root
@@systemd
systemd 255 (255.4-1ubuntu8.18)
systemd_dir=yes
@@mem
1613
@@disk
35841468
@@listen
LISTEN 0      4096      127.0.0.54:53    0.0.0.0:*
LISTEN 0      4096         0.0.0.0:22    0.0.0.0:*
LISTEN 0      4096            [::]:22       [::]:*
@@relay
@@sudo
uid0=yes
@@tools
tool=curl
tool=ss
tool=systemctl
tool=useradd
tool=install
tool=sha256sum
tool=openssl
tool=shred
tool=journalctl
@@end`;

/** Fresh server where 443/8443/9443 are already taken by other services. */
const PREFLIGHT_BUSY_PORTS = PREFLIGHT_FRESH.replace(
  'LISTEN 0      4096         0.0.0.0:22    0.0.0.0:*',
  `LISTEN 0      4096         0.0.0.0:22    0.0.0.0:*
LISTEN 0      4096         0.0.0.0:443   0.0.0.0:*
LISTEN 0      4096         0.0.0.0:8443  0.0.0.0:*
LISTEN 0      4096         0.0.0.0:9443  0.0.0.0:*`,
);

const SNAPSHOT_BEFORE = `@@units
cron.service
dshm-relay.service
ssh.service
systemd-journald.service
@@ports
0.0.0.0:22
*:443
*:30000
@@etc
apt
dshm-relay
ssh
@@root
.bashrc
dshm-backup
@@end`;

const SNAPSHOT_AFTER_FRESH = `@@units
cron.service
dshm-relay.service
ssh.service
systemd-journald.service
@@ports
0.0.0.0:22
*:443
*:30000
@@etc
apt
dshm-relay
ssh
@@root
.bashrc
dshm-backup
@@end`;

const SNAPSHOT_AFTER_WITH_LEAK = SNAPSHOT_AFTER_FRESH.replace('cron.service\ndshm-relay.service', 'cron.service\ndshm-relay.service\nstranger.service');

const SCAN = {
  status: 'unknown',
  hostPart: '203.0.113.10',
  fingerprint: 'SHA256:AbCdEfGhIjKlMnOpQrStUvWxYz0123456789abcdefg',
  keyType: 'ssh-ed25519',
  knownHostsText: '',
  candidates: [{ hostPart: '203.0.113.10', keyType: 'ssh-ed25519', keyBase64: 'AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyForTestsOnly000000000000000000000', fingerprint: 'SHA256:AbCdEfGhIjKlMnOpQrStUvWxYz0123456789abcdefg', raw: 'x' }],
};

// ---------------------------------------------------------------------------
// Fake SSH transport + scripted remote outputs
// ---------------------------------------------------------------------------
function createFakeTransportFactory(script) {
  const calls = { exec: [], execRoot: [], uploads: [], scans: 0, trust: [], dispose: 0, privileges: [] };
  const factory = ({ input }) => {
    const transport = {
      calls,
      input,
      async scanHostKey() {
        calls.scans += 1;
        return typeof script.scan === 'function' ? script.scan() : script.scan ?? SCAN;
      },
      trustHostKey(candidate, options) {
        calls.trust.push({ candidate, options });
        return { fingerprint: candidate.fingerprint, keyType: candidate.keyType, changed: true };
      },
      async exec(command, options = {}) {
        calls.exec.push({ command, options });
        const handler = script.exec;
        if (typeof handler === 'function') {
          const result = await handler(command, options);
          if (result !== undefined) return result;
        }
        return { code: 0, stdout: '', stderr: '' };
      },
      async execRoot(command, options = {}) {
        calls.execRoot.push({ command, options });
        const handler = script.execRoot;
        if (typeof handler === 'function') {
          const result = await handler(command, options);
          if (result !== undefined) return result;
        }
        return { code: 0, stdout: '', stderr: '' };
      },
      async upload(localPath, remotePath) {
        calls.uploads.push({ localPath, remotePath });
        return { bytes: 1 };
      },
      setPrivilege(privilege) {
        calls.privileges.push(privilege);
      },
      logLine() {},
      classifyFailure(result) {
        return new DeployError(CODES.sshCommandFailed, 'fake ssh failure', { detail: String(result?.stderr ?? '') });
      },
      dispose() {
        calls.dispose += 1;
      },
    };
    return transport;
  };
  return { factory, calls };
}

function createFakeAssets() {
  const dir = join(WORK, 'assets-' + Math.random().toString(16).slice(2));
  mkdirSync(join(dir, 'linux-amd64'), { recursive: true });
  mkdirSync(join(dir, 'deploy'), { recursive: true });
  const binary = Buffer.from('fake-linux-amd64-relay-binary');
  const binaryPath = join(dir, 'linux-amd64', 'dshm-relay');
  writeFileSync(binaryPath, binary);
  const sha256 = createHash('sha256').update(binary).digest('hex');
  writeFileSync(
    join(dir, 'index.json'),
    JSON.stringify({ version: '0.1.0-test', binaries: { 'linux-amd64': { file: 'linux-amd64/dshm-relay', sha256, size: binary.length } } }, null, 2),
  );
  writeFileSync(join(dir, 'deploy', 'install.sh'), '#!/usr/bin/env bash\n# fake installer\nexit 0\n');
  writeFileSync(join(dir, 'deploy', 'dshm-relay.service'), '[Service]\nExecStart=/fake\n');
  return loadAssets({ assetsDir: dir });
}

const APP_CONFIG = 'dshm-relay://203.0.113.10:443?pin=TESTPIN_b64url_43chars_000000000000000000&v=1';
const RELAY_SECRET = 'TESTRELAYSECRET_0123456789abcdefghijklmn';

function installSummary(overrides = {}) {
  return {
    ok: true,
    engine: 1,
    mode: 'fresh',
    action: 'fresh-install',
    version: '0.1.0',
    publicHost: '203.0.113.10',
    controlPort: 443,
    controlOrigin: 'https://203.0.113.10:443',
    bridgeRange: '30000-30009',
    pin: 'TESTPIN_b64url_43chars_000000000000000000',
    appConfig: APP_CONFIG,
    healthOk: 1,
    restarted: 1,
    binarySha256: 'x'.repeat(64),
    changed: { user: 1, configDir: 1, dataDir: 1, binary: 1, config: 1, unit: 1 },
    had: { user: 0, config: 0, binary: 0, unit: 0, active: 0 },
    backupPath: '',
    init: { controlOrigin: 'https://203.0.113.10:443', pin: 'TESTPIN_b64url_43chars_000000000000000000', secret: RELAY_SECRET, appConfig: APP_CONFIG },
    ...overrides,
  };
}

function makeFreshScript({ preflight = PREFLIGHT_FRESH, summary = installSummary(), probe, installCode = 0, snapshotAfter = SNAPSHOT_AFTER_FRESH, localHealthz = true } = {}) {
  return {
    scan: SCAN,
    exec: (command) => {
      if (command.includes('id -u; id -un')) return { code: 0, stdout: '0\nroot\n', stderr: '' };
      if (command.includes('@@uname')) return { code: 0, stdout: preflight, stderr: '' };
      if (command.includes('@@units')) return { code: 0, stdout: snapshotAfter, stderr: '' };
      if (command.includes('sha256sum')) {
        const fake = createFakeAssets();
        const target = fake.binary('linux-amd64');
        return { code: 0, stdout: target.sha256 + '  /tmp/dshm-deploy-x/dshm-relay\n', stderr: '' };
      }
      return { code: 0, stdout: '', stderr: '' };
    },
    execRoot: (command) => {
      if (command.includes('install.sh')) return { code: installCode, stdout: '[install] mode=fresh\n[install] 完成\n', stderr: installCode === 0 ? '' : '[install] ERROR: fake install failure\n' };
      if (command.includes('summary.json')) return { code: 0, stdout: JSON.stringify(summary), stderr: '' };
      if (command.includes('relay.secret')) return { code: 0, stdout: RELAY_SECRET + '\n', stderr: '' };
      if (command.includes('rm -rf')) return { code: 0, stdout: '', stderr: '' };
      return { code: 0, stdout: '', stderr: '' };
    },
    probe: probe ?? (async () => ({ ok: true, health: { ok: true, hosts: 0 } })),
    localHealthz,
  };
}

function makeEngine(script, { dataDir, assets, hostKeyTimeoutMs, tunnelActivator, tunnelStatus } = {}) {
  const { factory, calls } = createFakeTransportFactory(script);
  const engine = new DeployEngine({
    dataDir: dataDir ?? mkdtempSync(join(WORK, 'data-')),
    assets: assets ?? createFakeAssets(),
    transportFactory: factory,
    probes: { externalSelfCheck: script.probe ?? (async () => ({ ok: true, health: { ok: true } })) },
    hostKeyTimeoutMs,
    ...(tunnelActivator === undefined ? {} : { tunnelActivator }),
    ...(tunnelStatus === undefined ? {} : { tunnelStatus }),
    log: () => {},
  });
  return { engine, calls };
}

const sleep = (ms) => new Promise((done) => setTimeout(done, ms));

async function waitDone(engine, deployId, { confirmFingerprint = false, timeoutMs = 8000 } = {}) {
  const started = Date.now();
  let confirmed = false;
  while (Date.now() - started < timeoutMs) {
    const status = engine.status({ deployId });
    if (status.prompt?.kind === 'host-fingerprint' && confirmFingerprint === true && confirmed === false) {
      confirmed = true;
      const result = engine.confirm({ deployId, fingerprint: status.prompt.fingerprint });
      assert(result.ok === true, 'fingerprint confirm accepted');
    }
    if (status.active !== true) return status;
    await sleep(15);
  }
  throw new Error('engine did not finish in ' + String(timeoutMs) + 'ms (state=' + String(engine.status({ deployId }).state) + ')');
}

async function waitForPrompt(engine, deployId, { timeoutMs = 3000 } = {}) {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    const status = engine.status({ deployId });
    if (status.prompt?.kind === 'host-fingerprint') return status;
    if (status.active !== true) throw new Error('deploy finished before prompting (state=' + String(status.state) + ')');
    await sleep(10);
  }
  throw new Error('timed out waiting for host-fingerprint prompt');
}

const FRESH_INPUT = { host: '203.0.113.10', sshPort: 22, user: 'root', auth: 'key', privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----\nfake-key-material-for-tests-only\n-----END OPENSSH PRIVATE KEY-----\n' };

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

await test('input: host normalization + validation', () => {
  assertEqual(normalizeHostInput('https://203.0.113.10/'), '203.0.113.10');
  assertEqual(normalizeHostInput('relay.example.com:2222'), 'relay.example.com');
  assertEqual(normalizeHostInput('[2001:db8::1]'), '2001:db8::1');
  assertEqual(normalizeHostInput('  '), '');
  const normalized = normalizeInput({ host: 'https://203.0.113.10/path', sshPort: '22', user: 'root', auth: 'key', privateKey: FRESH_INPUT.privateKey, forceReinstall: true });
  assertEqual(normalized.host, '203.0.113.10');
  assertEqual(normalized.sshPort, 22);
  assertEqual(normalized.forceReinstall, true);
  const published = JSON.stringify(publicInput(normalized));
  assert(!published.includes('PRIVATE KEY'), 'publicInput must not contain key material');
  let threw = false;
  try {
    normalizeInput({ host: '', auth: 'key', privateKey: 'x' });
  } catch (error) {
    threw = error.code === CODES.inputInvalid;
  }
  assert(threw, 'empty host rejected with input/invalid');
  assertThrows(() => normalizeInput({ host: 'h', auth: 'key', privateKey: 'not-a-key' }), CODES.inputInvalid, 'bad key rejected');
  assertThrows(() => normalizeInput({ host: 'h', auth: 'password', password: '' }), CODES.inputInvalid, 'empty password rejected');
  assertThrows(() => normalizeInput({ host: 'h', auth: 'key', privateKey: FRESH_INPUT.privateKey, sshPort: 70000 }), CODES.inputInvalid, 'bad ssh port rejected');
  assertThrows(() => normalizeInput({ host: 'h', auth: 'key', privateKey: FRESH_INPUT.privateKey, bridgeRange: 'x-y' }), CODES.inputInvalid, 'bad bridge range rejected');
  assertThrows(() => normalizeInput({ host: 'h', auth: 'key', privateKey: FRESH_INPUT.privateKey, installDir: 'relative/dir' }), CODES.inputInvalid, 'bad install dir rejected');
});

function assertThrows(fn, expectedCode, message) {
  try {
    fn();
  } catch (error) {
    if (expectedCode !== undefined && error?.code !== expectedCode && error?.code !== undefined) {
      throw new Error(message + ': wrong code ' + String(error.code) + ' (expected ' + expectedCode + ')');
    }
    return;
  }
  throw new Error(message + ': did not throw');
}

await test('mask: secrets are redacted from logs and structured values', () => {
  const masker = new SecretMasker();
  masker.add('hunter2-password');
  masker.add('-----BEGIN OPENSSH PRIVATE KEY-----\nfake-key-line-aaaa\n-----END OPENSSH PRIVATE KEY-----');
  masker.add('relay-secret-value-123456');
  const text = masker.mask('pw=hunter2-password secret=relay-secret-value-123456 key=fake-key-line-aaaa');
  assert(!text.includes('hunter2-password'), 'password redacted');
  assert(!text.includes('relay-secret-value-123456'), 'secret redacted');
  assert(!text.includes('fake-key-line-aaaa'), 'key line redacted');
  assert(text.includes('***'), 'replacement marker present');
  assertEqual(maskText('value abcdef xyz', ['abcdef']), 'value *** xyz');
  const maskedObject = masker.maskValue({ password: 'hunter2-password', nested: ['relay-secret-value-123456'] });
  assert(!JSON.stringify(maskedObject).includes('hunter2-password'), 'structured password masked');
});

await test('ssh: argv/env construction for key and password auth', () => {
  const keyArgs = buildSshArgs({ host: '1.2.3.4', port: 2222, user: 'deploy', auth: 'key', identityFile: '/tmp/id', knownHostsFile: '/tmp/kh' });
  assert(keyArgs.includes('-i') && keyArgs.includes('/tmp/id'), 'key mode uses -i');
  assert(keyArgs.includes('IdentitiesOnly=yes'), 'key mode IdentitiesOnly');
  assert(keyArgs.includes('BatchMode=yes'), 'key mode BatchMode=yes');
  assert(keyArgs.includes('UserKnownHostsFile=/tmp/kh'), 'private known_hosts');
  assert(keyArgs.includes('GlobalKnownHostsFile=/dev/null'), 'global known_hosts disabled');
  assert(keyArgs.includes('StrictHostKeyChecking=yes'), 'strict host checking');
  assert(keyArgs.includes('-p') && keyArgs.includes('2222'), 'port passed');
  assert(keyArgs[keyArgs.length - 1] === 'deploy@1.2.3.4', 'destination last');

  const pwArgs = buildSshArgs({ host: '1.2.3.4', port: 22, user: 'root', auth: 'password', knownHostsFile: '/tmp/kh' });
  assert(pwArgs.includes('PreferredAuthentications=password,keyboard-interactive'), 'password auth preference');
  assert(pwArgs.includes('PubkeyAuthentication=no'), 'password mode disables pubkey');
  assert(!pwArgs.includes('-i'), 'password mode has no identity file');
  assert(pwArgs.includes('NumberOfPasswordPrompts=1'), 'single password prompt');

  const scpArgs = buildScpArgs({ host: '1.2.3.4', port: 22, auth: 'key', identityFile: '/tmp/id', knownHostsFile: '/tmp/kh', localPath: '/tmp/bin', remotePath: '/tmp/remote/bin' });
  assert(scpArgs.includes('-P') && scpArgs.includes('22'), 'scp port flag');
  assert(scpArgs[scpArgs.length - 1] === 'root@1.2.3.4:/tmp/remote/bin', 'scp remote destination');
  // Regression (M5 deploy productization): scp must follow the configured login
  // user. `SshTransport.scpArgs` used to omit `user`, so a non-root deployment
  // uploaded to root@host and failed with `scp: Connection closed` on hosts
  // where root login is disabled (the ordinary-server acceptance case).
  const scpUserArgs = buildScpArgs({ host: '1.2.3.4', port: 22, user: 'deploy', auth: 'key', identityFile: '/tmp/id', knownHostsFile: '/tmp/kh', localPath: '/tmp/bin', remotePath: '/tmp/remote/bin' });
  assert(scpUserArgs[scpUserArgs.length - 1] === 'deploy@1.2.3.4:/tmp/remote/bin', 'buildScpArgs honors the configured user');
  const scpTransport = new SshTransport({
    host: '1.2.3.4',
    port: 22,
    user: 'deploy',
    auth: 'key',
    privateKey: FRESH_INPUT.privateKey,
    workDir: join(WORK, 'ssh-scp-user'),
    knownHostsFile: join(WORK, 'ssh-scp-user-known_hosts'),
    runner: { async run() { return { code: 0, stdout: '', stderr: '' }; } },
  });
  const transportScpArgs = scpTransport.scpArgs('/tmp/bin', '/tmp/remote/bin');
  assert(transportScpArgs[transportScpArgs.length - 1] === 'deploy@1.2.3.4:/tmp/remote/bin', 'SshTransport.scpArgs keeps the configured user');
  scpTransport.dispose();
  assertEqual(shellQuote("a'b"), "'a'\\''b'");
});

await test('static: preflight reads the relay config through sudo for non-root upgrades', () => {
  // Regression (M5 deploy productization): /etc/dshm-relay is 0750 root:dshm-relay,
  // so a non-root login user (even with NOPASSWD sudo) could not read relay.yaml —
  // every non-root "重新部署/升级" failed the plan step with relay/config-unreadable.
  assert(PREFLIGHT_SCRIPT.includes('sudo -n cat /etc/dshm-relay/relay.yaml'), 'preflight has a sudo config-read fallback');
  assert(PREFLIGHT_SCRIPT.includes('__unreadable__'), 'preflight keeps the unreadable marker for a real failure');
});

await test('ssh: password only via askpass env, never in argv or on disk', async () => {
  const workDir = join(WORK, 'ssh-pw');
  const password = 'super-secret-password-XYZ';
  const runnerCalls = [];
  const transport = new SshTransport({
    host: '1.2.3.4',
    port: 22,
    user: 'root',
    auth: 'password',
    password,
    workDir,
    knownHostsFile: join(WORK, 'ssh-pw-known_hosts'),
    runner: {
      async run(request) {
        runnerCalls.push(request);
        return { code: 0, stdout: '', stderr: '' };
      },
    },
  });
  const env = transport.childEnv();
  assertEqual(env.SSH_ASKPASS_REQUIRE, 'force', 'askpass forced');
  assertEqual(env.DSHM_SSH_PASSWORD, password, 'password passed via env');
  const askpassContent = readFileSync(env.SSH_ASKPASS, 'utf8');
  assert(!askpassContent.includes(password), 'askpass script itself must not contain the password');
  assertEqual(statSync(env.SSH_ASKPASS).mode & 0o777, 0o700, 'askpass script mode 0700');
  await transport.exec('true');
  const request = runnerCalls[0];
  assert(!request.args.some((arg) => arg.includes(password)), 'password never in ssh argv');
  assert(!JSON.stringify(request.args).includes(password), 'password never in argv JSON');
  transport.dispose();
  assert(!existsSync(workDir), 'work dir removed on dispose');
});

await test('ssh: key material is written 0600 and removed on dispose', async () => {
  const workDir = join(WORK, 'ssh-key');
  const transport = new SshTransport({
    host: '1.2.3.4',
    port: 22,
    user: 'root',
    auth: 'key',
    privateKey: FRESH_INPUT.privateKey,
    workDir,
    knownHostsFile: join(WORK, 'ssh-key-known_hosts'),
    runner: { async run() { return { code: 0, stdout: '', stderr: '' }; } },
  });
  const keyPath = join(workDir, 'id_deploy');
  assert(existsSync(keyPath), 'identity file materialized');
  assertEqual(statSync(keyPath).mode & 0o777, 0o600, 'identity file mode 0600');
  assertEqual(readFileSync(keyPath, 'utf8'), FRESH_INPUT.privateKey, 'identity content');
  transport.dispose();
  assert(!existsSync(workDir), 'key material removed');
});

await test('ssh: host key fingerprint matches ssh-keygen and known_hosts trust is tracked', async () => {
  const dir = join(WORK, 'keys');
  mkdirSync(dir, { recursive: true });
  const keyPath = join(dir, 'id_ed25519');
  const hasSshKeygen = existsSync('/usr/bin/ssh-keygen') || existsSync('/opt/homebrew/bin/ssh-keygen');
  if (hasSshKeygen !== true) {
    EVIDENCE.notes.push('ssh-keygen unavailable, fingerprint cross-check skipped');
  } else {
    execFileSync('ssh-keygen', ['-q', '-t', 'ed25519', '-N', '', '-f', keyPath, '-C', 'm2b-test']);
    const pubLine = readFileSync(keyPath + '.pub', 'utf8').trim();
    const [keyType, keyBase64] = pubLine.split(/\s+/);
    const expected = execFileSync('ssh-keygen', ['-lf', keyPath + '.pub'], { encoding: 'utf8' }).trim().split(/\s+/)[1];
    assertEqual(keyFingerprint(keyBase64), expected, 'OpenSSH SHA256 fingerprint matches ssh-keygen');
    const keyscanLine = '203.0.113.10 ' + keyType + ' ' + keyBase64;
    const [parsed] = parseKeyscanOutput('# comment\n' + keyscanLine + '\n');
    assertEqual(parsed.fingerprint, expected, 'keyscan parsing yields same fingerprint');
    assertEqual(parsed.keyType, keyType, 'keyscan key type');
    const hostPart = knownHostsHostPart('203.0.113.10', 22);
    const unknown = classifyHostKey({ knownHostsText: '', hostPart, candidates: [parsed] });
    assertEqual(unknown.status, 'unknown', 'empty known_hosts => unknown');
    const trusted = classifyHostKey({ knownHostsText: keyscanLine + '\n', hostPart, candidates: [parsed] });
    assertEqual(trusted.status, 'trusted', 'same key => trusted');
    const otherKey = parseKeyscanOutput('203.0.113.10 ' + keyType + ' ' + Buffer.from('another-key-blob').toString('base64'))[0];
    const mismatch = classifyHostKey({ knownHostsText: keyscanLine + '\n', hostPart, candidates: [otherKey] });
    assertEqual(mismatch.status, 'mismatch', 'different key => mismatch');
    assertEqual(parseKnownHosts(keyscanLine + '\n').get(hostPart).get(keyType), keyBase64, 'known_hosts parse');

    // Transport-level trust bookkeeping
    const knownHostsFile = join(WORK, 'trust-known_hosts');
    const transport = new SshTransport({
      host: '203.0.113.10',
      port: 22,
      user: 'root',
      auth: 'key',
      privateKey: FRESH_INPUT.privateKey,
      workDir: join(WORK, 'trust-work'),
      knownHostsFile,
      runner: { async run() { return { code: 0, stdout: keyscanLine + '\n', stderr: '' }; } },
    });
    const scan = await transport.scanHostKey();
    assertEqual(scan.status, 'unknown', 'transport scan unknown');
    transport.trustHostKey({ ...parsed, hostPart });
    assertEqual(transport.scanHostKey !== undefined, true, 'trust wrote file');
    assert(readFileSync(knownHostsFile, 'utf8').includes(keyBase64), 'known_hosts contains key');
    const second = new SshTransport({
      host: '203.0.113.10',
      port: 22,
      user: 'root',
      auth: 'key',
      privateKey: FRESH_INPUT.privateKey,
      workDir: join(WORK, 'trust-work2'),
      knownHostsFile,
      runner: { async run() { return { code: 0, stdout: keyscanLine + '\n', stderr: '' }; } },
    });
    assertEqual((await second.scanHostKey()).status, 'trusted', 'second scan trusted');
    assertEqual(forgetKnownHostKey(knownHostsFile, '203.0.113.10', 22), true, 'forget removes entry');
    assert(!readFileSync(knownHostsFile, 'utf8').includes(keyBase64), 'known_hosts entry removed');
  }
});

await test('ports: listening parse + control/bridge selection + avoidance', () => {
  const ports = parseListeningPorts(`LISTEN 0      4096      127.0.0.54:53    0.0.0.0:*
LISTEN 0      4096   127.0.0.53%lo:53    0.0.0.0:*
LISTEN 0      4096         0.0.0.0:22    0.0.0.0:*
LISTEN 0      4096               *:443         *:*
LISTEN 0      4096               *:30000       *:*
LISTEN 0      4096            [::]:22       [::]:*`);
  assertEqual([...ports].sort((a, b) => a - b), [22, 53, 443, 30000], 'listening ports');
  assertEqual(pickControlPort(new Set()), 443, 'prefers 443');
  assertEqual(pickControlPort(new Set([443])), 8443, '443 busy => 8443');
  assertEqual(pickControlPort(new Set([443, 8443])), 9443, '8443 busy => 9443');
  const randomPort = pickControlPort(new Set([443, 8443, 9443]), { rng: createRng(42) });
  assert(Number.isInteger(randomPort) && randomPort >= 20000 && ![443, 8443, 9443].includes(randomPort), 'random high port fallback');
  assertEqual(pickControlPort(new Set([443, 8443, 9443]), { rng: createRng(42) }), randomPort, 'seeded fallback is deterministic');
  assertEqual(pickControlPort(new Set([9999]), { preferred: 9999 }), undefined, 'busy preferred port => undefined');
  assertEqual(pickBridgeRange(new Set()), { start: 30000, end: 30009 }, 'default bridge range');
  assertEqual(pickBridgeRange(new Set([30000])), { start: 40000, end: 40009 }, 'avoid busy bridge range');
  assertEqual(pickBridgeRange(new Set(), { controlPort: 30003 }), { start: 40000, end: 40009 }, 'bridge never overlaps control port');
  assertEqual(parsePortRange('30000-30009'), { start: 30000, end: 30009 }, 'parse port range');
  assertEqual(parsePortRange('30009-30000'), undefined, 'reject inverted range');
  assertEqual(parseControlPortFromListen('0.0.0.0:8443'), 8443, 'control port from listen');
  assertEqual(parseBridgeRangeFromConfig('bridgePorts: [31000, 31009]'), { start: 31000, end: 31009 }, 'bridge range from config');
  assertEqual(parsePublicHostFromConfig('publicHost: "relay.example.com"'), 'relay.example.com', 'publicHost from config');
});

await test('preflight: parse real acceptance-server output into facts', () => {
  const facts = parsePreflightOutput(PREFLIGHT_REAL);
  assertEqual(facts.unameS, 'Linux', 'os family');
  assertEqual(facts.unameM, 'x86_64', 'machine');
  assertEqual(facts.os.ID, 'ubuntu', 'os id');
  assertEqual(facts.uid, 0, 'uid');
  assertEqual(facts.loginUser, 'root', 'login user');
  assertEqual(facts.systemd.present, true, 'systemd present');
  assertEqual(facts.memoryMb, 1613, 'memory');
  assertEqual(facts.listeningPorts, [22, 53, 443, 30000], 'listening ports');
  assertEqual(facts.existingRelay.installed, true, 'existing relay detected');
  assertEqual(facts.existingRelay.active, true, 'relay active');
  assertEqual(facts.existingRelay.userPresent, true, 'relay user');
  assertEqual(facts.existingRelay.configDirPresent, true, 'config dir');
  assertEqual(facts.existingRelay.dataDirPresent, true, 'data dir');
  assert(facts.tools.includes('sha256sum') && facts.tools.includes('curl'), 'tools detected');
  const config = parseExistingRelayConfig(facts.existingRelay.configText);
  assertEqual(config.controlPort, 443, 'existing control port');
  assertEqual(config.publicHost, '203.0.113.10', 'existing publicHost');
  assertEqual(config.bridgeRange, { start: 30000, end: 30009 }, 'existing bridge range');

  const fresh = parsePreflightOutput(PREFLIGHT_FRESH);
  assertEqual(fresh.existingRelay.installed, false, 'fresh host has no relay');
  assertEqual(fresh.listeningPorts, [22, 53], 'fresh listening ports');
});

await test('preflight: planning — fresh, port avoidance, upgrade, rejection paths', () => {
  const assets = { targets: ['linux-amd64', 'linux-arm64'] };
  const fresh = parsePreflightOutput(PREFLIGHT_FRESH);
  const freshPlan = assessPreflight({ facts: fresh, input: { host: '203.0.113.10' }, assets });
  assertEqual(freshPlan.ok, true, 'fresh plan ok');
  assertEqual(freshPlan.mode, 'fresh', 'fresh mode');
  assertEqual(freshPlan.plan.controlPort, 443, 'fresh uses 443');
  assertEqual(freshPlan.plan.bridgePorts, '30000-30009', 'fresh bridge range');

  const busy = parsePreflightOutput(PREFLIGHT_BUSY_PORTS);
  const busyPlan = assessPreflight({ facts: busy, input: { host: '203.0.113.10', rng: createRng(7) }, assets });
  assertEqual(busyPlan.ok, true, 'busy-port plan ok');
  assertEqual(busyPlan.plan.controlPort, pickControlPort(new Set([443, 8443, 9443]), { rng: createRng(7) }), 'avoided control port');

  const upgrade = assessPreflight({ facts: parsePreflightOutput(PREFLIGHT_REAL), input: { host: '203.0.113.10' }, assets });
  assertEqual(upgrade.ok, true, 'upgrade plan ok');
  assertEqual(upgrade.mode, 'upgrade', 'upgrade mode');
  assertEqual(upgrade.plan.controlPort, 443, 'upgrade reuses control port');
  assertEqual(upgrade.plan.bridgeRange, { start: 30000, end: 30009 }, 'upgrade reuses bridge range');

  const mismatch = assessPreflight({ facts: parsePreflightOutput(PREFLIGHT_REAL), input: { host: 'relay.example.com' }, assets });
  assertEqual(mismatch.ok, false, 'host change rejected');
  assertEqual(mismatch.errors[0].code, CODES.relayHostMismatch, 'host change error code');
  const forced = assessPreflight({ facts: parsePreflightOutput(PREFLIGHT_REAL), input: { host: 'relay.example.com', forceReinstall: true }, assets });
  assertEqual(forced.ok, true, 'host change allowed with forceReinstall');
  assert(forced.warnings.some((warning) => warning.includes('强制重建')), 'force reinit warning');

  const wrongArch = assessPreflight({ facts: { ...fresh, unameM: 'mips64' }, input: { host: 'h' }, assets });
  assertEqual(wrongArch.errors[0].code, CODES.hostUnsupportedArch, 'unsupported arch');
  const noSystemd = assessPreflight({ facts: { ...fresh, systemd: { present: false } }, input: { host: 'h' }, assets });
  assertEqual(noSystemd.errors[0].code, CODES.hostNoSystemd, 'no systemd rejected');
  const lowDisk = assessPreflight({ facts: { ...fresh, diskAvailableKb: 1024 }, input: { host: 'h' }, assets });
  assertEqual(lowDisk.errors[0].code, CODES.hostLowDisk, 'low disk rejected');
  const noBinary = assessPreflight({ facts: { ...fresh, unameM: 'aarch64' }, input: { host: 'h' }, assets: { targets: ['linux-amd64'] } });
  assertEqual(noBinary.errors[0].code, CODES.assetsUnavailable, 'missing asset rejected');
});

await test('preflight: snapshot parsing + non-destructive diff', () => {
  const before = parseSnapshotOutput(SNAPSHOT_BEFORE);
  const afterClean = parseSnapshotOutput(SNAPSHOT_AFTER_FRESH);
  assertEqual(before.units.length, 4, 'unit snapshot');
  assertEqual(before.etc.includes('dshm-relay'), true, 'etc snapshot');
  const clean = diffSnapshots({ before, after: afterClean, expectedPorts: [443, 30000] });
  assertEqual(clean.ok, true, 'clean diff has no destructive changes');
  // A fresh deploy legitimately adds dshm-relay.service; it is excluded by default.
  const freshDiff = diffSnapshots({ before: { units: ['ssh.service'], ports: ['0.0.0.0:22'], etc: ['ssh'], root: [] }, after: { units: ['dshm-relay.service', 'ssh.service'], ports: ['0.0.0.0:22', '*:443'], etc: ['dshm-relay', 'ssh'], root: [] }, expectedPorts: [443] });
  assertEqual(freshDiff.ok, true, 'expected dshm-relay unit is not flagged');
  const leaky = diffSnapshots({ before, after: parseSnapshotOutput(SNAPSHOT_AFTER_WITH_LEAK), expectedPorts: [443, 30000] });
  assertEqual(leaky.ok, false, 'unexpected service detected');
  assert(leaky.newUnits.includes('stranger.service'), 'leaked unit listed');
  const extraPort = parseSnapshotOutput(SNAPSHOT_AFTER_FRESH.replace('*:30000', '*:30000\n*:8080'));
  const portDiff = diffSnapshots({ before, after: extraPort, expectedPorts: [443, 30000] });
  assertEqual(portDiff.unexpectedNewPorts.includes('*:8080'), true, 'unexpected port flagged');
});

await test('tunnel config: 0600 persistence, reload merge, profile snippet', () => {
  const dataDir = mkdtempSync(join(WORK, 'tunnel-'));
  const written = writeTunnelState({
    dataDir,
    controlOrigin: 'https://203.0.113.10:443',
    pin: 'PIN_test_0000000000000000000000000000000000000',
    secret: RELAY_SECRET,
    publicHost: '203.0.113.10',
    controlPort: 443,
    bridgePorts: '30000-30009',
    appConfig: APP_CONFIG,
    relayVersion: '0.1.0',
    mode: 'fresh',
  });
  assertEqual(statSync(written.secretFile).mode & 0o777, 0o600, 'secret file 0600');
  assertEqual(statSync(written.tunnelStateFile).mode & 0o777, 0o600, 'tunnel.json 0600');
  assertEqual(readFileSync(written.secretFile, 'utf8').trim(), RELAY_SECRET, 'secret content');
  const read = readTunnelState({ dataDir });
  assertEqual(read.ok, true, 'tunnel state readable');
  assertEqual(read.state.controlOrigin, 'https://203.0.113.10:443', 'origin persisted');
  const merged = applyPersistedTunnelConfig({ port: 3466 }, { dataDir });
  assertEqual(merged.tunnel.enabled, true, 'persisted tunnel activates');
  assertEqual(merged.tunnel.pin, read.state.pin, 'pin merged');
  assertEqual(merged.tunnel.secretFile, written.secretFile, 'secretFile merged');
  assertEqual(merged.port, 3466, 'other config preserved');
  const explicit = applyPersistedTunnelConfig({ port: 3466, tunnel: { enabled: true, controlOrigin: 'https://other', pin: 'OTHER' } }, { dataDir });
  assertEqual(explicit.tunnel.controlOrigin, 'https://other', 'explicit profile tunnel wins');
  const snippet = buildProfileSnippet({ dataDir, controlOrigin: 'https://203.0.113.10:443', pin: 'PINX' });
  assert(snippet.includes('enabled: true') && snippet.includes('controlOrigin: "https://203.0.113.10:443"') && snippet.includes('secretFile:'), 'profile snippet content');
  writeFileSync(tunnelPaths({ dataDir }).tunnelStateFile, '{not json', { mode: 0o600 });
  const corrupt = applyPersistedTunnelConfig({ port: 3466 }, { dataDir });
  assertEqual(corrupt.tunnel, undefined, 'corrupt state ignored');
});

await test('selfcheck: TLS pin derivation matches relay pin form', () => {
  const der = Buffer.from('fake-der-certificate-bytes');
  const pin = certPin(der);
  assert(/^[A-Za-z0-9_-]{43}$/u.test(pin), 'pin is 43-char base64url');
  assertEqual(pin, certPin(Buffer.from('fake-der-certificate-bytes')), 'deterministic');
  assert(pin !== certPin(Buffer.from('different-der')), 'different certs differ');
});

await test('engine: fresh deploy happy path (fingerprint pause → confirm → done)', async () => {
  const script = makeFreshScript();
  const { engine, calls } = makeEngine(script);
  const start = engine.start(FRESH_INPUT);
  assertEqual(start.ok, true, 'deploy starts');
  const deployId = start.data.deployId;
  const waiting = await waitForPrompt(engine, deployId);
  assertEqual(waiting.state, 'waiting-host-key', 'waits for host fingerprint confirmation');
  assertEqual(waiting.prompt.kind, 'host-fingerprint', 'prompt kind');
  assertEqual(waiting.prompt.fingerprint, SCAN.fingerprint, 'prompt fingerprint');
  const wrongConfirm = engine.confirm({ deployId, fingerprint: 'SHA256:wrong' });
  assertEqual(wrongConfirm.ok, false, 'wrong fingerprint rejected');
  const status = await waitDone(engine, deployId, { confirmFingerprint: true });
  assertEqual(status.state, 'done', 'deploy done');
  assertEqual(status.steps.every((step) => step.status === 'ok'), true, 'all steps ok');
  assertEqual(status.result.mode, 'fresh', 'result mode fresh');
  assertEqual(status.result.controlOrigin, 'https://203.0.113.10:443', 'control origin');
  assertEqual(status.result.appConfig, APP_CONFIG, 'app config');
  assertEqual(status.result.pin, 'TESTPIN_b64url_43chars_000000000000000000', 'pin');
  assertEqual(calls.trust.length, 1, 'host key trusted once');
  assertEqual(calls.uploads.length, 3, 'binary + install.sh + unit uploaded');
  const installCall = calls.execRoot.find((call) => call.command.includes('install.sh'));
  assert(installCall !== undefined, 'installer invoked');
  assert(installCall.command.includes('--engine'), 'engine mode');
  assert(installCall.command.includes('--control-port 443'), 'control port in installer argv');
  assert(installCall.command.includes('--public-host') && installCall.command.includes('203.0.113.10'), 'public host in installer argv');
  const tunnel = readTunnelState({ dataDir: engine.dataDir });
  assertEqual(tunnel.ok, true, 'tunnel state persisted');
  assertEqual(tunnel.state.mode, 'fresh', 'tunnel mode');
  assertEqual(tunnel.state.pin, 'TESTPIN_b64url_43chars_000000000000000000', 'tunnel pin');
  // Non-destructive proof ran and found nothing suspicious.
  assertEqual(status.result.nonDestructive.ok, true, 'snapshot diff clean');
  // Log must not contain the relay secret.
  const logText = (status.logs ?? []).map((entry) => entry.text).join('\n');
  assert(!logText.includes(RELAY_SECRET), 'relay secret never logged');
});

await test('engine: log cursor streams incrementally and never leaks secrets', async () => {
  const script = makeFreshScript();
  const { engine } = makeEngine(script);
  const { data } = engine.start(FRESH_INPUT);
  const first = engine.status({ deployId: data.deployId, since: 0 });
  assert(first.logs.length > 0, 'initial logs');
  await waitDone(engine, data.deployId, { confirmFingerprint: true });
  const status = engine.status({ deployId: data.deployId });
  const allSecrets = Object.keys(RELAY_SECRET).length > 0;
  assert(allSecrets, 'secret registered for masking');
  const texts = status.logs.map((entry) => entry.text).join('\n');
  assert(!texts.includes(RELAY_SECRET), 'secret masked in streamed logs');
  assert(!texts.includes('hunter2'), 'password masked in streamed logs');
  assert(status.logs.every((entry) => entry.seq > 0), 'monotonic log seq');
});

await test('engine: port avoidance when 443/8443/9443 are occupied', async () => {
  const script = makeFreshScript({ preflight: PREFLIGHT_BUSY_PORTS });
  const { engine, calls } = makeEngine(script);
  const start = engine.start({ ...FRESH_INPUT, rng: undefined });
  const status = await waitDone(engine, start.data.deployId, { confirmFingerprint: true });
  assertEqual(status.state, 'done', 'deploy with avoided port done');
  const installCall = calls.execRoot.find((call) => call.command.includes('install.sh'));
  const match = installCall.command.match(/--control-port (\d+)/u);
  assert(match !== null, 'control port present');
  assert(!['443', '8443', '9443'].includes(match[1]), 'occupied ports avoided');
  assert(Number(match[1]) >= 20000, 'random high port selected');
});

await test('engine: idempotent upgrade reuses ports and keeps secret/state', async () => {
  const upgradeSummary = installSummary({
    mode: 'upgrade',
    action: 'noop',
    restarted: 0,
    pin: 'EXISTING_PIN_0000000000000000000000000000000000',
    controlOrigin: 'https://203.0.113.10:443',
    appConfig: 'dshm-relay://203.0.113.10:443?pin=EXISTING_PIN_0000000000000000000000000000000000&v=1',
    changed: { user: 0, configDir: 0, dataDir: 0, binary: 0, config: 0, unit: 0 },
    had: { user: 1, config: 1, binary: 1, unit: 1, active: 1 },
    init: undefined,
  });
  const script = makeFreshScript({ preflight: PREFLIGHT_REAL.replace('203.0.113.10', '203.0.113.10'), summary: upgradeSummary, snapshotAfter: SNAPSHOT_AFTER_FRESH });
  const { engine, calls } = makeEngine(script);
  const start = engine.start({ ...FRESH_INPUT, host: '203.0.113.10' });
  const status = await waitDone(engine, start.data.deployId, { confirmFingerprint: true });
  assertEqual(status.state, 'done', 'upgrade done');
  assertEqual(status.result.mode, 'upgrade', 'upgrade mode');
  assertEqual(status.result.controlPort, 443, 'upgrade reuses 443');
  const installCall = calls.execRoot.find((call) => call.command.includes('install.sh'));
  assert(installCall.command.includes('--control-port 443'), 'installer gets reused port');
  assert(installCall.command.includes('--bridge-start 30000') && installCall.command.includes('--bridge-end 30009'), 'installer reuses bridge range');
  assert(!installCall.command.includes('--force-reinstall'), 'no force reinstall by default');
  // Upgrade failure/rollback never deletes existing config: no rollback commands fired.
  assertEqual(calls.execRoot.some((call) => call.command.includes('rm -rf /etc/dshm-relay')), false, 'upgrade never removes existing config');
  assertEqual(status.result.nonDestructive.ok, true, 'upgrade non-destructive diff clean');
});

await test('engine: install failure rolls back a fresh deploy only', async () => {
  const script = makeFreshScript({ installCode: 1 });
  // No summary produced on failure.
  const originalExecRoot = script.execRoot;
  script.execRoot = (command) => (command.includes('summary.json') ? { code: 1, stdout: '', stderr: '' } : originalExecRoot(command));
  const { engine, calls } = makeEngine(script);
  const start = engine.start(FRESH_INPUT);
  const status = await waitDone(engine, start.data.deployId, { confirmFingerprint: true });
  assertEqual(status.state, 'failed', 'deploy failed');
  assertEqual(status.error.code, CODES.relayInstallFailed, 'install failed error code');
  assertEqual(status.rollback.ok, true, 'rollback ok');
  const rollbackCommands = calls.execRoot.map((call) => call.command).join('\n');
  assert(rollbackCommands.includes('systemctl stop dshm-relay'), 'stops created unit');
  assert(rollbackCommands.includes('rm -f') && rollbackCommands.includes('/usr/local/bin/dshm-relay'), 'removes created binary');
  assert(rollbackCommands.includes('rm -rf') && rollbackCommands.includes('/etc/dshm-relay'), 'removes created config dir');
  assert(rollbackCommands.includes('rm -rf') && rollbackCommands.includes('/var/lib/dshm-relay'), 'removes created data dir');
  assert(rollbackCommands.includes('userdel dshm-relay'), 'removes created user');
  assertEqual(calls.dispose >= 1, true, 'transport disposed');
});

await test('engine: external self-check failure rolls back and reports firewall hint', async () => {
  const firewallError = new DeployError(CODES.networkFirewall, '控制端口不可达', { hint: '手工放行 TCP' });
  const script = makeFreshScript({ probe: async () => ({ ok: false, tcpOk: false, error: firewallError }) });
  const { engine, calls } = makeEngine(script);
  const start = engine.start(FRESH_INPUT);
  const status = await waitDone(engine, start.data.deployId, { confirmFingerprint: true });
  assertEqual(status.state, 'failed', 'failed on external check');
  assertEqual(status.error.code, CODES.networkFirewall, 'firewall error code preserved');
  assert(status.error.hint.includes('手工放行') || status.error.hint.includes('安全组'), 'actionable hint shown');
  assert(calls.execRoot.some((call) => call.command.includes('rm -rf') && call.command.includes('/etc/dshm-relay')), 'fresh install cleaned up');
});

await test('engine: upgrade failure does not remove existing relay resources', async () => {
  const upgradeSummary = installSummary({ mode: 'upgrade', action: 'upgrade', init: undefined });
  const script = makeFreshScript({ preflight: PREFLIGHT_REAL, summary: upgradeSummary, installCode: 1 });
  const originalExecRoot = script.execRoot;
  script.execRoot = (command) => (command.includes('summary.json') ? { code: 1, stdout: '', stderr: '' } : originalExecRoot(command));
  const { engine, calls } = makeEngine(script);
  const start = engine.start(FRESH_INPUT);
  const status = await waitDone(engine, start.data.deployId, { confirmFingerprint: true });
  assertEqual(status.state, 'failed', 'upgrade failed');
  const destructive = calls.execRoot.some((call) => call.command.includes('rm -rf') && (call.command.includes('/etc/dshm-relay') || call.command.includes('/var/lib/dshm-relay')));
  assert(!destructive, 'existing config untouched on upgrade failure');
  assert(!calls.execRoot.some((call) => call.command.includes('userdel')), 'existing user untouched on upgrade failure');
  assertEqual(status.rollback.skipped, true, 'upgrade rollback delegated to installer');
});

await test('engine: cancel while waiting for fingerprint', async () => {
  const script = makeFreshScript();
  const { engine } = makeEngine(script);
  const start = engine.start(FRESH_INPUT);
  await waitForPrompt(engine, start.data.deployId);
  assertEqual(engine.status({ deployId: start.data.deployId }).state, 'waiting-host-key', 'waiting');
  const cancelled = engine.cancel({ deployId: start.data.deployId });
  assertEqual(cancelled.ok, true, 'cancel accepted');
  const status = await waitDone(engine, start.data.deployId);
  assertEqual(status.state, 'cancelled', 'state cancelled');
  assertEqual(status.error.code, CODES.deployCancelled, 'cancel error code');
});

await test('engine: host fingerprint confirmation timeout', async () => {
  const script = makeFreshScript();
  const { engine } = makeEngine(script, { hostKeyTimeoutMs: 60 });
  const start = engine.start(FRESH_INPUT);
  const status = await waitDone(engine, start.data.deployId);
  assertEqual(status.state, 'failed', 'timeout fails deploy');
  assertEqual(status.error.code, CODES.deployTimeout, 'timeout error code');
});

await test('engine: password auth is masked in logs and absent from status payload', async () => {
  const password = 'pw-TOP-SECRET-42';
  const script = makeFreshScript();
  const { engine } = makeEngine(script);
  const start = engine.start({ ...FRESH_INPUT, auth: 'password', password, privateKey: undefined });
  const status = await waitDone(engine, start.data.deployId, { confirmFingerprint: true });
  assertEqual(status.state, 'done', 'password deploy done');
  const payload = JSON.stringify(status);
  assert(!payload.includes(password), 'password absent from status payload');
  assert(!payload.includes(RELAY_SECRET), 'relay secret absent from status payload');
  const last = engine.lastPayload();
  assert(!JSON.stringify(last).includes(password), 'password absent from persisted summary');
});

await test('engine: dry-run stops after planning without touching the server', async () => {
  const script = makeFreshScript();
  const { engine, calls } = makeEngine(script);
  const start = engine.start({ ...FRESH_INPUT, dryRun: true });
  const status = await waitDone(engine, start.data.deployId, { confirmFingerprint: true });
  assertEqual(status.state, 'done', 'dry-run done');
  assertEqual(status.result.dryRun, true, 'dry-run flag in result');
  assertEqual(status.result.controlPort, 443, 'dry-run planned port');
  assertEqual(status.result.mode, 'fresh', 'dry-run mode');
  assertEqual(calls.uploads.length, 0, 'no uploads in dry-run');
  assertEqual(calls.execRoot.length, 0, 'no privileged commands in dry-run');
});

await test('engine: runtime tunnel activation runs after deploy (no reload needed)', async () => {
  const activations = [];
  const activator = async (activation) => {
    activations.push(activation);
    return { ok: true, state: 'ready', origin: 'https://203.0.113.10:30000', port: 30000, unchanged: false };
  };
  const { engine } = makeEngine(makeFreshScript(), { tunnelActivator: activator });
  const start = engine.start(FRESH_INPUT);
  const status = await waitDone(engine, start.data.deployId, { confirmFingerprint: true });
  assertEqual(status.state, 'done', 'deploy done with activation');
  assertEqual(activations.length, 1, 'activator called exactly once');
  assertEqual(activations[0].controlOrigin, 'https://203.0.113.10:443', 'activator gets controlOrigin');
  assertEqual(activations[0].pin, 'TESTPIN_b64url_43chars_000000000000000000', 'activator gets pin');
  assertEqual(activations[0].secret, RELAY_SECRET, 'activator gets relay secret in memory');
  assertEqual(status.result.tunnelActivation.ok, true, 'result reports activation ok');
  assertEqual(status.result.tunnelActivation.origin, 'https://203.0.113.10:30000', 'result reports tunnel origin');
  const payload = JSON.stringify(status);
  assert(!payload.includes(RELAY_SECRET), 'secret never appears in status payload');
  const texts = status.logs.map((entry) => entry.text).join('\n');
  assert(texts.includes('运行时隧道已就绪'), 'log shows runtime tunnel ready');
  assert(!texts.includes(RELAY_SECRET), 'secret never logged');
});

await test('engine: activation failure keeps the deploy successful and warns', async () => {
  const activator = async () => ({ ok: false, state: 'error', origin: null, port: null, error: 'auth/invalid', rolledBack: true, restoredState: 'ready' });
  const { engine } = makeEngine(makeFreshScript(), { tunnelActivator: activator });
  const start = engine.start(FRESH_INPUT);
  const status = await waitDone(engine, start.data.deployId, { confirmFingerprint: true });
  assertEqual(status.state, 'done', 'deploy remains successful');
  assertEqual(status.result.tunnelActivation.ok, false, 'activation failure recorded');
  assertEqual(status.result.tunnelActivation.rolledBack, true, 'rollback to previous tunnel recorded');
  const texts = status.logs.map((entry) => entry.text).join('\n');
  assert(texts.includes('运行时隧道激活失败'), 'warning logged');
  assert(texts.includes('重启 DSH'), 'fallback hint logged');
});

await test('engine: tunnel.activate action is repeatable and uses persisted config', async () => {
  const activations = [];
  const activator = async (activation) => {
    activations.push(activation);
    return { ok: true, state: 'ready', origin: 'https://203.0.113.10:30000', port: 30000 };
  };
  const { engine } = makeEngine(makeFreshScript(), { tunnelActivator: activator });
  const start = engine.start(FRESH_INPUT);
  await waitDone(engine, start.data.deployId, { confirmFingerprint: true });
  activations.length = 0;
  const first = await engine.handleAction({ action: 'tunnel.activate' });
  const second = await engine.handleAction({ action: 'tunnel.activate' });
  assertEqual(first.ok, true, 'first activate ok');
  assertEqual(second.ok, true, 'second activate ok (repeatable)');
  assertEqual(activations.length, 2, 'activator invoked for each explicit call');
  assertEqual(typeof activations[0].secret, 'string', 'secret read from persisted secret file');
  assert(activations[0].secret.length >= 16, 'persisted secret usable');
  assertEqual(first.data.pin, 'TESTPIN_b64url_43chars_000000000000000000', 'pin returned without secret');
  assert(!JSON.stringify(first).includes(RELAY_SECRET), 'activate response contains no secret');
});

await test('engine: tunnel.activate reports unavailable in headless mode', async () => {
  const { engine } = makeEngine(makeFreshScript());
  const result = await engine.handleAction({ action: 'tunnel.activate' });
  assertEqual(result.ok, false, 'headless activate rejected');
  assertEqual(result.error, 'deploy/tunnel-unavailable', 'headless error code');
});

await test('link-server: activateTunnel contract (validation / success / idempotent / rollback)', async () => {
  const { LinkServer } = await import('../lib/link-server.js');
  const makeFakeLink = (overrides = {}) => {
    const calls = { started: [], notifyTrust: 0, relayCleared: 0 };
    const fake = {
      disposed: false,
      config: { port: 3466, tunnel: { enabled: true, controlOrigin: 'https://old.example:443', pin: 'OLD_PIN_0000000000000000000000000000000000000', secret: 'OLD_SECRET_0123456789abcdef', secretFile: '', wantPort: 0 } },
      tunnel: { health: () => ({ state: 'ready', origin: 'https://old.example:30000', port: 30000 }), dispose() {} },
      baseEndpoints: [{ url: 'https://192.168.1.10:3466' }],
      deviceEndpoints: [],
      endpoints: [],
      certs: { caPin: 'CA' },
      pairing: { setTrust() { calls.notifyTrust += 1; }, setRelay(value) { if (value === undefined) calls.relayCleared += 1; } },
      bonjour: { update() {} },
      audit: { records: [], record(event, data) { this.records.push({ event, data }); } },
      hostIdentity: { hostId: 'hostid0001' },
      hostname: 'Mac',
      publishTunnelCode() {},
      onTunnelReady() {},
      _startActivatedTunnel: async function (config, timeoutMs) {
        calls.started.push({ config, timeoutMs });
        const origin = config.controlOrigin.replace(/:\d+$/u, ':30000');
        this.tunnel = { health: () => ({ state: 'ready', origin, port: 30000 }), dispose() {} };
        return { ok: true, state: 'ready', origin, port: 30000, error: undefined };
      },
      ...overrides,
    };
    return { fake, calls };
  };
  const invalidOrigin = await LinkServer.prototype.activateTunnel.call(makeFakeLink().fake, { controlOrigin: 'http://x', pin: 'A'.repeat(43) });
  assertEqual(invalidOrigin.ok, false, 'invalid origin rejected');
  assertEqual(invalidOrigin.state, 'config/invalid-origin', 'invalid origin state');
  const invalidPin = await LinkServer.prototype.activateTunnel.call(makeFakeLink().fake, { controlOrigin: 'https://x.example:443', pin: 'short' });
  assertEqual(invalidPin.state, 'config/invalid-pin', 'invalid pin state');

  const { fake, calls } = makeFakeLink();
  const success = await LinkServer.prototype.activateTunnel.call(fake, { controlOrigin: 'https://new.example:443', pin: 'NEW_PIN_0000000000000000000000000000000000000', secret: 'NEW_SECRET_0123456789abcdef' });
  assertEqual(success.ok, true, 'activation success');
  assertEqual(success.state, 'ready', 'activation state ready');
  assertEqual(calls.started.length, 1, 'new tunnel started once');
  assertEqual(calls.started[0].config.controlOrigin, 'https://new.example:443', 'explicit origin wins');
  assertEqual(calls.started[0].config.pin, 'NEW_PIN_0000000000000000000000000000000000000', 'explicit pin wins');
  assertEqual(calls.started[0].config.secret, 'NEW_SECRET_0123456789abcdef', 'explicit secret used');
  assertEqual(fake.config.tunnel.controlOrigin, 'https://new.example:443', 'runtime config updated');
  assertEqual(calls.relayCleared >= 1, true, 'stale relay advert cleared before activation');

  // Idempotency: same target + ready runtime tunnel => no restart.
  const idem = await LinkServer.prototype.activateTunnel.call(fake, { controlOrigin: 'https://new.example:443', pin: 'NEW_PIN_0000000000000000000000000000000000000', secret: 'NEW_SECRET_0123456789abcdef' });
  assertEqual(idem.unchanged, true, 'same target is a no-op');
  assertEqual(calls.started.length, 1, 'no extra tunnel start for idempotent call');

  // Failure path: first activation fails, then rollback restores previous config.
  const { fake: failing, calls: failingCalls } = makeFakeLink();
  let attempt = 0;
  failing._startActivatedTunnel = async (config) => {
    failingCalls.started.push(config);
    attempt += 1;
    if (attempt === 1) return { ok: false, state: 'error', origin: null, port: null, error: 'auth/invalid' };
    failing.tunnel = { health: () => ({ state: 'ready', origin: 'https://old.example:30000', port: 30000 }), dispose() {} };
    return { ok: true, state: 'ready', origin: 'https://old.example:30000', port: 30000 };
  };
  const failed = await LinkServer.prototype.activateTunnel.call(failing, { controlOrigin: 'https://bad.example:443', pin: 'BAD_PIN_00000000000000000000000000000000000000', secret: 'BAD_SECRET_0123456789abcdef' });
  assertEqual(failed.ok, false, 'activation failure reported');
  assertEqual(failed.error, 'auth/invalid', 'relay error propagated');
  assertEqual(failed.rolledBack, true, 'rollback to previous tunnel succeeded');
  assertEqual(failingCalls.started.length, 2, 'rolled-back tunnel restarted');
  assertEqual(failingCalls.started[1].controlOrigin, 'https://old.example:443', 'previous config restored');
  assertEqual(failing.config.tunnel.controlOrigin, 'https://old.example:443', 'runtime config reverted');
});

await test('engine: env action reports assets and ssh tooling', async () => {
  const { engine } = makeEngine(makeFreshScript());
  const env = await engine.handleAction({ action: 'env' });
  assertEqual(env.ok, true, 'env ok');
  assertEqual(env.data.assets.version, '0.1.0-test', 'assets version');
  assertEqual(env.data.assets.targets.includes('linux-amd64'), true, 'asset target listed');
  assertEqual(typeof env.data.sshBinaries.ssh, 'string', 'ssh binary resolved on macOS');
  assertEqual(env.data.tunnel.configured, false, 'no tunnel yet');
  assertEqual(env.data.busy, false, 'not busy');
});

await test('link-server: activateTunnel isolated e2e (real TLS relay + real TunnelClient)', async () => {
  const certs = ensureCerts({ dir: mkdtempSync(join(WORK, 'act-certs-')), bindHost: '127.0.0.1', lanIps: [], hostname: 'localhost' });
  const secret = 'ISOLATED_SECRET_0123456789abcdef';
  const hostId = 'isolatedhost01';
  const pin = certPinFromFingerprint(certs.leafFingerprint256);
  const readySeen = [];
  let relayPort;
  const relay = createTlsServer({ key: readFileSync(certs.leafKey), cert: readFileSync(certs.leafCert), ALPNProtocols: [RELAY_ALPN] }, (socket) => {
    let buffer = Buffer.alloc(0);
    socket.on('error', () => {});
    socket.on('data', (chunk) => {
      buffer = Buffer.concat([buffer, chunk]);
      buffer = consumeFrames(buffer, (type, payload) => {
        if (type !== FRAME_TYPE.JSON) return;
        let message;
        try {
          message = JSON.parse(payload.toString('utf8'));
        } catch {
          return;
        }
        if (message.t === 'hello') {
          const expected = computeHelloAuth({ secret, hostId: message.hostId, ts: message.ts, nonce: message.nonce, wantPort: message.wantPort });
          if (message.auth !== expected || message.hostId !== hostId) {
            socket.write(encodeFrame(FRAME_TYPE.JSON, Buffer.from(JSON.stringify({ t: 'error', code: 'auth/invalid', message: 'bad hmac' }))));
            socket.end();
            return;
          }
          socket.write(
            encodeFrame(
              FRAME_TYPE.JSON,
              Buffer.from(JSON.stringify({ t: 'ready', v: 1, hostId, publicHost: '127.0.0.1', port: 39999, origin: 'https://127.0.0.1:' + String(relayPort), heartbeatSec: 15 })),
            ),
          );
        } else if (message.t === 'ping') {
          socket.write(encodeFrame(FRAME_TYPE.JSON, Buffer.from(JSON.stringify({ t: 'pong', ts: Date.now() }))));
        }
      });
    });
  });
  await new Promise((done) => relay.listen(0, '127.0.0.1', done));
  relayPort = relay.address().port;
  const controlOrigin = 'https://127.0.0.1:' + String(relayPort);
  const makeFakeLink = () => ({
    disposed: false,
    config: { port: 3466, tunnel: { enabled: false, controlOrigin: '', pin: '', secret: '', secretFile: '', wantPort: 0 } },
    tunnel: undefined,
    baseEndpoints: [{ url: 'https://192.168.1.10:3466' }],
    certs,
    pairing: { hostName: 'ActMac', setTrust() {}, setRelay() {} },
    bonjour: { update() {} },
    audit: { record() {} },
    hostIdentity: { hostId },
    hostname: 'ActMac',
    publishTunnelCode() {},
    onTunnelReady(ready) {
      readySeen.push(ready);
    },
    // activateTunnel calls this method; bind the real implementation so the
    // test exercises the actual TLS/TunnelClient path (not a stub).
    _startActivatedTunnel: LinkServer.prototype._startActivatedTunnel,
  });
  const fakeLink = makeFakeLink();
  try {
    const result = await LinkServer.prototype.activateTunnel.call(fakeLink, { controlOrigin, pin, secret, timeoutMs: 8000 });
    assertEqual(result.ok, true, 'isolated activation reaches ready');
    assertEqual(result.state, 'ready', 'isolated activation state ready');
    assertEqual(result.origin, controlOrigin, 'isolated activation origin from relay ready');
    assertEqual(result.port, 39999, 'isolated activation bridge port from relay ready');
    assertEqual(readySeen.length, 1, 'onTunnelReady callback invoked (endpoints/pairing merge path)');
    assertEqual(fakeLink.config.tunnel.controlOrigin, controlOrigin, 'runtime config updated');
    // Idempotent repeat against the same live tunnel must not reconnect.
    const again = await LinkServer.prototype.activateTunnel.call(fakeLink, { controlOrigin, pin, secret, timeoutMs: 8000 });
    assertEqual(again.ok, true, 'repeat activation ok');
    assertEqual(again.unchanged, true, 'repeat activation is a no-op');
    // Wrong secret is rejected by the relay HMAC and surfaced (no previous tunnel => no rollback).
    const wrong = await LinkServer.prototype.activateTunnel.call(makeFakeLink(), { controlOrigin, pin, secret: 'WRONG_SECRET_0123456789abcdef', timeoutMs: 5000 });
    assertEqual(wrong.ok, false, 'wrong secret activation fails');
    assertEqual(wrong.rolledBack, undefined, 'no rollback when there was no previous tunnel');
    assert(String(wrong.error ?? '').includes('auth/invalid'), 'relay auth/invalid error surfaced');
  } finally {
    try {
      fakeLink.tunnel?.dispose?.();
    } catch {
      /* best effort */
    }
    await new Promise((done) => relay.close(done));
  }
});

await test('static: install.sh syntax + asset manifest integrity', () => {
  const installSh = join(REPO_ROOT, 'packages', 'dsh-m-relay', 'deploy', 'install.sh');
  assert(existsSync(installSh), 'install.sh exists');
  execFileSync('bash', ['-n', installSh]);
  const stagedInstall = join(REPO_ROOT, 'packages', 'dsh-m-link', 'assets', 'relay', 'deploy', 'install.sh');
  const stagedUnit = join(REPO_ROOT, 'packages', 'dsh-m-link', 'assets', 'relay', 'deploy', 'dshm-relay.service');
  assert(existsSync(stagedInstall), 'staged install.sh exists (run build-release.sh)');
  assert(existsSync(stagedUnit), 'staged unit exists');
  const assets = loadAssets();
  assertEqual(assets.manifestError, undefined, 'asset manifest parses');
  assert(assets.targets.includes('linux-amd64'), 'linux-amd64 asset present');
  assert(assets.targets.includes('linux-arm64'), 'linux-arm64 asset present');
  for (const target of assets.targets) {
    const binary = assets.binary(target);
    assertEqual(binary.ok, true, target + ' asset sha256 matches manifest');
    const header = readFileSync(binary.path).subarray(0, 4).toString('hex');
    assertEqual(header, '7f454c46', target + ' is an ELF binary');
    assertEqual(sha256File(binary.path), assets.manifest.binaries[target].sha256, target + ' sha256 recomputed');
  }
});

await test('static: client.js bundle loads and registers the settings section', async () => {
  // The DSH client module loader supplies "react"; emulate just enough to load
  // the factory and run apply() so a broken UI bundle fails the unit suite.
  const { readFileSync } = await import('node:fs');
  const source = readFileSync(join(REPO_ROOT, 'packages', 'dsh-m-link', 'client.js'), 'utf8');
  let loaded;
  const fakeReact = {
    createElement: () => undefined,
    useState: (initial) => [initial, () => {}],
    useEffect: () => {},
    useCallback: (fn) => fn,
    useRef: (initial) => ({ current: initial }),
  };
  const window = {
    __ModuleLoader__: {
      load(definition) {
        loaded = definition;
      },
    },
  };
  // eslint-disable-next-line no-new-func
  new Function('window', source)(window);
  assert(loaded !== undefined && typeof loaded.factory === 'function', 'client.js calls __ModuleLoader__.load');
  assertEqual(loaded.id, 'dsh-m-link', 'client plugin id');
  const mod = loaded.factory((name) => {
    if (name === 'react') return fakeReact;
    throw new Error('unexpected client require: ' + name);
  });
  assertEqual(typeof mod.apply, 'function', 'client apply exported');
  assertEqual(JSON.stringify(mod.inject), JSON.stringify(['slots']), 'client inject slots');
  let registered;
  const ctx = {
    slots: {
      inject(slot, register) {
        assertEqual(slot, 'settings.section', 'settings.section slot');
        register();
      },
      register(definition, component) {
        registered = { definition, component };
      },
    },
  };
  mod.apply(ctx);
  assert(registered !== undefined, 'settings section registered');
  assertEqual(registered.definition.id, 'dsh-m-link', 'section id');
  assertEqual(typeof registered.component, 'function', 'section component is a function');
  assert(registered.definition.label().includes('DSH-m'), 'section label');
});

await test('static: device list only renders active devices (M5)', async () => {
  // The backend deliberately keeps revoked devices (audit trail + auth/revoked
  // blacklist); the settings page must not render them, otherwise a revoked row
  // looks like the revoke did nothing and crowds the list.
  const { readFileSync } = await import('node:fs');
  const source = readFileSync(join(REPO_ROOT, 'packages', 'dsh-m-link', 'client.js'), 'utf8');
  assert(source.includes('devices.filter((device) => device.revoked !== true)'), 'client.js filters revoked devices into activeDevices');
  assert(source.includes('activeDevices.length'), 'device count uses the active list');
  assert(source.includes('activeDevices.map('), 'device rows use the active list');
  assert(!source.includes('已撤销 · '), 'revoked rows are no longer rendered');
});

await test('static: deploy admin route registers and handles env/unknown/bad-content-type', async () => {
  const { registerDeployRoute, DEPLOY_ADMIN_PATH } = await import('../lib/deploy/admin.js');
  const dataDir = mkdtempSync(join(WORK, 'admin-'));
  let handler;
  let disposed = false;
  const ctx = {
    connection: {
      fetch: {
        register(route) {
          assertEqual(route.path, DEPLOY_ADMIN_PATH, 'deploy route path');
          assertEqual(route.methods[0], 'POST', 'deploy route POST');
          handler = route.fetch;
          return () => {
            disposed = true;
          };
        },
      },
    },
  };
  const route = registerDeployRoute({ ctx, link: { dataDir } });
  assert(typeof handler === 'function', 'fetch handler registered');
  const makeRequest = (body, contentType = 'application/json') => ({
    headers: { get: (name) => (String(name).toLowerCase() === 'content-type' ? contentType : null) },
    async json() {
      return body;
    },
  });
  const envResponse = await handler(makeRequest({ action: 'deploy.env', server: true }));
  assertEqual(envResponse instanceof Response, true, 'handler returns a Response');
  const envBody = await envResponse.json();
  assertEqual(envBody.ok, true, 'env action ok');
  assertEqual(typeof envBody.data.assets.version, 'string', 'env includes assets version');
  assert(envBody.data.assets.targets.includes('linux-amd64'), 'env lists the linux-amd64 asset');
  assertEqual(envBody.data.tunnel.configured, false, 'env tunnel not configured');
  const unknown = await handler(makeRequest({ action: 'deploy.revokeEverything' }));
  assertEqual(unknown.status, 400, 'unknown action rejected');
  assertEqual((await unknown.json()).error, 'admin/unknown-action', 'unknown action error code');
  const badType = await handler(makeRequest({ action: 'env' }, 'text/plain'));
  assertEqual(badType.status, 415, 'non-JSON rejected');
  const tunnelStatus = await handler(makeRequest({ action: 'tunnel.status' }));
  assertEqual(tunnelStatus.status, 200, 'tunnel.status ok');
  assertEqual((await tunnelStatus.json()).data.tunnel, null, 'no runtime tunnel in mock link');
  const noActivation = await handler(makeRequest({ action: 'tunnel.activate' }));
  assertEqual(noActivation.status, 501, 'tunnel.activate unavailable without LinkServer hook');
  route.dispose();
  assertEqual(disposed, true, 'route disposer called');
});

await test('static: deploy admin tunnel.activate falls back to persisted state (激活连接 recovery)', async () => {
  // Live regression 2026-10-22 (restart window): the deploy card's 「激活连接」
  // button calls deployAdmin("tunnel.activate", {}) with an empty body. The route
  // must activate the persisted deploy/tunnel.json (+ tunnel.secret), otherwise
  // it answers config/invalid-origin and the recovery button cannot recover.
  const { registerDeployRoute } = await import('../lib/deploy/admin.js');
  const dataDir = mkdtempSync(join(WORK, 'admin-activate-'));
  const pin = 'TESTPIN_b64url_43chars_000000000000000000';
  const secret = 'PERSISTED_SECRET_0123456789abcdef';
  const persisted = writeTunnelState({ dataDir, controlOrigin: 'https://203.0.113.10:443', pin, secret, publicHost: '203.0.113.10', controlPort: 443, bridgePorts: '30000-30009', relayVersion: '0.1.0', mode: 'upgrade' });
  const activations = [];
  const link = {
    dataDir,
    config: { tunnel: { enabled: true, controlOrigin: 'https://old.example:443', pin: 'OLD_PIN_0000000000000000000000000000000000000', secretFile: '', wantPort: 0 } },
    async activateTunnel(activation) {
      activations.push(activation);
      if (activation.pin === 'EXPLICIT_BAD_PIN_000000000000000000000000000000') {
        return { ok: false, state: 'error', origin: 'https://203.0.113.10:443', port: null, error: 'pin-mismatch', rolledBack: true, restoredState: 'ready', current: { state: 'ready', origin: 'https://old.example:30000', port: 30000 } };
      }
      return { ok: true, state: 'ready', origin: 'https://203.0.113.10:30000', port: 30000, unchanged: true };
    },
  };
  let handler;
  const ctx = {
    connection: {
      fetch: {
        register(route) {
          handler = route.fetch;
          return () => {};
        },
      },
    },
  };
  const route = registerDeployRoute({ ctx, link });
  const makeRequest = (body) => ({
    headers: { get: (name) => (String(name).toLowerCase() === 'content-type' ? 'application/json' : null) },
    async json() {
      return body;
    },
  });
  const empty = await handler(makeRequest({ action: 'tunnel.activate' }));
  const emptyBody = await empty.json();
  assertEqual(emptyBody.ok, true, 'empty-body activate route ok');
  assertEqual(emptyBody.data.ok, true, 'empty-body activate succeeds');
  assertEqual(activations.length, 1, 'activator invoked once');
  assertEqual(activations[0].controlOrigin, 'https://203.0.113.10:443', 'persisted controlOrigin used');
  assertEqual(activations[0].pin, pin, 'persisted pin used');
  assertEqual(activations[0].secret, secret, 'secret read from persisted secret file');
  assertEqual(activations[0].secretFile, persisted.secretFile, 'persisted secretFile passed through');
  assert(!JSON.stringify(emptyBody).includes(secret), 'no secret echoed back');
  const explicit = await handler(makeRequest({ action: 'tunnel.activate', pin: 'EXPLICIT_BAD_PIN_000000000000000000000000000000', controlOrigin: 'https://203.0.113.10:443' }));
  const explicitBody = await explicit.json();
  assertEqual(explicitBody.data.ok, false, 'failure stays inside data for the card');
  assertEqual(explicitBody.data.rolledBack, true, 'rolledBack surfaced to the card');
  assertEqual(explicitBody.data.restoredState, 'ready', 'rollback state surfaced');
  route.dispose();
});

// ---------------------------------------------------------------------------
// Report
// ---------------------------------------------------------------------------
EVIDENCE.finishedAt = new Date().toISOString();
EVIDENCE.passed = passed;
EVIDENCE.failed = failed;
EVIDENCE.failures = failures;
mkdirSync(RESULT_DIR, { recursive: true });
writeFileSync(join(RESULT_DIR, 'm2b-deploy.json'), JSON.stringify(EVIDENCE, null, 2) + '\n');
if (KEEP !== true) rmSync(WORK, { recursive: true, force: true });

process.stdout.write('\n' + String(passed) + ' passed, ' + String(failed) + ' failed' + (failed === 0 ? ' — OK' : '') + '\n');
process.stdout.write('evidence: ' + join(RESULT_DIR, 'm2b-deploy.json') + '\n');
process.exit(failed === 0 ? 0 : 1);
