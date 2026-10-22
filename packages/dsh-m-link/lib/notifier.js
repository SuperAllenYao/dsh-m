/**
 * notifier.js — read-only frame inspector that turns Remote events into APNs
 * notifications (approval arrival / turn end / turn failure).
 *
 * The bridge stays transparent: the frame is forwarded byte-for-byte, and this
 * inspector only parses a copy to decide whether a short push is worthwhile.
 * Notifications never contain message bodies, tool output or reasons — only the
 * event kind, tool name and session id.
 */

import { shortFingerprint } from './audit.js';
import { tokenFingerprint } from './apns.js';

const DEDUPE_LIMIT = 512;

/** iOS UNNotificationCategory identifier registered by the app for approvals. */
export const APPROVAL_CATEGORY = 'dshm-approval';

export class Notifier {
 /**
 * @param {{
 * devices: import('./devices.js').DeviceStore,
 * apns: import('./apns.js').ApnsProvider,
 * audit: import('./audit.js').AuditLog,
 * config: {
 * enabled?: boolean, approval?: boolean, turnEnd?: boolean, failure?: boolean,
 * questions?: boolean, silent?: boolean, silentMinIntervalMs?: number,
 * },
 * log?: (message: string) => void,
 * now?: => number,
 * }} options
 */
  constructor({ devices, apns, audit, config = {}, log = () => {}, now = () => Date.now() }) {
    this.devices = devices;
    this.apns = apns;
    this.audit = audit;
    this.config = {
      enabled: true,
      approval: true,
      turnEnd: true,
      failure: true,
      questions: true,
      silent: true,
      silentMinIntervalMs: 3000,
      ...config,
    };
    this.log = log;
    this.now = now;
    this.seen = new Set();
 /** deviceId -> last silent-push timestamp (M4 coalescing window). */
    this.lastSilentAt = new Map();
    this.queue = Promise.resolve();
  }

  dedupe(key) {
    if (this.seen.has(key)) return false;
    this.seen.add(key);
    if (this.seen.size > DEDUPE_LIMIT) this.seen.delete(this.seen.values().next().value);
    return true;
  }

 /** Inspect one upstream mux frame (text only) without modifying it. */
  observe(device, data, isBinary) {
    if (!this.config.enabled || isBinary) return;
    let frame;
    try {
      frame = JSON.parse(typeof data === 'string' ? data : data.toString('utf8'));
    } catch {
      return;
    }
    const value = frame?.type === 'item' ? frame.value : undefined;
    if (value === undefined || value === null) return;
    if (value.type === 'waterfall' && value.event === 'approval/request') {
      if (!this.config.approval || !this.dedupe('approval|' + String(value.eventId))) return;
      const toolName = typeof value.request?.toolName === 'string' ? value.request.toolName : 'tool';
      this.notify(device, {
        kind: 'approval',
        title: 'DSH 需要审批',
        body: '工具调用 ' + toolName + ' 等待你的确认',
        threadId: typeof value.agentId === 'string' ? value.agentId : undefined,
 // The category is what makes iOS render the 允许/拒绝 actions (M4).
        category: APPROVAL_CATEGORY,
        data: { type: 'approval', toolName, eventId: value.eventId, sessionId: value.agentId },
      });
      return;
    }
    if (value.type === 'waterfall' && value.event === 'user-questions/request') {
      if (!this.config.questions || !this.dedupe('question|' + String(value.eventId))) return;
      const questions = Array.isArray(value.request?.questions) ? value.request.questions : [];
 // A waterfall without usable questions can only open an empty card; the
 // iOS side treats it as not answerable as well (StreamFrames P1-4).
      if (questions.length === 0) return;
      this.notify(device, {
        kind: 'question',
        title: 'DSH 需要你的回答',
        body: questions.length === 1 ? '有 1 个问题等待你回答' : '有 ' + String(questions.length) + ' 个问题等待你回答',
        threadId: typeof value.agentId === 'string' ? value.agentId : undefined,
        data: {
          type: 'question',
          eventId: value.eventId,
          sessionId: value.agentId,
          questionCount: questions.length,
        },
      });
      return;
    }
    if (value.type === 'event' && value.event?.type === 'turn/end') {
      const event = value.event;
      const reasonKind = event.data?.reason?.kind ?? 'completed';
      const key = 'turn|' + String(event.data?.sessionId ?? '') + '|' + String(event.seq);
      if (!this.dedupe(key)) return;
      if (reasonKind === 'completed') {
        if (!this.config.turnEnd) return;
        this.notify(device, {
          kind: 'turn-end',
          title: 'DSH 回合完成',
          body: '任务已在 Mac 上完成',
          data: { type: 'turn-end', sessionId: event.data?.sessionId },
        });
        return;
      }
      if (reasonKind === 'error') {
        if (!this.config.failure) return;
        this.notify(device, {
          kind: 'failure',
          title: 'DSH 回合失败',
          body: '任务执行出错，打开 App 查看详情',
          data: { type: 'failure', sessionId: event.data?.sessionId },
        });
      }
      return;
    }
  }

 /** Stop accepting new notifications and drop dedupe state (dispose path). */
  dispose() {
    this.seen.clear();
    this.lastSilentAt.clear();
    this.queue = Promise.resolve();
  }

  notify(device, { kind, title, body, threadId, data, category }) {
    const delivery = this.apns.mode === 'ready' ? 'push' : this.apns.mode;
    this.audit.record('notify.' + kind, {
      deviceId: device.deviceId,
      delivery,
      pushToken: device.pushToken === undefined ? 'none' : tokenFingerprint(device.pushToken),
 // A short correlation fingerprint only — never the event payload.
      ref: shortFingerprint(String(data?.eventId ?? data?.sessionId ?? '')),
    });
    if (device.pushToken === undefined) return;
    this.queue = this.queue
      .then(() => this.apns.send({
        deviceToken: device.pushToken,
        environment: device.pushEnvironment,
        topic: this.apns.topic,
        title,
        body,
        threadId,
        data,
        category,
      }))
      .then((result) => {
        if (result.ok === false) this.log('APNs send failed (' + kind + '): ' + String(result.error));
      })
      .catch((error) => this.log('APNs send failed (' + kind + '): ' + String(error?.message ?? error)));
    this.sendSilent(device, kind, data);
  }

 /**
 * M4: background refresh push (content-available) for the same key events.
 *
 * Coalesced per device with `silentMinIntervalMs` so a burst of turn-ends does
 * not burn the iOS background budget; the alert push above is never coalesced.
 * The payload is `{aps:{"content-available":1}, type:"sync", reason, sessionId?}`
 * — iOS refreshes data only, it never answers/approves from a silent push.
 */
  sendSilent(device, kind, data) {
    if (this.config.silent !== true) return;
    if (device.pushToken === undefined) return;
    const now = this.now();
    const last = this.lastSilentAt.get(device.deviceId);
 // The first silent push for a device always goes out; only a burst inside
 // the window is coalesced.
    if (last !== undefined && now - last < this.config.silentMinIntervalMs) return;
    this.lastSilentAt.set(device.deviceId, now);
    this.audit.record('notify.sync', {
      deviceId: device.deviceId,
      delivery: this.apns.mode === 'ready' ? 'push' : this.apns.mode,
      reason: kind,
      ref: shortFingerprint(String(data?.eventId ?? data?.sessionId ?? '')),
    });
    this.queue = this.queue
      .then(() => this.apns.send({
        deviceToken: device.pushToken,
        environment: device.pushEnvironment,
        topic: this.apns.topic,
        silent: true,
        data: {
          type: 'sync',
          reason: kind,
          ...(data?.sessionId === undefined ? {} : { sessionId: data.sessionId }),
          ...(data?.eventId === undefined ? {} : { eventId: data.eventId }),
        },
      }))
      .then((result) => {
        if (result.ok === false) this.log('APNs silent send failed (' + kind + '): ' + String(result.error));
      })
      .catch((error) => this.log('APNs silent send failed (' + kind + '): ' + String(error?.message ?? error)));
  }
}