#!/usr/bin/env node
/**
 * host-turn-events.mjs — task-5b: turn 完成/失败通知改由 Host 进程内事件总线驱动。
 *
 * 用户要求（2026-10-22）：turn 完成类 APNs 通知必须在 App 未打开、未跟随该会话、
 * 进程被杀时也能送达。此前只有"手机侧帧流"一条来源（没跟随就没有流 → 不发通知），
 * 轮询 session/list 又依赖宿主 peer。现在订阅 ctx.on('session/event') 实时驱动。
 */
import assert from 'node:assert/strict';

const { createHostTurnEventHandler, hostTurnEndKind } = await import('../lib/session-watcher.js');

let checks = 0;
const check = (label, fn) => {
  fn();
  checks += 1;
  console.log('ok ' + String(checks) + ' - ' + label);
};

const session = (id) => ({ id });
const turnEnd = (reasonKind, seq = 7) => ({
  type: 'turn/end',
  seq,
  data: { turn: 2, reason: reasonKind === undefined ? undefined : { kind: reasonKind } },
});

check('turn/end completed -> turn-end kind', () => {
  assert.equal(hostTurnEndKind(turnEnd('completed')), 'turn-end');
  assert.equal(hostTurnEndKind(turnEnd(undefined)), 'turn-end', 'missing reason defaults to completed');
});

check('turn/end error -> failure kind; aborted/interrupted -> nothing', () => {
  assert.equal(hostTurnEndKind(turnEnd('error')), 'failure');
  assert.equal(hostTurnEndKind(turnEnd('aborted')), undefined);
  assert.equal(hostTurnEndKind(turnEnd('interrupted')), undefined);
});

check('non turn/end events produce nothing', () => {
  assert.equal(hostTurnEndKind({ type: 'user/message', data: {} }), undefined);
  assert.equal(hostTurnEndKind({ type: 'turn/start' }), undefined);
  assert.equal(hostTurnEndKind(undefined), undefined);
  assert.equal(hostTurnEndKind(null), undefined);
});

check('completed turn notifies with the session id (works without any phone attached)', () => {
  const calls = [];
  const handler = createHostTurnEventHandler({ notifyTurnEnd: (id) => calls.push(['turn-end', id]) });
  handler(session('session-abc'), turnEnd('completed'));
  assert.deepEqual(calls, [['turn-end', 'session-abc']]);
});

check('error turn notifies the failure fan-out', () => {
  const calls = [];
  const handler = createHostTurnEventHandler({ notifyFailure: (id) => calls.push(['failure', id]) });
  handler(session('session-def'), turnEnd('error'));
  assert.deepEqual(calls, [['failure', 'session-def']]);
});

check('turns in sessions the App is not following still notify (no device state involved)', () => {
  const calls = [];
  const handler = createHostTurnEventHandler({ notifyTurnEnd: (id) => calls.push(id) });
  for (const id of ['session-1', 'session-2', 'session-3']) handler(session(id), turnEnd('completed', 1));
  assert.deepEqual(calls, ['session-1', 'session-2', 'session-3']);
});

check('aborted turn never notifies', () => {
  const calls = [];
  const handler = createHostTurnEventHandler({ notifyTurnEnd: (id) => calls.push(id) });
  handler(session('session-abc'), turnEnd('aborted'));
  assert.deepEqual(calls, []);
});

check('config switches suppress turn-end / failure independently', () => {
  const calls = [];
  const off = createHostTurnEventHandler({ notifyTurnEnd: (id) => calls.push('turn' + id), notifyFailure: (id) => calls.push('fail' + id), config: { turnEnd: false } });
  off(session('s1'), turnEnd('completed'));
  off(session('s1'), turnEnd('error'));
  assert.deepEqual(calls, ['fails1']);
  const disabled = createHostTurnEventHandler({ notifyTurnEnd: (id) => calls.push(id), config: { enabled: false } });
  disabled(session('s2'), turnEnd('completed'));
  assert.equal(calls.length, 1);
});

check('isEnabled gate + throwing fan-out never break the host event bus', () => {
  const calls = [];
  const gated = createHostTurnEventHandler({ notifyTurnEnd: (id) => calls.push(id), isEnabled: () => false });
  gated(session('s1'), turnEnd('completed'));
  assert.equal(calls.length, 0);
  const boom = createHostTurnEventHandler({ notifyTurnEnd: () => { throw new Error('apns down'); } });
  assert.doesNotThrow(() => boom(session('s1'), turnEnd('completed')));
});

check('missing/empty session id is ignored (never push a deep link with no target)', () => {
  const calls = [];
  const handler = createHostTurnEventHandler({ notifyTurnEnd: (id) => calls.push(id) });
  handler(undefined, turnEnd('completed'));
  handler({}, turnEnd('completed'));
  handler({ id: '' }, turnEnd('completed'));
  assert.deepEqual(calls, []);
});

check('subagent / teammate sessions never notify (user decision 2026-10-22: top-level only)', () => {
  const calls = [];
  const handler = createHostTurnEventHandler({
    notifyTurnEnd: (id) => calls.push(['turn-end', id]),
    notifyFailure: (id) => calls.push(['failure', id]),
  });
  // The Host Session header carries origin/parentSession for delegated sessions.
  handler({ id: 'child-origin', header: { origin: 'subagent' } }, turnEnd('completed'));
  handler({ id: 'child-parent', header: { parentSession: 'parent-x' } }, turnEnd('error'));
  assert.deepEqual(calls, [], 'no push for subagent child sessions');
  // Top-level sessions (and headerless test doubles) keep notifying.
  handler({ id: 'top-origin', header: { origin: 'top-level' } }, turnEnd('completed'));
  handler({ id: 'plain' }, turnEnd('completed'));
  handler({ id: 'top-parentless', header: { parentSession: '' } }, turnEnd('error'));
  assert.deepEqual(calls, [
    ['turn-end', 'top-origin'],
    ['turn-end', 'plain'],
    ['failure', 'top-parentless'],
  ]);
});

console.log('host-turn-events: GO ' + String(checks) + '/' + String(checks));
