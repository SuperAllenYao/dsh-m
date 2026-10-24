/**
 * session-watcher.js — host-side turn watcher (task-5).
 *
 * Why: the APNs notifier used to learn about `turn/end` only from a phone's
 * `session/follow` frame stream. When the App is on the workspace list, in the
 * background while not following that session, or killed, there is no stream —
 * and therefore no "round finished" push. The user requirement is explicit:
 * a turn-completion notification must be delivered no matter what the phone is
 * doing (or not doing), and tapping it must jump straight to that session.
 *
 * Design: poll `session/list` over the plugin's loopback unary channel (the same
 * target the phone proxy uses, with a device peer cookie) every
 * `pollIntervalMs` and remember which sessions report `running`. A session that
 * was running and is now idle completed a turn -> notify every device that has a
 * push token. The first successful poll only establishes the baseline, so
 * sessions that were already running when the watcher started are not notified
 * by mistake.
 *
 * Everything is injectable (devices, fetch, notify, clock/timers) and the diff
 * itself is pure, so `test/turn-watcher.mjs` runs with no network, no APNs and
 * no real timers.
 */

/** Default poll cadence (approved default). */
export const DEFAULT_POLL_INTERVAL_MS = 2000;
/** Per-request budget: a stuck session/list must never pile up polls. */
export const DEFAULT_REQUEST_TIMEOUT_MS = 1500;

/**
 * Set of session ids that report `running === true` in one session/list
 * snapshot. Mirrors the App's list model (`SessionListItem.running`); rows
 * without a usable id or with a non-boolean running flag are ignored.
 *
 * @param {unknown} items session/list `items` array (or the value object).
 * @returns {Set<string>}
 */
export function sessionRunningState(items) {
  const list = Array.isArray(items) ? items : Array.isArray(items?.items) ? items.items : [];
  const running = new Set();
  for (const item of list) {
    if (item === null || typeof item !== 'object') continue;
    if (typeof item.sessionId !== 'string' || item.sessionId.length === 0) continue;
 // Only top-level sessions: subagent/teammate children never push.
    if (isSubagentSessionItem(item)) continue;
    if (item.running === true) running.add(item.sessionId);
  }
  return running;
}

/**
 * `session/list` snapshot -> session title info (`sessionId -> {title, blank}`).
 *
 * User requirement: alerts are titled with the title of the session
 * that triggered them (the desktop card title, `projections.values.title`). The
 * watcher already polls the list every tick, so it is the cheapest place to
 * cache that title and hand it to the notification callback.
 *
 * Unlike `sessionRunningState`, this keeps **every** row (subagent children
 * included): approval/question pushes deep-link to a child session and should
 * still show its title. Rows without a usable id are ignored; `title` may be
 * undefined (callers fall back to the App-list wording) and `blank` is true
 * only when the row explicitly says so.
 *
 * @param {unknown} items session/list `items` array (or the value object); rows
 * are the trimmed shape produced by LinkServer.fetchSessionListForWatcher
 * (`{sessionId, running, title?, blank?}`).
 * @returns {Map<string, {title?: string, blank?: boolean}>}
 */
export function sessionTitleInfo(items) {
  const list = Array.isArray(items) ? items : Array.isArray(items?.items) ? items.items : [];
  const titles = new Map();
  for (const item of list) {
    if (item === null || typeof item !== 'object') continue;
    if (typeof item.sessionId !== 'string' || item.sessionId.length === 0) continue;
    titles.set(item.sessionId, {
      title: typeof item.title === 'string' ? item.title : undefined,
      blank: item.blank === true,
    });
  }
  return titles;
}

/**
 * Diff the previous running set against a fresh snapshot.
 *
 * - `ended`: was running, still listed, now idle -> a completed turn (notify);
 * - `dropped`: was running, no longer listed -> do NOT notify (the deep link
 * target is gone; e.g. the session was deleted between polls);
 * - `running`: the new set to remember.
 *
 * Pure so the transition rule is unit-tested instead of only observed live.
 *
 * `titles` is the snapshot's full title map (see `sessionTitleInfo`), so the
 * caller can title the push with the title of the session that just ended
 * without a second `session/list` read.
 *
 * @param {Set<string>|undefined} previousRunning
 * @param {unknown} items
 * @returns {{running: Set<string>, ended: string[], dropped: string[], titles: Map<string, {title?: string, blank?: boolean}>}}
 */
export function diffRunningSessions(previousRunning, items) {
  const list = Array.isArray(items) ? items : Array.isArray(items?.items) ? items.items : [];
  const running = sessionRunningState(list);
  const titles = sessionTitleInfo(list);
  const listed = new Set();
  for (const item of list) {
    if (item !== null && typeof item === 'object' && typeof item.sessionId === 'string') {
      if (isSubagentSessionItem(item)) continue;
      listed.add(item.sessionId);
    }
  }
  const ended = [];
  const dropped = [];
  for (const sessionId of previousRunning ?? []) {
    if (running.has(sessionId)) continue;
    if (listed.has(sessionId)) ended.push(sessionId);
    else dropped.push(sessionId);
  }
  return { running, ended, dropped, titles };
}

/**
 * Watch only when a device can actually receive a push and turn-end
 * notifications are enabled. Pure (config + device list in, boolean out).
 *
 * @param {{notifications?: Record<string, unknown>, devices?: unknown[]}} input
 */
export function shouldWatchSessions({ notifications = {}, devices = [] } = {}) {
  if (notifications.enabled === false) return false;
  if (notifications.turnEnd === false) return false;
  if (notifications.watchSessions === false) return false;
  if (!Array.isArray(devices)) return false;
  return devices.some(
    (device) =>
      device !== null &&
      typeof device === 'object' &&
      typeof device.pushToken === 'string' &&
      device.pushToken.length > 0
  );
}

/**
 * Polls session/list and notifies on running -> idle transitions.
 *
 * The host wiring supplies `listDevices` (active devices with a push token),
 * `fetchSessionList(device)` (loopback session/list) and
 * `notifyTurnEnd(sessionId, titleInfo)` (fan-out to every push-token device;
 * `titleInfo` is the ended session's `{title, blank}` from the same snapshot, so
 * the push can be titled with the session title without another list read).
 * `sync()` starts/stops the timer as devices come and go; `pollOnce()` is the
 * test seam.
 */
export class TurnWatcher {
  constructor({
    listDevices = () => [],
    fetchSessionList = async () => [],
    notifyTurnEnd = () => {},
    isAvailable = () => true,
    config = {},
    log = () => {},
    setIntervalFn = setInterval,
    clearIntervalFn = clearInterval,
    setTimeoutFn = setTimeout,
    clearTimeoutFn = clearTimeout,
  } = {}) {
    this.listDevices = listDevices;
    this.fetchSessionList = fetchSessionList;
    this.notifyTurnEnd = notifyTurnEnd;
    this.isAvailable = isAvailable;
    this.config = config;
    this.log = log;
    this.setIntervalFn = setIntervalFn;
    this.clearIntervalFn = clearIntervalFn;
    this.setTimeoutFn = setTimeoutFn;
    this.clearTimeoutFn = clearTimeoutFn;
    this.pollIntervalMs =
      Number.isInteger(config.pollIntervalMs) && config.pollIntervalMs >= 250
        ? config.pollIntervalMs
        : DEFAULT_POLL_INTERVAL_MS;
    this.requestTimeoutMs =
      Number.isInteger(config.requestTimeoutMs) && config.requestTimeoutMs >= 100
        ? config.requestTimeoutMs
        : DEFAULT_REQUEST_TIMEOUT_MS;
    this.timer = undefined;
    this.polling = false;
    this.primed = false;
 /** @type {Set<string>} */
    this.running = new Set();
 /**
 * sessionId -> {title, blank} from the last snapshot, so pushes
 * can be titled with the triggering session's title (desktop card title).
 * @type {Map<string, {title?: string, blank?: boolean}>}
 */
    this.titles = new Map();
 /** Last error message, so a repeated failure does not spam the log. */
    this.lastError = undefined;
  }

 /** Title info cached from the last successful poll (undefined when unknown). */
  titleInfoFor(sessionId) {
    if (typeof sessionId !== 'string' || sessionId.length === 0) return undefined;
    return this.titles.get(sessionId);
  }

 /** True while the polling timer is armed (used to suppress frame-path pushes). */
  get active() {
    return this.timer !== undefined;
  }

 /** Start/stop polling for the current device set (called on device changes). */
  sync() {
    const devices = this.safeListDevices();
    const shouldWatch = shouldWatchSessions({ notifications: this.config, devices });
    if (!shouldWatch) {
      if (this.active) {
        this.stop();
        this.log('turn watcher stopped (no push-token device / notifications off)');
      }
      return false;
    }
    if (this.active) return true;
    this.primed = false;
    this.running = new Set();
    this.titles = new Map();
    this.lastError = undefined;
    this.timer = this.setIntervalFn(() => {
      void this.pollOnce();
    }, this.pollIntervalMs);
    if (typeof this.timer?.unref === 'function') this.timer.unref();
    this.log('turn watcher started (poll ' + String(this.pollIntervalMs) + 'ms)');
    void this.pollOnce();
    return true;
  }

  stop() {
    if (this.timer !== undefined) {
      this.clearIntervalFn(this.timer);
      this.timer = undefined;
    }
    this.primed = false;
    this.running = new Set();
    this.titles = new Map();
    this.polling = false;
  }

  dispose() {
    this.stop();
  }

 /**
 * One poll cycle. Never throws: transport/host errors are logged (state
 * changes only) and the next interval retries.
 *
 * @returns {Promise<{skipped?: string, primed?: boolean, ended?: string[], dropped?: string[], error?: string}>}
 */
  async pollOnce() {
    if (!this.active) return { skipped: 'inactive' };
    if (this.polling) return { skipped: 'busy' };
    const devices = this.safeListDevices();
    if (!shouldWatchSessions({ notifications: this.config, devices })) {
      this.stop();
      return { skipped: 'no-devices' };
    }
    let available = false;
    try {
      available = this.isAvailable() === true;
    } catch {
      available = false;
    }
    if (!available) return { skipped: 'host-inactive' };
    const device = devices.find((candidate) => typeof candidate?.pushToken === 'string');
    if (device === undefined) return { skipped: 'no-devices' };
    this.polling = true;
    try {
      const items = await this.withTimeout(this.fetchSessionList(device));
      if (!this.primed) {
 // Baseline: sessions already running when the watcher started must not
 // be reported as "just finished" on the first diff.
        this.running = sessionRunningState(items);
        this.titles = sessionTitleInfo(items);
        this.primed = true;
        this.clearError();
        return { primed: true };
      }
      const { running, ended, dropped, titles } = diffRunningSessions(this.running, items);
      this.running = running;
      this.titles = titles;
      this.clearError();
      for (const sessionId of ended) {
        try {
 // hand the session title over with the sessionId so the
 // push is titled with the session, not with the fixed type label.
          this.notifyTurnEnd(sessionId, titles.get(sessionId));
        } catch (error) {
          this.log('turn watcher notify failed: ' + String(error?.message ?? error));
        }
      }
      return { ended, dropped };
    } catch (error) {
      this.noteError(String(error?.message ?? error));
      return { error: String(error?.message ?? error) };
    } finally {
      this.polling = false;
    }
  }

  safeListDevices() {
    try {
      const devices = this.listDevices();
      return Array.isArray(devices) ? devices : [];
    } catch {
      return [];
    }
  }

  withTimeout(promise) {
    return new Promise((resolve, reject) => {
      let settled = false;
      const timer = this.setTimeoutFn(() => {
        if (settled) return;
        settled = true;
        reject(new Error('turn-watch session/list timeout after ' + String(this.requestTimeoutMs) + 'ms'));
      }, this.requestTimeoutMs);
      if (typeof timer?.unref === 'function') timer.unref();
      Promise.resolve(promise).then(
        (value) => {
          if (settled) return;
          settled = true;
          this.clearTimeoutFn(timer);
          resolve(value);
        },
        (error) => {
          if (settled) return;
          settled = true;
          this.clearTimeoutFn(timer);
          reject(error);
        }
      );
    });
  }

  noteError(message) {
    if (message !== this.lastError) {
      this.lastError = message;
      this.log('turn watcher poll failed: ' + message);
    }
  }

  clearError() {
    this.lastError = undefined;
  }
}

/**
 * task-5b: kind of notification a durable session event should produce, or
 * undefined when the event is not a finished turn. Only `completed` and
 * `error` turns notify (aborted/interrupted turns are user-visible in the app).
 *
 * The host emits every durable event on `ctx.on('session/event', (session,
 * event))`; this is the in-process, real-time source that works whether or not
 * any phone is connected or following the session.
 */
export function hostTurnEndKind(event) {
  if (event === null || typeof event !== 'object' || event.type !== 'turn/end') return undefined;
  const kind = event.data?.reason?.kind ?? 'completed';
  if (kind === 'completed') return 'turn-end';
  if (kind === 'error') return 'failure';
  return undefined;
}

/**
 * Build the `session/event` subscriber used by LinkServer.
 *
 * @param {{
 * notifyTurnEnd: (sessionId: string) => void,
 * notifyFailure?: (sessionId: string) => void,
 * config?: { turnEnd?: boolean, failure?: boolean, enabled?: boolean },
 * isEnabled?: => boolean,
 * }} options
 */
export function createHostTurnEventHandler({
  notifyTurnEnd = () => {},
  notifyFailure = () => {},
  config = {},
  isEnabled = () => true,
} = {}) {
  return (session, event) => {
    try {
      if (isEnabled() !== true) return;
      if (config.enabled === false) return;
      const kind = hostTurnEndKind(event);
      if (kind === undefined) return;
      const sessionId = session?.id;
      if (typeof sessionId !== 'string' || sessionId.length === 0) return;
 // User decision: only top-level sessions notify. Subagent /
 // teammate child sessions are internal to the parent's turn; pushing them
 // made a turn-end tap open the child session out of context (blank page /
 // "Turn 2 stuck at the bottom" on the phone).
      if (isSubagentSession(session)) return;
      if (kind === 'turn-end') {
        if (config.turnEnd === false) return;
        notifyTurnEnd(sessionId);
        return;
      }
      if (config.failure === false) return;
      notifyFailure(sessionId);
    } catch {
 /* the host event bus must never break the link */
    }
  };
}
/**
 * True when a Host `Session` (the object handed to `ctx.on('session/event')`)
 * is a subagent / teammate child.
 *
 * User decision: turn-end pushes go to **top-level sessions only**.
 * The Host's durable session header carries `origin: 'subagent'` and/or
 * `parentSession` for delegated sessions (see dsh-session header validation).
 *
 * @param {{header?: {origin?: unknown, parentSession?: unknown}}|null|undefined} session
 * @returns {boolean}
 */
export function isSubagentSession(session) {
  const header = session?.header;
  if (header === null || typeof header !== 'object') return false;
  if (header.origin === 'subagent') return true;
  return typeof header.parentSession === 'string' && header.parentSession.length > 0;
}

/**
 * True when one `session/list` row describes a subagent / teammate child.
 * `session/list` exposes `parentSessionId` (header.parentSession) and the
 * optional `origin`; the turn watcher keeps those two fields for that reason.
 *
 * @param {unknown} item
 * @returns {boolean}
 */
export function isSubagentSessionItem(item) {
  if (item === null || typeof item !== 'object') return false;
  if (item.origin === 'subagent') return true;
  return typeof item.parentSessionId === 'string' && item.parentSessionId.length > 0;
}
