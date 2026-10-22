/**
 * p1-mux-rpc.mjs — P1 single-WSS transport prototype tests (protocol engine).
 *
 * Covers the feature-flagged piece behind `config.features.muxRpc`:
 *   1. config defaults: off by default, limit normalization;
 *   2. hello negotiation (welcome shape, version/duplicate guards);
 *   3. unary RPC over the mux socket: correlation, concurrency, HTTP status,
 *      upstream failure, plugin timeout and the in-flight cap;
 *   4. upstream stream frames stay verbatim client→Mac, and get a transport
 *      sequence (`down{sid}`) Mac→client;
 *   5. `resume{logEpoch,sid}`: exact replay, epoch reset, eviction reset, phone
 *      frames pipelined before the upstream mux is ready;
 *   6. stateless resume tickets (mint/verify/tamper/expiry).
 *
 * Runs standalone (no DSH host, no TLS, no ~/.dsh):
 *   node test/p1-mux-rpc.mjs [--out-dir <dir>]
 */

import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { EventEmitter } from 'node:events';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

import { AuditLog } from '../lib/audit.js';
import { FrameAudit } from '../lib/frame-audit.js';
import { LinkServer } from '../lib/link-server.js';
import { mintResumeTicket, MuxRpcChannel, P1_LIMITS, ReplayLog, verifyResumeTicket } from '../lib/mux-rpc.js';

const DEFAULT_OUT = resolve(new URL('results', import.meta.url).pathname);
const sleep = (ms) => new Promise((done) => setTimeout(done, ms));
const checks = [];
const startedAt = Date.now();

function record(name, ok, detail) {
  checks.push({ name, ok: ok === true, detail });
  console.log((ok ? 'PASS ' : 'FAIL ') + name + (detail === undefined ? '' : ' — ' + JSON.stringify(detail)));
  if (!ok) throw new Error('check failed: ' + name);
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

async function waitFor(predicate, { timeoutMs = 3000, label = 'condition' } = {}) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const value = predicate();
    if (value) return value;
    await sleep(5);
  }
  throw new Error('timed out waiting for ' + label);
}

// ------------------------------------------------------------- channel harness

/** A channel wired to in-memory transport/upstream; no sockets, no TLS. */
function makeChannel({ limits, forwardUnary, issueTicket, epoch } = {}) {
  const state = { down: [], close: [], upstream: [] };
  const calls = { unary: [] };
  let channel;
  channel = new MuxRpcChannel({
    deviceId: 'dev-unit',
    epoch,
    limits,
    issueTicket,
    forwardUnary:
      forwardUnary ??
      (async (request) => {
        calls.unary.push(request);
        return { status: 200, contentType: 'application/json', bytes: Buffer.from(JSON.stringify({ type: 'server-response', result: { ok: true } })) };
      }),
  });
  channel.attachTransport({ send: (text) => state.down.push(text), close: (code, reason) => state.close.push({ code, reason }) });
  channel.attachUpstream({ send: (text) => state.upstream.push(text) });
  return { channel, state, calls };
}

function hello(channel, extra = {}) {
  channel.handleClient(JSON.stringify({ type: 'hello', v: 2, client: { name: 'unit' }, ...extra }));
}

function frames(state) {
  return state.down.map((text) => JSON.parse(text));
}

function lastFrame(state) {
  return JSON.parse(state.down[state.down.length - 1]);
}

function makeServerContext(home) {
  return {
    get(name) {
      if (name === 'dshHomePath') return home;
      return undefined;
    },
    webServer: { getOrigin: () => 'http://127.0.0.1:62001' },
    connection: { authenticatedUrl: (url) => url },
  };
}

// ----------------------------------------------------------------------- main

async function run() {
  const outDirArg = process.argv.indexOf('--out-dir');
  const outDir = outDirArg >= 0 ? resolve(process.argv[outDirArg + 1]) : DEFAULT_OUT;
  mkdirSync(outDir, { recursive: true });

  // ---------------------------------------------------------- 1. config defaults
  const home = mkdtempSync(join(tmpdir(), 'dshm-p1-unit-'));
  try {
    const defaults = new LinkServer(makeServerContext(home), { port: 3466, bindHost: '127.0.0.1' });
    assert(defaults.config.features.muxRpc === false, 'features.muxRpc must default to false');
    assert(defaults.config.features.muxRpcResumeWindowMs === P1_LIMITS.resumeWindowMs, 'resume window default');
    record('config-muxrpc-default-off', true, { muxRpc: defaults.config.features.muxRpc });

    const clamped = new LinkServer(makeServerContext(home), {
      port: 3466,
      features: { muxRpc: true, muxRpcReplayBytes: -1, muxRpcRpcMaxInFlight: 0, muxRpcResumeWindowMs: 45_000 },
    });
    assert(clamped.config.features.muxRpc === true, 'explicit muxRpc:true must survive');
    assert(clamped.config.features.muxRpcReplayBytes === P1_LIMITS.replayBytes, 'invalid byte cap falls back to the default');
    assert(clamped.config.features.muxRpcRpcMaxInFlight === P1_LIMITS.rpcMaxInFlight, 'invalid in-flight cap falls back');
    assert(clamped.config.features.muxRpcResumeWindowMs === 45_000, 'valid override kept');
    record('config-limit-normalization', true, clamped.config.features);

    // -------------------------------------------------------- 2. hello negotiation
    const first = makeChannel({ issueTicket: (epoch) => 'ticket:' + epoch });
    hello(first.channel, { auth: { muxToken: 'ignored-by-unit' } });
    const welcome = lastFrame(first.state);
    assert(welcome.type === 'welcome', 'first server frame must be welcome');
    assert(welcome.v === 2 && welcome.proto === 'dsh-m/2', 'welcome must negotiate dsh-m/2');
    assert(typeof welcome.epoch === 'string' && welcome.epoch.length >= 8, 'welcome must carry a logEpoch');
    assert(welcome.sid === 0, 'fresh channel starts at sid 0');
    assert(welcome.resume.ok === true && welcome.resume.mode === 'fresh', 'fresh hello resumes nothing');
    assert(welcome.caps.unary === true && welcome.caps.resume === true, 'welcome caps');
    assert(welcome.ticket === 'ticket:' + welcome.epoch, 'welcome carries the resume ticket');
    record('hello-welcome-shape', true, { epoch: welcome.epoch.slice(0, 8), sid: welcome.sid, caps: welcome.caps });

    // hello must be first: a stream frame before hello is a protocol error.
    const early = makeChannel({});
    early.channel.handleClient(JSON.stringify({ type: 'open', streamId: 's0', endpoint: '$events', payload: { args: {} } }));
    assert(early.state.close.length === 1 && early.state.close[0].code === 4408, 'prevents pre-hello frames');
    record('hello-must-be-first', true, early.state.close[0]);

    // Unsupported version and duplicate hello both close the socket.
    const badVersion = makeChannel({});
    badVersion.channel.handleClient(JSON.stringify({ type: 'hello', v: 1 }));
    assert(badVersion.state.close[0]?.code === 4400, 'v1 hello rejected with 4400');
    const duplicate = makeChannel({});
    hello(duplicate.channel);
    hello(duplicate.channel);
    assert(duplicate.state.close.length === 1 && duplicate.state.close[0].code === 4400, 'duplicate hello rejected');
    record('hello-version-and-duplicate-guards', true, { v1: badVersion.state.close[0], duplicate: duplicate.state.close[0] });

    // ------------------------------------------------- 3. streams + transport seq
    const stream = makeChannel({});
    hello(stream.channel);
    stream.channel.handleClient(JSON.stringify({ type: 'open', streamId: 's1', endpoint: 'session/follow', payload: { args: {} } }));
    assert(stream.state.upstream.length === 1, 'open frame forwarded upstream');
    assert(stream.state.upstream[0] === JSON.stringify({ type: 'open', streamId: 's1', endpoint: 'session/follow', payload: { args: {} } }), 'client→upstream frames stay byte-identical');
    stream.channel.onUpstreamMessage(JSON.stringify({ type: 'item', streamId: 's1', value: { type: 'snapshot', cursor: 2 } }));
    stream.channel.onUpstreamMessage(JSON.stringify({ type: 'item', streamId: 's1', value: { type: 'event', event: { seq: 3 } } }));
    const down = frames(stream.state).filter((frame) => frame.type === 'down');
    assert(down.length === 2, 'two upstream frames delivered');
    assert(down[0].sid === 1 && down[1].sid === 2, 'transport sid increments per connection');
    assert(down[1].frame.type === 'item' && down[1].frame.streamId === 's1', 'down.frame is the verbatim upstream frame');
    stream.channel.handleClient(JSON.stringify({ type: 'ping', ts: 7 }));
    assert(lastFrame(stream.state).type === 'pong' && lastFrame(stream.state).ts === 7, 'app-level ping→pong');
    record('stream-passthrough-and-tseq', true, { sids: down.map((frame) => frame.sid), upstreamBytes: stream.state.upstream[0].length });

    // ------------------------------------------------------ 4. unary over the mux
    let unaryCalls = 0;
    const unary = makeChannel({
      forwardUnary: async ({ endpoint, bodyText }) => {
        unaryCalls += 1;
        assert(endpoint === 'session/list', 'endpoint forwarded to the unary forwarder');
        const parsed = JSON.parse(bodyText);
        assert(parsed.type === 'client-request' && parsed.method === 'session/list', 'client-request body preserved');
        return {
          status: 200,
          contentType: 'application/json; charset=utf-8',
          bytes: Buffer.from(JSON.stringify({ type: 'server-response', rpcId: parsed.rpcId, result: { ok: true, value: { sessions: 2 } } })),
        };
      },
    });
    hello(unary.channel);
    const rpcId = 'rpc-1';
    unary.channel.handleClient(
      JSON.stringify({ type: 'rpc', id: rpcId, endpoint: 'session/list', body: { type: 'client-request', rpcId, method: 'session/list', payload: { args: {} } } })
    );
    const result = await waitFor(() => frames(unary.state).find((frame) => frame.type === 'rpc/result'), { label: 'rpc/result' });
    assert(result.id === rpcId && result.status === 200, 'rpc result correlates by id and keeps HTTP status');
    assert(result.body?.type === 'server-response' && result.body.result.ok === true, 'JSON body is delivered parsed');
    record('rpc-unary-happy-path', true, { id: result.id, status: result.status, unaryCalls });

    // Concurrent calls resolve out of order yet correlate by id.
    const concurrent = makeChannel({
      forwardUnary: async ({ bodyText }) => {
        const parsed = JSON.parse(bodyText);
        const delay = parsed.payload.args.delay;
        await sleep(delay);
        return { status: 200, contentType: 'application/json', bytes: Buffer.from(JSON.stringify({ id: parsed.rpcId })) };
      },
    });
    hello(concurrent.channel);
    for (const [id, delay] of [['slow', 40], ['fast', 0]]) {
      concurrent.channel.handleClient(
        JSON.stringify({ type: 'rpc', id, endpoint: 'session/page', body: { type: 'client-request', rpcId: id, method: 'session/page', payload: { args: { delay } } } })
      );
    }
    await waitFor(() => frames(concurrent.state).filter((frame) => frame.type === 'rpc/result').length === 2, { label: 'two results' });
    const results = frames(concurrent.state).filter((frame) => frame.type === 'rpc/result');
    assert(results[0].id === 'fast' && results[1].id === 'slow', 'out-of-order completion keeps caller correlation');
    record('rpc-concurrent-correlation', true, results.map((frame) => frame.id));

    // Upstream failure and plugin timeout become rpc/error frames.
    const failing = makeChannel({
      forwardUnary: async () => {
        throw new Error('upstream connect failed');
      },
    });
    hello(failing.channel);
    failing.channel.handleClient(JSON.stringify({ type: 'rpc', id: 'boom', endpoint: 'session/list', body: { type: 'client-request', rpcId: 'boom', method: 'session/list', payload: { args: {} } } }));
    const failure = await waitFor(() => frames(failing.state).find((frame) => frame.type === 'rpc/error'), { label: 'rpc/error' });
    assert(failure.id === 'boom' && failure.error.code === 'upstream/failed', 'upstream failure maps to rpc/error');
    record('rpc-upstream-error', true, failure.error);

    const hanging = makeChannel({
      limits: { rpcTimeoutMs: 25 },
      forwardUnary: () => new Promise(() => {}),
    });
    hello(hanging.channel);
    hanging.channel.handleClient(JSON.stringify({ type: 'rpc', id: 'hang', endpoint: 'session/list', body: { type: 'client-request', rpcId: 'hang', method: 'session/list', payload: { args: {} } } }));
    const timedOut = await waitFor(() => frames(hanging.state).find((frame) => frame.type === 'rpc/error'), { label: 'timeout' });
    assert(timedOut.error.code === 'rpc/timeout', 'plugin-side deadline yields rpc/timeout');
    assert(hanging.channel.inflight.size === 0, 'timed-out call is removed from the in-flight table');
    record('rpc-timeout', true, timedOut.error);

    const capped = makeChannel({ limits: { rpcMaxInFlight: 1 }, forwardUnary: () => new Promise(() => {}) });
    hello(capped.channel);
    for (const id of ['a', 'b']) {
      capped.channel.handleClient(JSON.stringify({ type: 'rpc', id, endpoint: 'session/list', body: { type: 'client-request', rpcId: id, method: 'session/list', payload: { args: {} } } }));
    }
    const busy = frames(capped.state).find((frame) => frame.type === 'rpc/error');
    assert(busy?.error.code === 'rpc/busy', 'second call over the cap is rejected with rpc/busy');
    record('rpc-inflight-cap', true, busy.error);

    const badEndpoint = makeChannel({});
    hello(badEndpoint.channel);
    badEndpoint.channel.handleClient(JSON.stringify({ type: 'rpc', id: 'e', endpoint: 'not-an-endpoint', body: {} }));
    assert(lastFrame(badEndpoint.state).error.code === 'rpc/bad-endpoint', 'malformed endpoint rejected');
    record('rpc-endpoint-validation', true, lastFrame(badEndpoint.state).error);

    // ------------------------------------------------------------- 5. resume
    const resumed = makeChannel({});
    hello(resumed.channel);
    const resumedWelcome = lastFrame(resumed.state);
    for (let index = 1; index <= 3; index += 1) {
      resumed.channel.onUpstreamMessage(JSON.stringify({ type: 'item', streamId: 's1', value: { index } }));
    }
    assert(frames(resumed.state).filter((frame) => frame.type === 'down').length === 3, 'three frames delivered before the drop');
    resumed.channel.detachTransport();
    // Frames that arrive while the phone is away stay in the replay log.
    resumed.channel.onUpstreamMessage(JSON.stringify({ type: 'item', streamId: 's1', value: { index: 4 } }));
    assert(frames(resumed.state).filter((frame) => frame.type === 'down').length === 3, 'no delivery without a transport');
    const down2 = [];
    resumed.channel.attachTransport({ send: (text) => down2.push(text), close: () => {} });
    hello(resumed.channel, { resume: { logEpoch: resumedWelcome.epoch, sid: 3 } });
    const resumeWelcome = JSON.parse(down2[0]);
    assert(resumeWelcome.resume.ok === true && resumeWelcome.resume.mode === 'replay' && resumeWelcome.resume.replayed === 1, 'resume replays only the missing frame');
    assert(resumeWelcome.sid === 4, 'welcome reflects the current transport sid');
    const replayed = down2.slice(1).map((text) => JSON.parse(text));
    assert(replayed.length === 1 && replayed[0].sid === 4 && replayed[0].frame.value.index === 4, 'replayed envelope keeps its original sid');
    resumed.channel.onUpstreamMessage(JSON.stringify({ type: 'item', streamId: 's1', value: { index: 5 } }));
    assert(lastFrame({ down: down2 }).sid === 5, 'live frames continue after the replay');
    record('resume-exact-replay', true, { replayed: resumeWelcome.resume.replayed, sid: resumeWelcome.sid });

    const stale = makeChannel({});
    hello(stale.channel);
    stale.channel.detachTransport();
    const down3 = [];
    stale.channel.attachTransport({ send: (text) => down3.push(text), close: () => {} });
    hello(stale.channel, { resume: { logEpoch: 'epoch-from-another-process', sid: 0 } });
    const resetWelcome = JSON.parse(down3[0]);
    assert(resetWelcome.resume.ok === false && resetWelcome.resume.reason === 'epoch-mismatch', 'unknown logEpoch resets the session');
    assert(resetWelcome.sid === 0 && stale.channel.sid === 0, 'epoch reset also resets sid');
    record('resume-epoch-mismatch', true, resetWelcome.resume);

    // A reset must also cancel the old epoch's upstream streams so the phone can
    // safely re-open them (best effort; the App still re-opens its state).
    const cleanupChannel = makeChannel({});
    hello(cleanupChannel.channel);
    const cleanupEpoch = lastFrame(cleanupChannel.state).epoch;
    cleanupChannel.channel.handleClient(JSON.stringify({ type: 'open', streamId: 'old-a', endpoint: 'session/follow', payload: { args: {} } }));
    cleanupChannel.channel.handleClient(JSON.stringify({ type: 'open', streamId: 'old-b', endpoint: 'workspace/follow', payload: { args: {} } }));
    cleanupChannel.channel.detachTransport();
    const cleanupDown = [];
    cleanupChannel.channel.attachTransport({ send: (text) => cleanupDown.push(text), close: () => {} });
    hello(cleanupChannel.channel, { resume: { logEpoch: 'some-other-epoch', sid: 0 } });
    const cleanupWelcome = JSON.parse(cleanupDown[0]);
    const cancels = cleanupChannel.state.upstream.filter((text) => JSON.parse(text).type === 'cancel').map((text) => JSON.parse(text).streamId);
    assert(cleanupWelcome.resume.ok === false && cleanupWelcome.resume.reason === 'epoch-mismatch', 'reset path taken');
    assert(cancels.length === 2 && cancels.includes('old-a') && cancels.includes('old-b'), 'reset cancels streams opened in the old epoch, got ' + JSON.stringify(cancels));
    record('resume-reset-cancels-old-streams', true, { epochChanged: cleanupWelcome.epoch !== cleanupEpoch, cancels });

    // A reconnect without resume (phone dropped its transport state) is treated
    // as a fresh epoch too: old streams cancelled even without any gap.
    const freshChannel = makeChannel({});
    hello(freshChannel.channel);
    const freshEpoch = lastFrame(freshChannel.state).epoch;
    freshChannel.channel.handleClient(JSON.stringify({ type: 'open', streamId: 'stale', endpoint: '$events', payload: { args: {} } }));
    freshChannel.channel.detachTransport();
    const freshDown = [];
    freshChannel.channel.attachTransport({ send: (text) => freshDown.push(text), close: () => {} });
    hello(freshChannel.channel);
    const freshWelcome = JSON.parse(freshDown[0]);
    const freshCancels = freshChannel.state.upstream.filter((text) => JSON.parse(text).type === 'cancel').map((text) => JSON.parse(text).streamId);
    assert(freshWelcome.resume.mode === 'fresh' && freshWelcome.epoch !== freshEpoch, 'fresh reconnect starts a new epoch');
    assert(freshCancels.length === 1 && freshCancels[0] === 'stale', 'fresh reconnect cancels the lost streams');
    record('reconnect-without-resume-starts-new-epoch', true, { epochChanged: freshWelcome.epoch !== freshEpoch, cancels: freshCancels });

    const evicted = makeChannel({ limits: { replayFrames: 2 } });
    hello(evicted.channel);
    for (let index = 1; index <= 4; index += 1) evicted.channel.onUpstreamMessage(JSON.stringify({ type: 'item', value: { index } }));
    evicted.channel.detachTransport();
    const down4 = [];
    evicted.channel.attachTransport({ send: (text) => down4.push(text), close: () => {} });
    hello(evicted.channel, { resume: { logEpoch: evicted.channel.epoch, sid: 0 } });
    const evictedWelcome = JSON.parse(down4[0]);
    assert(evictedWelcome.resume.ok === false && evictedWelcome.resume.reason === 'evicted', 'evicted frames force a reset');
    record('resume-eviction-reset', true, evictedWelcome.resume);

    // Client frames pipelined before attachUpstream are buffered then flushed.
    const buffered = makeChannel({});
    buffered.channel.upstream = undefined; // simulate: upstream mux still opening
    hello(buffered.channel);
    buffered.channel.handleClient(JSON.stringify({ type: 'open', streamId: 's9', endpoint: 'workspace/follow', payload: { args: {} } }));
    assert(buffered.state.upstream.length === 0, 'frame buffered while upstream mux is opening');
    buffered.channel.attachUpstream({ send: (text) => buffered.state.upstream.push(text) });
    assert(buffered.state.upstream.length === 1, 'buffered frame flushed once upstream attaches');
    record('pending-client-frame-buffer', true, { flushed: buffered.state.upstream.length });

    // -------------------------------------------------------------- 6. tickets
    const secret = Buffer.from('unit-test-secret');
    const epoch = resumedWelcome.epoch;
    const ticket = mintResumeTicket({ secret, deviceId: 'dev-unit', epoch, ttlMs: 60_000 });
    const verified = verifyResumeTicket({ secret, ticket });
    assert(verified.ok === true && verified.deviceId === 'dev-unit' && verified.epoch === epoch, 'valid ticket verifies for the device/epoch');
    const tampered = verifyResumeTicket({ secret, ticket: ticket.slice(0, -2) + 'AA' });
    assert(tampered.ok === false && tampered.reason === 'bad-signature', 'tampered ticket rejected');
    const expired = verifyResumeTicket({ secret, ticket, now: Date.now() + 120_000 });
    assert(expired.ok === false && expired.reason === 'expired', 'expired ticket rejected');
    const wrongSecret = verifyResumeTicket({ secret: Buffer.from('other-secret'), ticket });
    assert(wrongSecret.ok === false, 'ticket is bound to the process secret');
    record('resume-ticket-hmac', true, { epoch: verified.epoch, tampered: tampered.reason, expired: expired.reason });

    // ReplayLog edge cases in isolation.
    const log = new ReplayLog({ maxBytes: 1024, maxFrames: 10 });
    log.append(1, 'a');
    log.append(2, 'b');
    assert(log.since(0).ok === true && log.since(0).frames.length === 2, 'log replays from the start');
    assert(log.since(2).ok === true && log.since(2).frames.length === 0, 'log up-to-date sid replays nothing');
    assert(log.since(3).ok === false && log.since(3).reason === 'sid-ahead', 'future sid rejected');
    assert(log.since(1).frames.length === 1, 'partial replay');
    record('replay-log-edge-cases', true, { since0: 2, since2: 0, since3: 'sid-ahead' });

    // Dispose closes a live socket and clears the log.
    const closing = makeChannel({});
    hello(closing.channel);
    closing.channel.onUpstreamMessage(JSON.stringify({ type: 'item', value: { x: 1 } }));
    closing.channel.dispose('test done');
    assert(closing.state.close.length === 1 && closing.state.close[0].code === 1001, 'dispose closes the phone socket');
    assert(closing.channel.replay.entries.length === 0 && closing.channel.inflight.size === 0, 'dispose clears replay/inflight state');
    record('channel-dispose', true, { close: closing.state.close[0] });

    // ------------------------------------------- 7. debug frame audit (Bug1)
    // The observer turns the next "stuck on 正在连接 Mac…" audit into a
    // hop-by-hop trace: from-device → to-upstream → from-upstream → to-device.
    // Debug off must stay a strict no-op (the recorder is never constructed).
    const collectAudit = () => {
      const lines = [];
      return {
        lines,
        record(event, fields = {}) {
          lines.push({ event, ...fields });
        },
      };
    };

    const quietAudit = collectAudit();
    const quietFrameAudit = new FrameAudit({ audit: quietAudit, enabled: false });
    quietFrameAudit.fromDevice('dev-x', JSON.stringify({ type: 'open', streamId: 's1', endpoint: '$events', payload: { args: {} } }));
    quietFrameAudit.toUpstream('dev-x', JSON.stringify({ type: 'open', streamId: 's1', endpoint: '$events' }));
    quietFrameAudit.fromUpstream('dev-x', JSON.stringify({ type: 'item', streamId: 's1', value: { type: 'ready' } }), false);
    quietFrameAudit.toDevice('dev-x', JSON.stringify({ type: 'welcome', sid: 0 }), true);
    const debugOffServer = new LinkServer(makeServerContext(home), { port: 3466, bindHost: '127.0.0.1', debug: { enabled: false } });
    debugOffServer.audit = quietAudit;
    assert(quietFrameAudit.active === false, 'disabled recorder is inactive');
    assert(quietAudit.lines.length === 0, 'debug off must not write any frame audit line');
    assert(debugOffServer.createFrameAudit() === undefined, 'debug.enabled=false must not construct a frame observer');
    record('frame-audit-debug-off-no-writes', true, { lines: quietAudit.lines.length });

    // Debug on: metadata only. Payloads, tokens, tickets, clientIds and homes
    // must never be copied; free-form values are neutralised, not stored.
    const frameAuditSink = collectAudit();
    const frameAudit = new FrameAudit({ audit: frameAuditSink });
    frameAudit.fromDevice('dev-x', JSON.stringify({ type: 'hello', v: 2, auth: { muxToken: 'SECRET-HELLO-TOKEN' } }));
    frameAudit.fromDevice('dev-x', JSON.stringify({ type: 'open', streamId: 'stream-events-1', endpoint: '$events', payload: { args: { note: 'SECRET-OPEN-ARG' } } }));
    frameAudit.fromDevice('dev-x', JSON.stringify({ type: 'item', streamId: 'stream-session-1', value: { type: 'snapshot', body: 'SECRET-SNAPSHOT-BODY' } }));
    frameAudit.fromDevice('dev-x', '{"type":"EVIL\\nTOKEN","streamId":"SECRET/STREAM-ID"}');
    frameAudit.fromUpstream(
      'dev-x',
      JSON.stringify({ type: 'item', streamId: 'stream-events-1', value: { type: 'ready', clientId: 'SECRET-CLIENT-ID', host: { home: '/Users/SECRET-HOME' } } }),
      false
    );
    frameAudit.fromUpstream('dev-x', Buffer.from(JSON.stringify({ type: 'item', streamId: 'b1', value: { type: 'ready' } })), true);
    frameAudit.toUpstream('dev-x', JSON.stringify({ type: 'open', streamId: 'stream-events-1', endpoint: '$events', payload: { args: {} } }));
    frameAudit.toDevice(
      'dev-x',
      JSON.stringify({ type: 'down', sid: 7, frame: { type: 'item', streamId: 'stream-events-1', value: { type: 'ready', clientId: 'SECRET-CLIENT-ID' } } }),
      true
    );
    frameAudit.toDevice('dev-x', JSON.stringify({ type: 'welcome', sid: 0, ticket: 'SECRET-RESUME-TICKET' }), true);
    frameAudit.toDevice('dev-x', JSON.stringify({ type: 'rpc/result', id: 'r1', body: { result: 'SECRET-RPC-BODY' } }), false);
    frameAudit.toDevice('dev-x', 'not-json SECRET-GARBAGE', true);

    const frameLines = frameAuditSink.lines;
    const frameDump = JSON.stringify(frameLines);
    assert(frameLines.length === 11, 'one audit line per observed frame, got ' + frameLines.length);
    assert(frameLines.every((line) => line.event === 'mux.frame' && line.deviceId === 'dev-x'), 'every line is a device-scoped mux.frame');
    for (const secret of [
      'SECRET-HELLO-TOKEN',
      'SECRET-OPEN-ARG',
      'SECRET-SNAPSHOT-BODY',
      'SECRET/STREAM-ID',
      'SECRET-CLIENT-ID',
      'SECRET-HOME',
      'SECRET-RESUME-TICKET',
      'SECRET-RPC-BODY',
      'SECRET-GARBAGE',
    ]) {
      assert(frameDump.includes(secret) === false, 'sensitive value leaked into frame audit: ' + secret);
    }
    assert(/"payload"|"value"|"clientId"|"ticket"|"home"|"body"/.test(frameDump) === false, 'frame audit must not copy payload field names');
    const byDir = (dir) => frameLines.filter((line) => line.dir === dir);
    const openFromDevice = byDir('from-device')[1];
    assert(openFromDevice.type === 'open' && openFromDevice.ep === '$events' && openFromDevice.streamId === 'stream-events-1', 'open frame names $events without copying the endpoint string');
    assert(byDir('from-device')[2].streamId === 'stream-session-1' && byDir('from-device')[2].vt === undefined, 'business item keeps streamId but no value kind');
    assert(byDir('from-device')[3].type === '?' && byDir('from-device')[3].streamId === undefined, 'hostile type/streamId are neutralised');
    const readyFromUpstream = byDir('from-upstream')[0];
    assert(readyFromUpstream.type === 'item' && readyFromUpstream.vt === 'ready' && readyFromUpstream.streamId === 'stream-events-1', 'upstream ready item is distinguishable');
    assert(byDir('from-upstream')[1].type === 'binary', 'binary frames are recorded as an anomaly marker, never decoded');
    const downToDevice = byDir('to-device')[0];
    assert(downToDevice.type === 'item' && downToDevice.vt === 'ready' && downToDevice.sid === 7 && downToDevice.sent === true, 'to-device unwraps the down envelope for type/vt/sid');
    assert(byDir('to-device')[1].type === 'welcome' && byDir('to-device')[2].type === 'rpc/result', 'control/rpc frames keep their outer type');
    assert(byDir('to-device')[2].sent === false, 'sent:false marks replay-only delivery');
    record('frame-audit-metadata-only-redaction', true, { lines: frameLines.length, dirs: [...new Set(frameLines.map((line) => line.dir))] });

    // Per-device record cap: a frame storm cannot flood the shared audit file.
    const cappedSink = collectAudit();
    const cappedAuditor = new FrameAudit({ audit: cappedSink, maxRecordsPerDevice: 2 });
    for (let index = 0; index < 5; index += 1) cappedAuditor.fromUpstream('dev-cap', JSON.stringify({ type: 'item', streamId: 's1', value: { type: 'ready' } }), false);
    cappedAuditor.fromUpstream('dev-cap', JSON.stringify({ type: 'item' }));
    const capEvents = cappedSink.lines.map((line) => line.event);
    assert(capEvents.filter((event) => event === 'mux.frame').length === 2, 'cap stops writing frame lines at maxRecordsPerDevice');
    assert(capEvents.filter((event) => event === 'mux.frame.truncated').length === 1, 'exactly one truncation notice per device');
    record('frame-audit-record-cap', true, { events: capEvents });

    // Upstream ingress wiring: the pre-existing UpstreamPeer#onFrame observer is
    // reused (no upstream-peer.js API change); debug off keeps it audit-free.
    const wiringDir = join(home, 'frame-audit-wiring');
    const wiredServer = new LinkServer(makeServerContext(home), { port: 3466, bindHost: '127.0.0.1', debug: { enabled: true }, contract: { probeOnStart: false } });
    wiredServer.audit = new AuditLog({ dir: wiringDir, log: () => {} });
    wiredServer.notifier = { observe: () => {} };
    wiredServer.frameAudit = wiredServer.createFrameAudit();
    assert(wiredServer.frameAudit !== undefined, 'debug.enabled=true constructs the frame observer');
    const wiredPeer = wiredServer.ensurePeer({ deviceId: 'dev-wired' });
    wiredPeer.onFrame(JSON.stringify({ type: 'item', streamId: 'stream-events-1', value: { type: 'ready', clientId: 'SECRET-WIRED-CLIENT' } }), false);
    const wiredText = readFileSync(join(wiringDir, 'audit.log'), 'utf8');
    const wiredLines = wiredText.trim().split('\n').map((line) => JSON.parse(line));
    assert(wiredLines.length === 1 && wiredLines[0].dir === 'from-upstream' && wiredLines[0].vt === 'ready', 'upstream-peer onFrame is wired into the frame audit');
    assert(wiredText.includes('SECRET-WIRED-CLIENT') === false, 'upstream frame payload never reaches the audit file');
    const silentServer = new LinkServer(makeServerContext(home), { port: 3466, bindHost: '127.0.0.1', debug: { enabled: false } });
    silentServer.audit = quietAudit;
    let silentObserved = 0;
    silentServer.notifier = { observe: () => { silentObserved += 1; } };
    silentServer.frameAudit = silentServer.createFrameAudit();
    const silentPeer = silentServer.ensurePeer({ deviceId: 'dev-silent' });
    silentPeer.onFrame(JSON.stringify({ type: 'item', streamId: 's1', value: { type: 'ready' } }), false);
    assert(silentServer.frameAudit === undefined && quietAudit.lines.length === 0, 'debug off keeps upstream-peer onFrame free of audit writes');
    assert(silentObserved === 1, 'debug off keeps the existing notifier observer behaviour');
    record('frame-audit-upstream-peer-wiring', true, { lines: wiredLines.length, silentObserved });

    // P1 bridge chain: one phone→Mac open / Mac→phone ready round trip is fully
    // traceable, including the envelope sid, without any payload being written.
    const chainDir = join(home, 'frame-audit-chain');
    const chainServer = new LinkServer(makeServerContext(home), {
      port: 3466,
      bindHost: '127.0.0.1',
      debug: { enabled: true },
      features: { muxRpc: true, muxRpcResumeWindowMs: 30_000 },
      contract: { probeOnStart: false },
      notifications: { enabled: false },
    });
    chainServer.audit = new AuditLog({ dir: chainDir, log: () => {} });
    chainServer.frameAudit = chainServer.createFrameAudit();
    chainServer.notifier = { observe: () => {} };
    const upstreamSocket = new EventEmitter();
    upstreamSocket.readyState = 1;
    upstreamSocket.sent = [];
    upstreamSocket.send = (text) => upstreamSocket.sent.push(text);
    chainServer.ensurePeer = () => ({ ensureMux: async () => upstreamSocket, cookie: { name: 'c', value: 'v' } });
    const downstreamSocket = new EventEmitter();
    downstreamSocket.readyState = 1;
    downstreamSocket.sent = [];
    downstreamSocket.send = (text) => downstreamSocket.sent.push(text);
    downstreamSocket.close = (code, reason) => {
      downstreamSocket.closed = { code, reason };
      downstreamSocket.readyState = 3;
    };
    chainServer.attachP1Downstream({ deviceId: 'dev-chain' }, downstreamSocket);
    downstreamSocket.emit('message', JSON.stringify({ type: 'hello', v: 2, auth: { muxToken: 'SECRET-MUX-TOKEN' } }), false);
    await sleep(20); // let the async upstream attach settle
    downstreamSocket.emit('message', JSON.stringify({ type: 'open', streamId: 'stream-events-1', endpoint: '$events', payload: { args: { note: 'SECRET-CHAIN-ARG' } } }), false);
    const readyFrame = JSON.stringify({ type: 'item', streamId: 'stream-events-1', value: { type: 'ready', clientId: 'SECRET-CHAIN-CLIENT', host: { home: '/Users/SECRET-CHAIN-HOME' } } });
    // The real UpstreamPeer#onFrame observer fires before link-server's own
    // upstream listener; emulate that order (the wiring itself is covered above).
    chainServer.frameAudit.fromUpstream('dev-chain', readyFrame, false);
    upstreamSocket.emit('message', readyFrame, false);
    await sleep(10);
    const chainText = readFileSync(join(chainDir, 'audit.log'), 'utf8');
    const chainLines = chainText.trim().split('\n').map((line) => JSON.parse(line)).filter((line) => line.event === 'mux.frame');
    const chainDirs = new Set(chainLines.map((line) => line.dir));
    for (const dir of ['from-device', 'to-upstream', 'from-upstream', 'to-device']) {
      assert(chainDirs.has(dir), 'missing frame-audit hop: ' + dir + ' (got ' + [...chainDirs].join(',') + ')');
    }
    assert(upstreamSocket.sent.length === 1 && JSON.parse(upstreamSocket.sent[0]).endpoint === '$events', 'phone open frame is still forwarded verbatim upstream');
    const readyToDevice = chainLines.find((line) => line.dir === 'to-device' && line.vt === 'ready');
    assert(readyToDevice !== undefined && readyToDevice.sid === 1 && readyToDevice.streamId === 'stream-events-1', 'ready item is traceable down to its envelope sid');
    const chainWelcome = JSON.parse(downstreamSocket.sent[0]);
    assert(chainWelcome.type === 'welcome' && typeof chainWelcome.ticket === 'string' && chainWelcome.ticket.length > 0, 'fixture: welcome carries a resume ticket');
    for (const secret of ['SECRET-MUX-TOKEN', 'SECRET-CHAIN-ARG', 'SECRET-CHAIN-CLIENT', 'SECRET-CHAIN-HOME', chainWelcome.ticket]) {
      assert(chainText.includes(secret) === false, 'sensitive value leaked into the on-disk audit: ' + secret.slice(0, 16));
    }
    chainServer.dispose();
    record('frame-audit-p1-bridge-chain', true, { hops: [...chainDirs].sort(), sid: readyToDevice.sid, lines: chainLines.length });

    const report = {
      startedAt: new Date(startedAt).toISOString(),
      durationMs: Date.now() - startedAt,
      checks,
      pass: checks.length,
      fail: 0,
    };
    writeFileSync(join(outDir, 'p1-mux-rpc-' + Date.now() + '.json'), JSON.stringify(report, null, 2) + '\n');
    console.log('\nALL PASS (' + checks.length + ' checks, ' + report.durationMs + 'ms)');
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
}

run().catch((error) => {
  console.error('\nFAIL ' + (error?.stack ?? String(error)));
  process.exitCode = 1;
});
