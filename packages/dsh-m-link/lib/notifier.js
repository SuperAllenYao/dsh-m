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

/**
 * Session title information carried by a push (`session/list` row ->
 * `projections.values.title` + the row's `blank` flag).
 *
 * User requirement: the alert **title** must be the title of the
 * session that triggered the push (the desktop session-card title), and only the
 * **body** describes the event. A session id alone is not enough — the title is
 * looked up through `resolveSessionTitle`.
 *
 * @typedef {{title?: unknown, blank?: unknown}} SessionTitleInfo
 */

/**
 * Pure: pick the alert title for a session.
 *
 * - `info` missing (no row / not polled yet) -> keep the fixed type title
 * ("DSH 回合完成"), so an old host or a cold cache never produces an empty
 * notification title;
 * - a non-empty title -> that title (desktop card title);
 * - an empty/blank title -> same wording as the App session list
 * (`apps/ios/DSHm/Protocol/RemoteModels.swift`, `displayTitle`):
 * "新会话" when the row is blank, "未命名会话" otherwise.
 *
 * @param {SessionTitleInfo|null|undefined} info
 * @param {string} fallback fixed type title used when no title info exists
 * @returns {string}
 */
export function pushTitleForSession(info, fallback) {
  if (info === null || typeof info !== 'object') return fallback;
  const title = typeof info.title === 'string' ? info.title.trim() : '';
  if (title.length > 0) return title;
  return info.blank === true ? '新会话' : '未命名会话';
}

/**
 * Session id carried by a session-follow open frame
 * (`{type:'open', streamId, endpoint, payload:{args:{request:{address}}}}').
 * Orders of preference: normal session address, subagent child address, then
 * the flat legacy shapes some clients still send.
 */
function sessionIdFromOpenFrame(frame) {
  if (typeof frame.endpoint === 'string' && !frame.endpoint.includes('session')) return undefined;
  const args = frame.payload?.args;
  const address = args?.request?.address ?? args?.address;
  const candidates = [address?.sessionId, address?.childSessionId, args?.request?.sessionId, args?.sessionId];
  for (const candidate of candidates) {
    if (typeof candidate === 'string' && candidate.length > 0) return candidate;
  }
  return undefined;
}

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
 * isTurnEndWatched?: (device) => boolean,
 * resolveSessionTitle?: (sessionId: string) => Promise<SessionTitleInfo|undefined>|SessionTitleInfo|undefined,
 * }} options
 *
 * `resolveSessionTitle` is the session-title source: the caller
 * (link-server) resolves the title of the session that triggered the push from
 * its `session/list` cache, refreshing it on demand. It may be async — the
 * alert is already queued behind `this.queue`, so resolving there never blocks
 * the frame bridge.
 */
  constructor({
    devices,
    apns,
    audit,
    config = {},
    log = () => {},
    now = () => Date.now(),
    isTurnEndWatched = () => false,
    resolveSessionTitle = () => undefined,
  }) {
 /** Session-title resolver (see the constructor JSDoc above). */
    this.resolveSessionTitle =
      typeof resolveSessionTitle === 'function' ? resolveSessionTitle : () => undefined;
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
 /**
 * task-5: true while the host-side TurnWatcher owns turn-end delivery for the
 * device (a push-token device is being polled), so the frame path must stay
 * quiet and not double-push. Approval/question frames are unaffected.
 */
    this.isTurnEndWatched = typeof isTurnEndWatched === 'function' ? isTurnEndWatched : () => false;
    this.seen = new Set();
 /** deviceId -> last silent-push timestamp (M4 coalescing window). */
    this.lastSilentAt = new Map();
 /**
 * deviceId|streamId -> sessionId（来自手机侧的 open 帧）。
 * turn/end 事件本身不带 sessionId，通知要深链到会话就必须从 follow 流映射出来。
 */
    this.streamSessions = new Map();
    this.queue = Promise.resolve();
  }

  dedupe(key) {
    if (this.seen.has(key)) return false;
    this.seen.add(key);
    if (this.seen.size > DEDUPE_LIMIT) this.seen.delete(this.seen.values().next().value);
    return true;
  }

 /**
 * Inspect one **device → Host** frame (text only, never modified) to learn the
 * session behind each stream. `turn/end` events carry no sessionId, so a
 * turn-end notification would otherwise deep-link nowhere (user report
 * tapping it opened the workspace list instead of the session).
 */
  observeDevice(device, data, isBinary) {
    if (!this.config.enabled || isBinary) return;
    let frame;
    try {
      frame = JSON.parse(typeof data === 'string' ? data : data.toString('utf8'));
    } catch {
      return;
    }
    if (frame === null || typeof frame !== 'object') return;
    const streamId = typeof frame.streamId === 'string' ? frame.streamId : undefined;
    if (streamId === undefined) return;
    const key = device.deviceId + '|' + streamId;
    if (frame.type === 'open') {
      const sessionId = sessionIdFromOpenFrame(frame);
      if (sessionId === undefined) this.streamSessions.delete(key);
      else this.streamSessions.set(key, sessionId);
      return;
    }
    if (frame.type === 'end' || frame.type === 'cancel' || frame.type === 'error') {
      this.streamSessions.delete(key);
    }
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
      const sessionId = typeof value.agentId === 'string' ? value.agentId : undefined;
      this.notify(device, {
        kind: 'approval',
 // title = the triggering session's title, body = the event.
        title: 'DSH 需要审批',
        titleSessionId: sessionId,
        body: '工具调用 ' + toolName + ' 等待你的确认',
        threadId: sessionId,
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
      const sessionId = typeof value.agentId === 'string' ? value.agentId : undefined;
      this.notify(device, {
        kind: 'question',
        title: 'DSH 需要你的回答',
        titleSessionId: sessionId,
        body: questions.length === 1 ? '有 1 个问题等待你回答' : '有 ' + String(questions.length) + ' 个问题等待你回答',
        threadId: sessionId,
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
      const streamId = typeof frame.streamId === 'string' ? frame.streamId : undefined;
      const sessionId =
        typeof event.data?.sessionId === 'string' && event.data.sessionId.length > 0
          ? event.data.sessionId
          : (streamId === undefined ? undefined : this.streamSessions.get(device.deviceId + '|' + streamId));
 // task-5 (user requirement): turn-end delivery must not depend on the phone
 // following the session. When the host-side TurnWatcher is polling (a
 // push-token device exists), it owns turn-end notifications and this frame
 // path stays quiet so the device is not pushed twice.
      if (reasonKind === 'completed' && this.isTurnEndWatched(device)) return;
      const key = 'turn|' + String(sessionId ?? '') + '|' + String(event.seq);
      if (!this.dedupe(key)) return;
      if (reasonKind === 'completed') {
        if (!this.config.turnEnd) return;
        this.notify(device, {
          kind: 'turn-end',
          title: 'DSH 回合完成',
          titleSessionId: sessionId,
 // Title carries the session; the body only describes the event.
          body: '回合完成',
          threadId: sessionId,
          data: { type: 'turn-end', sessionId },
        });
        return;
      }
      if (reasonKind === 'error') {
        if (!this.config.failure) return;
        this.notify(device, {
          kind: 'failure',
          title: 'DSH 回合失败',
          titleSessionId: sessionId,
 // The protocol has no error text on turn/end (only reason.kind), so
 // there is no cheap detail to append: report the event only.
          body: '回合失败',
          threadId: sessionId,
          data: { type: 'failure', sessionId },
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

 /**
 * Resolve the alert title for one push.
 *
 * `title` is the fixed type title kept as the fallback; `titleSessionId` is the
 * session the alert belongs to, resolved through `resolveSessionTitle`. The
 * resolver may be async (link-server refreshes its `session/list` title cache
 * on demand) — this runs inside the send queue, never on the bridge path.
 */
  async alertTitle(titleSessionId, fallbackTitle) {
    if (typeof titleSessionId !== 'string' || titleSessionId.length === 0) return fallbackTitle;
    let info;
    try {
      info = await this.resolveSessionTitle(titleSessionId);
    } catch {
      info = undefined;
    }
    return pushTitleForSession(info, fallbackTitle);
  }

  notify(device, { kind, title, titleSessionId, body, threadId, data, category, collapseId }) {
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
      .then(async () => this.apns.send({
        deviceToken: device.pushToken,
        environment: device.pushEnvironment,
        topic: this.apns.topic,
        title: await this.alertTitle(titleSessionId, title),
        body,
        threadId,
        data,
        category,
        collapseId,
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