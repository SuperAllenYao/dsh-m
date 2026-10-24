#!/usr/bin/env node
/**
 * turn-watcher.mjs — task-5: turn-end pushes must not depend on the phone
 * following the session.
 *
 * 用户实测（2026-10-22）：App 停在列表页/未跟随会话时，一轮结束收不到通知；根因是
 * notifier 只在手机侧 session/follow 帧流里看到 turn/end 才发。现在由宿主侧
 * TurnWatcher 轮询 session/list（running -> idle）并推给所有带 pushToken 的设备，
 * 帧路径在 watcher 活跃时不再重复发。
 *
 * Runs standalone (no DSH host, no APNs network, no real timers):
 *   node test/turn-watcher.mjs
 */
import assert from 'node:assert/strict';
import { mkdirSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';

import { LinkServer, resolveConfig } from '../lib/link-server.js';
import { Notifier } from '../lib/notifier.js';
import {
  DEFAULT_POLL_INTERVAL_MS,
  DEFAULT_REQUEST_TIMEOUT_MS,
  diffRunningSessions,
  sessionRunningState,
  shouldWatchSessions,
  TurnWatcher,
} from '../lib/session-watcher.js';

const OUT_DIR = resolve(new URL('results', import.meta.url).pathname);
const checks = [];
const DEVICE = { deviceId: 'device-1', pushToken: 'a'.repeat(64), pushEnvironment: 'sandbox' };
const sleep = (ms) => new Promise((done) => setTimeout(done, ms));
const settle = () => new Promise((done) => setImmediate(done));

function assertOk(condition, message) {
  assert.ok(condition, message);
}

async function check(name, run) {
  try {
    await run();
    checks.push({ name, ok: true });
    console.log('PASS ' + name);
  } catch (error) {
    checks.push({ name, ok: false, error: String(error?.message ?? error) });
    console.log('FAIL ' + name + ': ' + String(error?.message ?? error));
    throw error;
  }
}

// ------------------------------------------------------------ fake world

function makeWatcher({ config = {}, devices = [DEVICE], rows = [], fail = false, available = true } = {}) {
  const state = {
    sent: [],
    fetchCalls: 0,
    intervals: [],
    clearedIntervals: [],
    timerCallbacks: [],
    clearedTimeouts: [],
    logs: [],
    devices,
    rows,
    fail,
    available,
  };
  const watcher = new TurnWatcher({
    listDevices: () => state.devices,
    fetchSessionList: async () => {
      state.fetchCalls += 1;
      if (state.fail) throw new Error('upstream down');
      return typeof state.rows === 'function' ? state.rows() : state.rows;
    },
    notifyTurnEnd: (sessionId) => state.sent.push(sessionId),
    isAvailable: () => state.available,
    config: { enabled: true, turnEnd: true, pollIntervalMs: 2000, requestTimeoutMs: 120, ...config },
    log: (message) => state.logs.push(message),
    setIntervalFn: (callback, ms) => {
      const timer = { callback, ms, unref() {} };
      state.intervals.push(timer);
      return timer;
    },
    clearIntervalFn: (timer) => state.clearedIntervals.push(timer),
    setTimeoutFn: (callback, ms) => {
      const timer = { callback, ms, unref() {} };
      state.timerCallbacks.push(timer);
      return timer;
    },
    clearTimeoutFn: (timer) => state.clearedTimeouts.push(timer),
  });
  return { watcher, state };
}

/** Activate the watcher and let the immediate baseline poll finish. */
async function activate(context) {
  context.watcher.sync();
  await settle();
  return context;
}

const rows = (entries) => entries.map(([sessionId, running]) => ({ sessionId, running }));
const row = (sessionId, running) => ({ sessionId, running });

// ------------------------------------------------- pure transition rules

await check('shouldWatchSessions-matrix', async () => {
  assert.equal(shouldWatchSessions({ notifications: { turnEnd: true }, devices: [DEVICE] }), true);
  assert.equal(shouldWatchSessions({ notifications: { turnEnd: false }, devices: [DEVICE] }), false, 'turnEnd off');
  assert.equal(shouldWatchSessions({ notifications: { watchSessions: false }, devices: [DEVICE] }), false, 'kill switch');
  assert.equal(shouldWatchSessions({ notifications: { enabled: false }, devices: [DEVICE] }), false, 'notifier off');
  assert.equal(shouldWatchSessions({ notifications: { turnEnd: true }, devices: [] }), false, 'no device');
  assert.equal(shouldWatchSessions({ notifications: { turnEnd: true }, devices: [{ deviceId: 'x' }] }), false, 'no push token');
  assert.equal(
    shouldWatchSessions({ notifications: { turnEnd: true }, devices: [{ pushToken: '' }] }),
    false,
    'empty token'
  );
});

await check('sessionRunningState-and-diff', async () => {
  const items = [row('a', true), row('b', false), { running: true }, null, { sessionId: '', running: true }];
  assert.deepEqual([...sessionRunningState(items)], ['a'], 'only usable running ids');
  const diff = diffRunningSessions(new Set(['a', 'b', 'gone']), [row('a', false), row('b', true)]);
  assert.deepEqual(diff.ended, ['a'], 'running -> idle is a completed turn');
  assert.deepEqual([...diff.running], ['b']);
  assert.deepEqual(diff.dropped, ['gone'], 'a session missing from the list must not be notified');
  assert.deepEqual([...sessionRunningState({ items: [row('c', true)] })], ['c'], 'accepts the value object');
});

// ------------------------------------------------------- watcher lifecycle

await check('watcher-starts-only-with-push-device-and-stops', async () => {
  const context = makeWatcher({ rows: [] });
  context.watcher.sync();
  assert.equal(context.watcher.active, true, 'watcher runs for a push-token device');
  assert.equal(context.state.intervals.length, 1);
  assert.equal(context.state.intervals[0].ms, DEFAULT_POLL_INTERVAL_MS, 'default cadence is 2s');
  await settle();
  assert.equal(context.state.fetchCalls, 1, 'immediate baseline poll');

  context.state.devices = [{ deviceId: 'device-1' }]; // token removed / device revoked
  context.watcher.sync();
  assert.equal(context.watcher.active, false, 'watcher stops when no push device remains');
  assert.equal(context.state.clearedIntervals.length, 1);
  context.watcher.dispose();
});

await check('baseline-poll-does-not-notify-already-running-sessions', async () => {
  const context = makeWatcher({ rows: [row('s1', true)] });
  await activate(context);
  assert.deepEqual(context.state.sent, [], 'sessions already running at start are the baseline');
  assert.equal(context.watcher.primed, true);
});

// ------------------------------------------------- running -> idle notify

await check('running-to-idle-notifies-once-with-session-id', async () => {
  const context = makeWatcher({ rows: [row('s1', false)] });
  await activate(context); // baseline: idle, not running
  context.state.rows = [row('s1', true)];
  await context.watcher.pollOnce(); // started running
  assert.deepEqual(context.state.sent, [], 'a running turn is not a completion');
  context.state.rows = [row('s1', false)];
  const result = await context.watcher.pollOnce();
  assert.deepEqual(result.ended, ['s1']);
  assert.deepEqual(context.state.sent, ['s1'], 'exactly one turn-end notification carried the sessionId');
  await context.watcher.pollOnce(); // unchanged idle
  assert.deepEqual(context.state.sent, ['s1'], 'no duplicate notification while the state is unchanged');
  context.watcher.dispose();
});

await check('multiple-sessions-each-notify', async () => {
  const context = makeWatcher({ rows: [row('a', true), row('b', true), row('c', false)] });
  await activate(context);
  context.state.rows = [row('a', false), row('b', false), row('c', true)];
  const result = await context.watcher.pollOnce();
  assert.deepEqual(result.ended.sort(), ['a', 'b']);
  assert.deepEqual(context.state.sent.sort(), ['a', 'b'], 'each completed session gets its own notification');
  context.watcher.dispose();
});

await check('dropped-session-is-not-notified', async () => {
  const context = makeWatcher({ rows: [row('s1', true)] });
  await activate(context);
  context.state.rows = [row('kept', false)]; // s1 disappeared between polls
  const result = await context.watcher.pollOnce();
  assert.deepEqual(result.ended, []);
  assert.deepEqual(result.dropped, ['s1']);
  assert.deepEqual(context.state.sent, [], 'a removed session has no deep-link target; do not push it');
  context.watcher.dispose();
});

// ------------------------------------------------ failures never break

await check('poll-failure-is-swallowed-and-recovers', async () => {
  const context = makeWatcher({ rows: [row('s1', true)] });
  await activate(context);
  context.state.fail = true;
  const failed = await context.watcher.pollOnce();
  assert.equal(typeof failed.error, 'string');
  assert.deepEqual(context.state.sent, [], 'a failed poll must not notify');
  assert.equal(context.watcher.active, true, 'the watcher keeps polling after a failure');
  assert.ok(context.state.logs.some((line) => line.includes('poll failed')), 'failure is logged once');

  context.state.fail = false;
  context.state.rows = [row('s1', false)];
  const recovered = await context.watcher.pollOnce();
  assert.deepEqual(recovered.ended, ['s1'], 'next successful poll still detects the completion');
  assert.deepEqual(context.state.sent, ['s1']);
  context.watcher.dispose();
});

await check('host-inactive-skip-does-not-fetch', async () => {
  const context = makeWatcher({ rows: [row('s1', true)], available: false });
  await activate(context);
  assert.equal(context.state.fetchCalls, 0, 'host inactive: do not touch the loopback API');
  context.watcher.dispose();
});

await check('slow-request-times-out-without-blocking', async () => {
  const context = makeWatcher({ rows: [row('s1', true)] });
  await activate(context);
  let release;
  context.state.rows = () => new Promise((done) => { release = done; });
  const timersBefore = context.state.timerCallbacks.length;
  const pending = context.watcher.pollOnce();
  assert.equal(
    context.state.timerCallbacks.length,
    timersBefore + 1,
    'request is wrapped in a timeout'
  );
  const requestTimer = context.state.timerCallbacks[timersBefore];
  assert.equal(requestTimer.ms, context.watcher.requestTimeoutMs);
  requestTimer.callback();
  const result = await pending;
  assert.ok(String(result.error).includes('timeout'), 'a stuck request reports a timeout');
  release([]);
  context.watcher.dispose();
});

await check('overlapping-polls-are-skipped', async () => {
  const context = makeWatcher({ rows: [] });
  await activate(context);
  let release;
  context.state.rows = () => new Promise((done) => { release = done; });
  const first = context.watcher.pollOnce();
  await settle();
  const second = await context.watcher.pollOnce();
  assert.equal(second.skipped, 'busy', 'a slow poll must not stack a second request');
  release([]);
  await first;
  context.watcher.dispose();
});

// --------------------------------------- frame-path / watcher dedupe

function makeNotifier({ isTurnEndWatched } = {}) {
  const sent = [];
  const notifier = new Notifier({
    devices: {},
    apns: {
      mode: 'ready',
      topic: 'com.dshm.app',
      send: async (message) => {
        sent.push(message);
        return { ok: true };
      },
    },
    audit: { record() {} },
    config: { enabled: true, turnEnd: true, failure: true, silent: false },
    log: () => {},
    isTurnEndWatched,
  });
  return { notifier, sent };
}

const openFrame = (streamId, sessionId) => JSON.stringify({
  type: 'open',
  streamId,
  endpoint: 'session/follow',
  payload: { args: { request: { address: { sessionId } } } },
});
const turnEndFrame = (streamId, seq) => JSON.stringify({
  type: 'item',
  streamId,
  value: { type: 'event', event: { type: 'turn/end', seq, data: { reason: { kind: 'completed' } } } },
});
const approvalFrame = (eventId, agentId) => JSON.stringify({
  type: 'item',
  value: { type: 'waterfall', event: 'approval/request', eventId, agentId, request: { toolName: 'bash' } },
});

await check('frame-path-suppressed-while-watcher-owns-turn-end', async () => {
  const { notifier, sent } = makeNotifier({ isTurnEndWatched: () => true });
  const watched = { deviceId: 'device-1', pushToken: 'a'.repeat(64) };
  notifier.observeDevice(watched, openFrame('st-1', 'session-abc'), false);
  notifier.observe(watched, turnEndFrame('st-1', 42), false);
  await notifier.queue;
  assert.deepEqual(sent, [], 'watcher active: no duplicate turn-end push from the frame path');

  notifier.observe(watched, approvalFrame('evt-1', 'session-abc'), false);
  await notifier.queue;
  assert.equal(sent.length, 1, 'approval alerts are unaffected by the turn-end dedupe');
  assert.equal(sent[0].data.type, 'approval');
});

await check('frame-path-fallback-when-device-has-no-watcher', async () => {
  const { notifier, sent } = makeNotifier({ isTurnEndWatched: (device) => device.deviceId === 'watched' });
  const watched = { deviceId: 'watched', pushToken: 'a'.repeat(64) };
  const unwatched = { deviceId: 'legacy', pushToken: 'b'.repeat(64) };
  notifier.observeDevice(watched, openFrame('st-1', 'session-abc'), false);
  notifier.observe(watched, turnEndFrame('st-1', 7), false);
  await notifier.queue;
  assert.deepEqual(sent, [], 'watched device is covered by the watcher');

  notifier.observeDevice(unwatched, openFrame('st-2', 'session-def'), false);
  notifier.observe(unwatched, turnEndFrame('st-2', 7), false);
  await notifier.queue;
  assert.equal(sent.length, 1, 'a device without watcher coverage keeps the frame-path fallback');
  assert.equal(sent[0].data.sessionId, 'session-def');
  assert.equal(sent[0].threadId, 'session-def');
});

// -------------------------------- top-level only (user decision 2026-10-22)

await check('subagent-list-rows-never-produce-turn-end', async () => {
  const before = [
    { sessionId: 'parent-1', running: true },
    { sessionId: 'child-1', running: true, parentSessionId: 'parent-1' },
    { sessionId: 'child-2', running: true, origin: 'subagent' },
  ];
  const after = [
    { sessionId: 'parent-1', running: false },
    { sessionId: 'child-1', running: false, parentSessionId: 'parent-1' },
    { sessionId: 'child-2', running: false, origin: 'subagent' },
  ];
  assert.deepEqual(
    [...sessionRunningState(before)],
    ['parent-1'],
    'only top-level sessions enter the running baseline'
  );
  const diff = diffRunningSessions(sessionRunningState(before), after);
  assert.deepEqual(diff.ended, ['parent-1'], 'only the top-level session notifies on completion');
  assert.deepEqual([...diff.running], []);
  assert.deepEqual(diff.dropped, [], 'subagent rows are ignored, not reported as dropped');
});

await check('watcher-ignores-subagent-transitions-end-to-end', async () => {
  const rows = [
    { sessionId: 'parent-1', running: true },
    { sessionId: 'child-1', running: true, parentSessionId: 'parent-1' },
  ];
  const { watcher, state } = makeWatcher({ config: { watchSessions: true }, rows });
  watcher.sync();
  await settle();
  assert.equal(state.sent.length, 0, 'baseline poll never notifies');
  // Both flip idle in the same poll: only the parent may notify.
  state.rows = [
    { sessionId: 'parent-1', running: false },
    { sessionId: 'child-1', running: false, parentSessionId: 'parent-1' },
  ];
  await watcher.pollOnce();
  assert.deepEqual(state.sent, ['parent-1'], 'only the top-level session notifies; subagent child is ignored');
  watcher.dispose();
});

// ------------------------------------------------------- server wiring

await check('config-defaults-and-normalization', async () => {
  const defaults = resolveConfig({});
  // task-5b: the host session-event bus is the primary turn-end source, so the
  // polling watcher is opt-in (fallback for hosts without the bus).
  assert.equal(defaults.notifications.watchSessions, false, 'polling watcher is opt-in now');
  assert.equal(defaults.notifications.pollIntervalMs, 2000);
  assert.equal(defaults.notifications.requestTimeoutMs, 1500);
  assert.equal(DEFAULT_POLL_INTERVAL_MS, 2000);
  assert.equal(DEFAULT_REQUEST_TIMEOUT_MS, 1500);

  const optIn = resolveConfig({ notifications: { watchSessions: true } });
  assert.equal(optIn.notifications.watchSessions, true, 'explicit opt-in is honored');
  const off = resolveConfig({ notifications: { watchSessions: false, pollIntervalMs: 10 } });
  assert.equal(off.notifications.watchSessions, false, 'kill switch is honored');
  assert.equal(off.notifications.pollIntervalMs, 2000, 'invalid cadence falls back to default');

  const custom = resolveConfig({ notifications: { pollIntervalMs: 5000, requestTimeoutMs: 900 } });
  assert.equal(custom.notifications.pollIntervalMs, 5000);
  assert.equal(custom.notifications.requestTimeoutMs, 900);
});

await check('server-fans-turn-end-out-to-push-devices', async () => {
  const calls = [];
  const fake = {
    disposed: false,
    devices: {
      active: () => [
        { deviceId: 'd1', pushToken: 'a'.repeat(64) },
        { deviceId: 'd2' },
        { deviceId: 'd3', pushToken: 'b'.repeat(64) },
      ],
    },
    notifier: { notify(device, payload) { calls.push({ device, payload }); } },
  };
  const sent = LinkServer.prototype.notifyTurnEndAllDevices.call(fake, 'session-x');
  assert.equal(sent, 2);
  assert.equal(calls.length, 2);
  for (const call of calls) {
    assert.equal(call.payload.kind, 'turn-end');
    assert.equal(call.payload.data.type, 'turn-end');
    assert.equal(call.payload.data.sessionId, 'session-x', 'deep link target must be the session');
    assert.equal(call.payload.threadId, 'session-x');
  }
  assert.deepEqual(
    LinkServer.prototype.watchableDevices.call(fake).map((device) => device.deviceId),
    ['d1', 'd3']
  );
  assert.equal(LinkServer.prototype.notifyTurnEndAllDevices.call({ ...fake, disposed: true }, 'session-x'), 0);
  assert.equal(LinkServer.prototype.notifyTurnEndAllDevices.call(fake, ''), 0);
});

// 真机报障（2026-10-24）：一台手机在重复配对/重装后留下多条 active 设备记录
// （同 keyId、同 APNs token），逐设备发送导致一次 turn-end 收到 8 条通知。
// 推送目标必须按 token 去重，同一 token 只发一次；配对/启动时清理重复记录。
await check('push-targets-dedupe-by-token', async () => {
  const duplicateToken = 'a'.repeat(64);
  const fake = {
    disposed: false,
    devices: {
      active: () => [
        { deviceId: 'old', pushToken: duplicateToken, lastSeenAt: 1 },
        { deviceId: 'new', pushToken: duplicateToken, lastSeenAt: 9 },
        { deviceId: 'other', pushToken: 'b'.repeat(64), lastSeenAt: 2 },
        { deviceId: 'no-token', lastSeenAt: 3 },
      ],
    },
  };
  const targets = LinkServer.prototype.pushTargets.call(fake);
  assert.deepEqual(targets.map((device) => device.deviceId), ['new', 'other'],
    'same push token collapses to the newest record; tokenless records are skipped');

  const calls = [];
  const fanOutFake = {
    ...fake,
    pushTargets: LinkServer.prototype.pushTargets,
    notifier: { notify(device, payload) { calls.push({ device, payload }); } },
  };
  const sent = LinkServer.prototype.notifyTurnEndAllDevices.call(fanOutFake, 'session-y');
  assert.equal(sent, 2, 'fan-out must send once per unique push token');
  assert.deepEqual(calls.map((call) => call.device.deviceId), ['new', 'other']);
  assert.equal(calls[0].payload.collapseId, 'turn-end:session-y', 'duplicate deliveries collapse on iOS');
});

await check('loopback-session-list-request-shape', async () => {
  const originalFetch = globalThis.fetch;
  const captured = [];
  globalThis.fetch = async (url, options) => {
    captured.push({ url, options });
    const body = {
      type: 'server-response',
      rpcId: 'rpc-x',
      result: {
        ok: true,
        value: { items: [{ sessionId: 's1', running: true, projections: { values: { title: 'big' } } }, { sessionId: 's2', running: false }, null] },
      },
    };
    return { ok: true, status: 200, arrayBuffer: async () => Buffer.from(JSON.stringify(body), 'utf8') };
  };
  try {
    const fake = {
      loopbackOrigin: 'https://127.0.0.1:3466',
      config: { notifications: { requestTimeoutMs: 500 } },
      ensurePeer: () => ({ cookie: { name: 'dsh-peer', value: 'cookie-v' } }),
    };
    const items = await LinkServer.prototype.fetchSessionListForWatcher.call(fake, { deviceId: 'd1' });
    assert.deepEqual(items, [{ sessionId: 's1', running: true }, { sessionId: 's2', running: false }]);
    assert.equal(captured.length, 1);
    assert.equal(captured[0].url, 'https://127.0.0.1:3466/api/session/list');
    assert.equal(captured[0].options.method, 'POST');
    assert.equal(captured[0].options.headers.cookie, 'dsh-peer=cookie-v');
    assert.equal(captured[0].options.headers['x-dshm-list-lite'], '1');
    const envelope = JSON.parse(captured[0].options.body);
    assert.equal(envelope.type, 'client-request');
    assert.equal(envelope.method, 'session/list');
    assert.ok(captured[0].options.signal !== undefined, 'loopback call carries an abort timeout');

    // A non-ok envelope must surface as an error for the watcher to swallow.
    globalThis.fetch = async () => ({
      ok: true,
      status: 200,
      arrayBuffer: async () => Buffer.from(JSON.stringify({ type: 'server-response', result: { ok: false } })),
    });
    await assert.rejects(
      () => LinkServer.prototype.fetchSessionListForWatcher.call(fake, { deviceId: 'd1' }),
      /not ok/
    );
    globalThis.fetch = async () => ({ ok: false, status: 503, arrayBuffer: async () => Buffer.alloc(0) });
    await assert.rejects(
      () => LinkServer.prototype.fetchSessionListForWatcher.call(fake, { deviceId: 'd1' }),
      /HTTP 503/
    );

    // A disposed peer (401) must drop the stale cookie so the next poll reconnects.
    const peer = { cookie: { name: 'dsh-peer', value: 'stale' } };
    const fakeWithPeer = {
      loopbackOrigin: 'https://127.0.0.1:3466',
      config: { notifications: { requestTimeoutMs: 500 } },
      ensurePeer: () => peer,
    };
    globalThis.fetch = async () => ({ ok: false, status: 401, arrayBuffer: async () => Buffer.alloc(0) });
    await assert.rejects(
      () => LinkServer.prototype.fetchSessionListForWatcher.call(fakeWithPeer, { deviceId: 'd1' }),
      /HTTP 401/
    );
    assert.equal(peer.cookie, undefined, 'stale peer cookie is dropped for the next poll');
  } finally {
    globalThis.fetch = originalFetch;
  }
});

// ------------------------------------------------------------- report

mkdirSync(OUT_DIR, { recursive: true });
const failed = checks.filter((entry) => !entry.ok);
const report = { task: 'task-5 turn watcher', startedAt: new Date().toISOString(), checks, failed: failed.length };
writeFileSync(resolve(OUT_DIR, 'turn-watcher.json'), JSON.stringify(report, null, 2) + '\n');
console.log('');
console.log('turn-watcher: ' + (failed.length === 0 ? 'GO' : 'FAIL') + ' (' + String(checks.length - failed.length) + '/' + String(checks.length) + ')');
console.log('evidence: ' + resolve(OUT_DIR, 'turn-watcher.json'));
if (failed.length > 0) process.exitCode = 1;
