#!/usr/bin/env node
/**
 * notifier-session-id.mjs — regression for the turn-end push deep link.
 *
 * 用户报障（2026-10-22）：点"turn 完成"通知只进入工作区列表。根因是 turn/end
 * 事件数据里没有 sessionId，notifier 之前直接读 event.data.sessionId 得到
 * undefined，payload 丢了深链。现在从 session/follow 的 open 帧建立
 * stream -> session 映射，并用它补上 sessionId（同时按会话去重）。
 */
import assert from 'node:assert/strict';

const { Notifier } = await import('../lib/notifier.js');

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
});
const device = { deviceId: 'dev-1', pushToken: 'f'.repeat(64), pushEnvironment: 'sandbox' };

const open = (streamId, sessionId) => JSON.stringify({
  type: 'open',
  streamId,
  endpoint: 'session/follow',
  payload: { args: { request: { address: { kind: 'session', sessionId }, assistantStream: true, maxMessages: 20 } } },
});
const turnEnd = (streamId, seq) => JSON.stringify({
  type: 'item',
  streamId,
  value: { type: 'event', event: { type: 'turn/end', seq, data: { turn: 3, reason: { kind: 'completed' } } } },
});

// 1) 手机打开 session/follow 流（open 帧在设备 -> Host 方向）。
notifier.observeDevice(device, open('st-1', 'session-abc'), false);
// 2) Host 推送 turn/end（事件数据里没有 sessionId）。
notifier.observe(device, turnEnd('st-1', 42), false);
await notifier.queue;

assert.equal(sent.length, 1, 'turn-end push sent');
assert.equal(sent[0].data.type, 'turn-end');
assert.equal(sent[0].data.sessionId, 'session-abc', 'turn-end push must carry the session deep link');
assert.equal(sent[0].threadId, 'session-abc', 'thread id groups notifications per session');

// 3) 另一个会话里同样的 seq 不能被去重吞掉（旧 dedupe key 没有 sessionId）。
notifier.observeDevice(device, open('st-2', 'session-def'), false);
notifier.observe(device, turnEnd('st-2', 42), false);
await notifier.queue;
assert.equal(sent.length, 2, 'same seq from another session still notifies');
assert.equal(sent[1].data.sessionId, 'session-def');

// 4) 流结束后映射清掉：没有 sessionId 也不能猜一个过期的。
notifier.observeDevice(device, JSON.stringify({ type: 'end', streamId: 'st-2' }), false);
notifier.observe(device, turnEnd('st-2', 43), false);
await notifier.queue;
assert.equal(sent.length, 3, 'turn-end without a live stream still notifies');
assert.equal(sent[2].data.sessionId, undefined, 'no stale session id after the stream ended');

console.log('notifier-session-id: ok (' + sent.length + ' pushes)');
