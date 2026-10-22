/**
 * m4-notify.mjs — M4 notification mapping unit test (plugin side).
 *
 * Guards docs/design/m4-notifications.zh.md §2/§5/§6:
 *   - approval pushes carry `aps.category = "dshm-approval"` (iOS renders the
 *     允许/拒绝 actions, both requiring unlock);
 *   - user-questions/request produces a `question` alert with questionCount;
 *   - every key event (approval / question / turn-end / failure) also sends a
 *     content-available background push (`type:"sync"`, `reason:<kind>`);
 *   - silent pushes are coalesced per device (`silentMinIntervalMs`, default 3s)
 *     while alert pushes are never coalesced;
 *   - dedupe, empty-question and no-token cases stay quiet.
 *
 * Runs standalone (no DSH host, no APNs network, no ~/.dsh):
 *   node test/m4-notify.mjs
 */

import { mkdirSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';

import { LinkServer } from '../lib/link-server.js';
import { Notifier } from '../lib/notifier.js';

const OUT_DIR = resolve(new URL('results', import.meta.url).pathname);
const checks = [];
const DEVICE = { deviceId: 'device-1', pushToken: 'a'.repeat(64), pushEnvironment: 'sandbox' };

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function check(name, run) {
  const started = Date.now();
  return (async () => {
    try {
      await run();
      checks.push({ name, ok: true, durationMs: Date.now() - started });
      console.log('PASS ' + name);
    } catch (error) {
      checks.push({ name, ok: false, durationMs: Date.now() - started, error: String(error?.message ?? error) });
      console.log('FAIL ' + name + ': ' + String(error?.message ?? error));
    }
  })();
}

function makeWorld({ config = {}, now } = {}) {
  const audit = { records: [], record(event, data) { this.records.push({ event, data }); } };
  const apns = {
    mode: 'ready',
    topic: 'com.dshm.app',
    sent: [],
    async send(args) {
      this.sent.push(args);
      return { ok: true, status: 200 };
    },
  };
  const clock = { value: now ?? 1000 };
  const notifier = new Notifier({
    devices: {},
    apns,
    audit,
    config,
    now: () => clock.value,
    log: () => {},
  });
  return { audit, apns, notifier, clock };
}

const classify = (sent) => sent.filter((entry) => entry.silent === true);
const alerts = (sent) => sent.filter((entry) => entry.silent !== true);

const item = (value) => JSON.stringify({ type: 'item', value });

const approvalFrame = (eventId, agentId) =>
  item({ type: 'waterfall', event: 'approval/request', eventId, agentId, request: { toolName: 'bash' } });

const questionFrame = (eventId, agentId, questions) =>
  item({ type: 'waterfall', event: 'user-questions/request', eventId, agentId, request: { questions } });

const turnEndFrame = (sessionId, seq, reasonKind) =>
  item({
    type: 'event',
    event: {
      type: 'turn/end',
      seq,
      data: { sessionId, reason: reasonKind === undefined ? { kind: 'completed' } : { kind: reasonKind } },
    },
  });

// ---------------------------------------------------------------- 1
await check('approval-alert-category-and-silent', async () => {
  const { apns, notifier } = makeWorld();
  notifier.observe(DEVICE, approvalFrame('evt-1', 'session-1'), false);
  await notifier.queue;
  assert(apns.sent.length === 2, 'approval must send alert + silent, got ' + String(apns.sent.length));
  const [alert, silent] = apns.sent;
  assert(alert.category === 'dshm-approval', 'alert must carry category dshm-approval, got ' + String(alert.category));
  assert(alert.data.type === 'approval', 'alert root type must be approval');
  assert(alert.data.eventId === 'evt-1', 'alert eventId mismatch');
  assert(alert.data.sessionId === 'session-1', 'alert sessionId mismatch');
  assert(alert.threadId === 'session-1', 'alert thread-id should be the agentId');
  assert(silent.silent === true, 'second push must be silent');
  assert(silent.data.type === 'sync', 'silent root type must be sync');
  assert(silent.data.reason === 'approval', 'silent reason must be approval');
  assert(silent.data.sessionId === 'session-1', 'silent sessionId mismatch');
});

// ---------------------------------------------------------------- 2
await check('approval-deduped', async () => {
  const { apns, notifier } = makeWorld();
  notifier.observe(DEVICE, approvalFrame('evt-dup', 'session-1'), false);
  await notifier.queue;
  notifier.observe(DEVICE, approvalFrame('evt-dup', 'session-1'), false);
  await notifier.queue;
  assert(apns.sent.length === 2, 'duplicate approval frame must not send again, got ' + String(apns.sent.length));
});

// ---------------------------------------------------------------- 3
await check('question-alert-and-silent', async () => {
  const { apns, notifier } = makeWorld();
  const questions = [{ id: 'q1', prompt: '继续吗？' }, { id: 'q2', prompt: '选哪个？' }];
  notifier.observe(DEVICE, questionFrame('evt-q1', 'session-2', questions), false);
  await notifier.queue;
  assert(apns.sent.length === 2, 'question must send alert + silent, got ' + String(apns.sent.length));
  const [alert, silent] = apns.sent;
  assert(alert.data.type === 'question', 'question alert root type mismatch');
  assert(alert.data.questionCount === 2, 'questionCount mismatch');
  assert(alert.data.sessionId === 'session-2', 'question sessionId mismatch');
  assert(alert.category === undefined, 'question alert must not carry the approval category');
  assert(alert.title.includes('需要你的回答'), 'question title mismatch: ' + alert.title);
  assert(alert.body.includes('2 个问题'), 'question body must include the count: ' + alert.body);
  assert(silent.data.reason === 'question', 'silent reason must be question');
  assert(silent.data.sessionId === 'session-2', 'silent question sessionId mismatch');
});

// ---------------------------------------------------------------- 4
await check('question-empty-skipped', async () => {
  const { apns, notifier } = makeWorld();
  notifier.observe(DEVICE, questionFrame('evt-q-empty', 'session-2', []), false);
  await notifier.queue;
  assert(apns.sent.length === 0, 'empty question waterfall must not notify, got ' + String(apns.sent.length));
});

// ---------------------------------------------------------------- 5
await check('turn-end-alert-and-silent', async () => {
  const { apns, notifier } = makeWorld();
  notifier.observe(DEVICE, turnEndFrame('session-3', 7), false);
  await notifier.queue;
  assert(apns.sent.length === 2, 'turn-end must send alert + silent');
  assert(apns.sent[0].data.type === 'turn-end', 'turn-end alert type mismatch');
  assert(apns.sent[0].data.sessionId === 'session-3', 'turn-end sessionId mismatch');
  assert(apns.sent[1].data.reason === 'turn-end', 'turn-end silent reason mismatch');
});

// ---------------------------------------------------------------- 6
await check('failure-alert-and-silent', async () => {
  const { apns, notifier } = makeWorld();
  notifier.observe(DEVICE, turnEndFrame('session-4', 8, 'error'), false);
  await notifier.queue;
  assert(apns.sent.length === 2, 'failure must send alert + silent');
  assert(apns.sent[0].data.type === 'failure', 'failure alert type mismatch');
  assert(apns.sent[1].data.reason === 'failure', 'failure silent reason mismatch');
});

// ---------------------------------------------------------------- 7
await check('silent-coalescing-window', async () => {
  const { apns, notifier, clock } = makeWorld({ now: 1000 });
  notifier.observe(DEVICE, turnEndFrame('session-5', 1), false);
  await notifier.queue;
  assert(alerts(apns.sent).length === 1 && classify(apns.sent).length === 1, 'first event: alert+silent expected');
  clock.value = 2000; // inside the 3s window
  notifier.observe(DEVICE, turnEndFrame('session-5', 2), false);
  await notifier.queue;
  assert(alerts(apns.sent).length === 2, 'alert must never be coalesced');
  assert(classify(apns.sent).length === 1, 'silent inside the 3s window must be dropped');
  clock.value = 5000; // outside the window
  notifier.observe(DEVICE, turnEndFrame('session-5', 3), false);
  await notifier.queue;
  assert(alerts(apns.sent).length === 3, 'third alert expected');
  assert(classify(apns.sent).length === 2, 'silent outside the window must be sent');
});

// ---------------------------------------------------------------- 8
await check('silent-disabled-config', async () => {
  const { apns, notifier } = makeWorld({ config: { silent: false } });
  notifier.observe(DEVICE, turnEndFrame('session-6', 1), false);
  await notifier.queue;
  assert(apns.sent.length === 1, 'silent:false must send alerts only, got ' + String(apns.sent.length));
  assert(apns.sent[0].silent !== true, 'only the alert push is expected');
});

// ---------------------------------------------------------------- 9
await check('no-token-device-stays-quiet', async () => {
  const { apns, notifier, audit } = makeWorld();
  notifier.observe({ deviceId: 'device-no-token', pushEnvironment: 'sandbox' }, turnEndFrame('session-7', 1), false);
  await notifier.queue;
  assert(apns.sent.length === 0, 'a device without a push token must not send');
  assert(audit.records.some((entry) => entry.event === 'notify.turn-end'), 'audit must still record the attempt');
});

// ---------------------------------------------------------------- 10
await check('audit-records-alert-and-sync', async () => {
  const { notifier, audit } = makeWorld();
  notifier.observe(DEVICE, approvalFrame('evt-audit', 'session-8'), false);
  await notifier.queue;
  assert(audit.records.some((entry) => entry.event === 'notify.approval'), 'audit must record notify.approval');
  assert(audit.records.some((entry) => entry.event === 'notify.sync' && entry.data.reason === 'approval'), 'audit must record notify.sync reason=approval');
});

// ---------------------------------------------------------------- 11
// apns.test variants are a pure method on LinkServer (no `this` use); calling it
// through the prototype keeps this test free of a real host/server instance.
const buildVariant = LinkServer.prototype.apnsTestVariant;

await check('apns-test-variant-approval', async () => {
  const variant = buildVariant({ kind: 'approval', deepLink: { sessionId: 'session-9' } });
  assert(variant.category === 'dshm-approval', 'approval test variant must carry category');
  assert(variant.data.type === 'approval', 'approval test variant type mismatch');
  assert(variant.data.eventId === 'test-event', 'approval test variant must use the dummy eventId');
  assert(variant.data.sessionId === 'session-9', 'approval test variant must keep the deep-link sessionId');
  assert(variant.silent === undefined, 'approval test variant must be an alert push');
});

// ---------------------------------------------------------------- 12
await check('apns-test-variant-silent', async () => {
  const byKind = buildVariant({ kind: 'silent', deepLink: { sessionId: 'session-9' } });
  assert(byKind.silent === true, 'kind=silent must produce a silent push');
  assert(byKind.data.type === 'sync', 'silent test variant root type must be sync');
  const byFlag = buildVariant({ silent: true });
  assert(byFlag.silent === true, 'silent:true must produce a silent push');
});

// ---------------------------------------------------------------- 13
await check('apns-test-variant-question-and-default', async () => {
  const question = buildVariant({ kind: 'question', deepLink: { sessionId: 'session-9' } });
  assert(question.data.type === 'question', 'question test variant type mismatch');
  assert(question.data.questionCount === 2, 'question test variant must fake 2 questions');
  assert(question.category === undefined, 'question test variant must not carry the approval category');
  const fallback = buildVariant({});
  assert(fallback.data.type === 'test', 'default test variant type mismatch');
  assert(fallback.category === undefined, 'default test variant must not carry a category');
  assert(fallback.silent === undefined, 'default test variant must be an alert push');
});

// ---------------------------------------------------------------- summary
const failed = checks.filter((item) => !item.ok);
mkdirSync(OUT_DIR, { recursive: true });
const report = {
  label: 'm4-notify',
  startedAt: new Date().toISOString(),
  total: checks.length,
  passed: checks.length - failed.length,
  failed: failed.length,
  checks,
};
writeFileSync(resolve(OUT_DIR, 'm4-notify.json'), JSON.stringify(report, null, 2) + '\n');

console.log('');
console.log('m4 notify: ' + (failed.length === 0 ? 'GO' : 'FAIL') + ' (' + String(checks.length - failed.length) + '/' + String(checks.length) + ')');
console.log('evidence: ' + resolve(OUT_DIR, 'm4-notify.json'));
if (failed.length > 0) process.exitCode = 1;
