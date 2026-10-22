/**
 * apns-payload-shape.mjs — APNs payload wire-shape unit test (release hardening).
 *
 * Guards the change introduced by docs/design/apns-payload-root-level.patch.md:
 * custom keys (`type`, `sessionId`, `toolName`, `eventId`) must live at the
 * **payload root**, not nested inside `aps` under `"dsh-m"`. `aps` must only
 * carry Apple system keys (alert/sound/thread-id).
 *
 * The iOS app keeps accepting all three historical shapes
 * (`apps/ios/DSHm/App/PushNotificationPayload.swift`: aps["dsh-m"] >
 * root["dsh-m"] > root), so old and new app builds decode either form.
 *
 * Runs standalone (no DSH host, no APNs network, no ~/.dsh):
 *   node test/apns-payload-shape.mjs
 */

import { mkdirSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';

import { buildApnsHeaders, buildApnsPayload } from '../lib/apns.js';

const OUT_DIR = resolve(new URL('results', import.meta.url).pathname);
const checks = [];

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function check(name, run) {
  const started = Date.now();
  try {
    run();
    checks.push({ name, ok: true, durationMs: Date.now() - started });
    console.log('PASS ' + name);
  } catch (error) {
    checks.push({ name, ok: false, durationMs: Date.now() - started, error: String(error?.message ?? error) });
    console.log('FAIL ' + name + ': ' + String(error?.message ?? error));
  }
}

function parse(input) {
  return JSON.parse(buildApnsPayload(input));
}

const approvalData = { type: 'approval', toolName: 'bash', eventId: 'evt-1', sessionId: 'session-1' };

// ---------------------------------------------------------------- 1
check('custom-keys-at-payload-root', () => {
  const payload = parse({ title: 'DSH 需要审批', body: '工具调用 bash 等待确认', threadId: 'dsh-m-evt-1', data: approvalData });
  assert(payload.type === 'approval', 'root.type must be "approval", got ' + String(payload.type));
  assert(payload.toolName === 'bash', 'root.toolName must be "bash", got ' + String(payload.toolName));
  assert(payload.eventId === 'evt-1', 'root.eventId must be "evt-1", got ' + String(payload.eventId));
  assert(payload.sessionId === 'session-1', 'root.sessionId must be "session-1", got ' + String(payload.sessionId));
});

// ---------------------------------------------------------------- 2
check('aps-has-no-custom-keys', () => {
  const payload = parse({ title: 't', body: 'b', threadId: 'dsh-m-evt-1', data: approvalData });
  assert(payload.aps !== undefined && payload.aps !== null, 'aps must exist');
  assert(payload.aps['dsh-m'] === undefined, 'legacy aps["dsh-m"] nesting must be gone: ' + JSON.stringify(payload.aps));
  for (const key of ['type', 'sessionId', 'toolName', 'eventId']) {
    assert(payload.aps[key] === undefined, 'custom key "' + key + '" must not appear inside aps');
  }
});

// ---------------------------------------------------------------- 3
check('aps-system-keys-intact', () => {
  const payload = parse({ title: 'DSH 测试通知', body: '点开进会话', threadId: 'dsh-m-test', data: { type: 'test' } });
  assert(payload.aps.alert?.title === 'DSH 测试通知', 'aps.alert.title mismatch');
  assert(payload.aps.alert?.body === '点开进会话', 'aps.alert.body mismatch');
  assert(payload.aps.sound === 'default', 'aps.sound must be "default"');
  assert(payload.aps['thread-id'] === 'dsh-m-test', 'aps["thread-id"] mismatch');
});

// ---------------------------------------------------------------- 4
check('no-data-keeps-minimal-root', () => {
  const payload = parse({ title: 't', body: 'b', threadId: 'tid-1' });
  const rootKeys = Object.keys(payload).sort();
  assert(rootKeys.length === 1 && rootKeys[0] === 'aps', 'root must only contain aps, got ' + rootKeys.join(','));
});

// ---------------------------------------------------------------- 5
check('undefined-thread-id-is-omitted', () => {
  const raw = buildApnsPayload({ title: 't', body: 'b', data: { type: 'turn-end' } });
  const payload = JSON.parse(raw);
  assert(payload.aps['thread-id'] === undefined, 'thread-id must be omitted when undefined');
  assert(!raw.includes('"thread-id"'), 'serialized payload must not contain a thread-id key: ' + raw);
  // JSON.stringify drops undefined values — no literal "undefined"/null leak.
  assert(!raw.includes('undefined') && !raw.includes('null'), 'payload leaked undefined/null: ' + raw);
});

// ---------------------------------------------------------------- 6
check('legacy-dsh-m-root-nesting-not-sent', () => {
  const raw = buildApnsPayload({ title: 't', body: 'b', threadId: 'tid-1', data: approvalData });
  const payload = JSON.parse(raw);
  assert(payload['dsh-m'] === undefined, 'root["dsh-m"] nesting must not be sent');
  assert(payload.aps['dsh-m'] === undefined, 'aps["dsh-m"] nesting must not be sent');
  assert(!raw.includes('"dsh-m"'), 'payload must not contain any "dsh-m" wrapper: ' + raw);
});

// ---------------------------------------------------------------- 7
check('all-notification-kinds-at-root', () => {
  const kinds = [
    { type: 'approval', toolName: 'bash', eventId: 'e1', sessionId: 's1' },
    { type: 'turn-end', sessionId: 's2' },
    { type: 'failure', sessionId: 's3' },
    { type: 'test', sessionId: 's4' },
    { type: 'apns-test', sessionId: 's5' },
  ];
  for (const data of kinds) {
    const payload = parse({ title: 't', body: 'b', threadId: 'x', data });
    for (const [key, value] of Object.entries(data)) {
      assert(payload[key] === value, 'kind ' + data.type + ': root.' + key + ' must be ' + String(value) + ', got ' + String(payload[key]));
    }
  }
});

// ---------------------------------------------------------------- 8
check('approval-category-in-aps', () => {
  const payload = parse({
    title: 'DSH 需要审批',
    body: '工具调用 bash 等待你的确认',
    threadId: 'dsh-m-evt-1',
    category: 'dshm-approval',
    data: { type: 'approval', toolName: 'bash', eventId: 'evt-1', sessionId: 'session-1' },
  });
  assert(payload.aps.category === 'dshm-approval', 'aps.category must be dshm-approval, got ' + String(payload.aps.category));
  assert(payload.category === undefined, 'category must live inside aps, not at the payload root');
});

// ---------------------------------------------------------------- 9
check('category-absent-without-option', () => {
  const payload = parse({ title: 't', body: 'b', threadId: 'x', data: { type: 'turn-end', sessionId: 's' } });
  assert(payload.aps.category === undefined, 'aps.category must be absent when the caller did not pass one');
});

// ---------------------------------------------------------------- 10
check('silent-payload-shape', () => {
  const payload = parse({
    silent: true,
    data: { type: 'sync', reason: 'approval', sessionId: 'session-1', eventId: 'evt-1' },
  });
  assert(payload.aps['content-available'] === 1, 'silent aps must carry content-available:1');
  assert(payload.aps.alert === undefined, 'silent push must not carry an alert');
  assert(payload.aps.sound === undefined, 'silent push must not carry a sound');
  assert(payload.aps['thread-id'] === undefined, 'silent push must not carry thread-id');
  assert(payload.type === 'sync', 'silent root type must be "sync"');
  assert(payload.reason === 'approval', 'silent root reason mismatch');
  assert(payload.sessionId === 'session-1', 'silent root sessionId mismatch');
});

// ---------------------------------------------------------------- 11
check('push-headers-alert-vs-background', () => {
  const alert = buildApnsHeaders({ silent: false });
  assert(alert['apns-push-type'] === 'alert', 'alert push-type mismatch');
  assert(alert['apns-priority'] === '10', 'alert priority must be 10');
  const background = buildApnsHeaders({ silent: true });
  assert(background['apns-push-type'] === 'background', 'silent push-type must be background');
  assert(background['apns-priority'] === '5', 'silent priority must be 5');
  const fallback = buildApnsHeaders();
  assert(fallback['apns-push-type'] === 'alert', 'default headers must be alert');
});

// ---------------------------------------------------------------- summary
const failed = checks.filter((item) => !item.ok);
mkdirSync(OUT_DIR, { recursive: true });
const report = {
  label: 'apns-payload-shape',
  startedAt: new Date().toISOString(),
  total: checks.length,
  passed: checks.length - failed.length,
  failed: failed.length,
  checks,
};
writeFileSync(resolve(OUT_DIR, 'apns-payload-shape.json'), JSON.stringify(report, null, 2) + '\n');

console.log('');
console.log('apns payload shape: ' + (failed.length === 0 ? 'GO' : 'FAIL') + ' (' + String(checks.length - failed.length) + '/' + String(checks.length) + ')');
console.log('evidence: ' + resolve(OUT_DIR, 'apns-payload-shape.json'));
if (failed.length > 0) process.exitCode = 1;
