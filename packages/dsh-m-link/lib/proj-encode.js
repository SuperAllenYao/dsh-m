/**
 * projV1 参考编解码器（协议 v1 · A 段冻结实现）。
 *
 * 契约：<internal-doc>（FROZEN v1）。
 * 职责边界：
 * - 投影：`session/page` 成功响应的 JSON 值 → 投影行（白名单、7 处全文、行壳不丢）；
 * - 编码：投影行数组 → tagged tree 二进制（tag 0..7 / varint / zigzag / f64 LE）；
 * - 分帧：每帧 100 条 → `[u32 LE len][gzip(level 6)]`；
 * - 页面装配：整页 → 1..N 个 `{header, chunk}`（seq 降序 = 与窗口前沿相邻的帧在前）；
 * - 参考解码：测试 / 跨语言 golden 用（生产客户端在 Swift 侧独立实现）。
 *
 * 本文件是契约的单一实现来源：B 段直接接入，C 段 Swift 解码器必须与
 * `decodePageFrame` 字节级等价（golden 见 test/fixtures/proj-v1/golden.json）。
 *
 * 不做：能力协商、下游 WS 发送、lazy-fetch 请求（那些在 mux-rpc/link-server/客户端）。
 */
import { gzipSync, gunzipSync } from 'node:zlib';

export const PROJ_VERSION = 1;
export const FRAME_FORMAT = 'page-v1';
export const WIRE_VERSION = 0x02;
export const BATCH_RECORDS = 100;
export const GZIP_LEVEL = 6;

/** 截断模式阈值（仅 features.projV1TruncateLongText=true 时生效，默认关闭）。 */
export const TRUNCATE_LIMITS = Object.freeze({ textLines: 60, metaLines: 120, diffLines: 40 });

/**
 * legacy 别名：历史日志/旧实现里出现、但**不在** Host 权威词表（62 类）中的类型。
 * 运行期行为与 ignored 等价（行壳保留、data 丢弃、不计 unknown）；单独登记是为了
 * 让分类快照（`host-event-vocabulary.json`）能区分「词表内隐藏」与「词表外别名」。
 */
export const LEGACY_ALIAS_TYPES = Object.freeze([
  'request/header-encoded',
  'session-log-deepseek/*',
]);

/**
 * 已确知的隐藏/忽略事件类型：data 丢弃但**不**计入 unknownTypes（属预期内）。
 * Host 权威词表 62 类中的 42 类（20 projected + 42 known-ignored = 62；AC-14 / DD-15
 * 快照守卫按此校验，schema 漂移必须由守卫测试报警）。
 */
export const KNOWN_IGNORED_TYPES = Object.freeze([
  'developer/message',
  'request/header',
  'request/context',
  'session/title-llm-request',
  'web/deepseek-search-llm-request',
  'session-log-deepseek/delivery-accepted',
  'tool-workflow/run-start',
  'tool-workflow/run-end',
  'tool-workflow/agent-start',
  'tool-workflow/agent-end',
  'compaction/prune',
  'compaction/start',
  'compaction/summary',
  'compaction/end',
  'llm/retry',
  'llm/retry-started',
  'assistant/attempt',
  'model/selection',
  'working-directory/change',
  'session/end-seed',
  'agent-preset/selected',
  'step/start',
  'step/end',
  'session/title',
  'agent/inbox/spliced',
  'system/message',
  'permission/preset',
  'team/task',
  'team/member',
  'subagent/catalog',
  'subagent/model-selection-policy',
 // AC-14 补齐：Host 62 类词表中此前未分类的 11 类。
  'feedback/message-delete',
  'feedback/message-put',
  'feedback/record',
  'hook/invoked',
  'hook/result',
  'image/offload',
  'plan/mode',
  'schedule/change',
  'subagent/descriptor',
  'team/message/delivered',
  'team/message/queued',
]);

/** data 字段被投影保留的事件类型（其余类型只出行壳）。 */
export const PROJECTED_TYPES = Object.freeze([
  'user/message',
  'assistant/message',
  'tool/call',
  'tool/result',
  'tool/ptc-dispatch-start',
  'tool/ptc-dispatch',
  'turn/start',
  'turn/end',
  'approval/asked',
  'approval/decided',
  'todo/write',
  'goal/change',
  'deliverables/presented',
  'command/run',
  'command/done',
  'job/registered',
  'job/settled',
  'approval/policy',
  'sandbox/mode',
  'workspace/changes',
]);

/**
 * 投影行 data 顶层键白名单（按 event.type，契约 §2.2）。
 * 单一事实来源：守卫测试用它做「App 消费键 ⊆ 白名单」与「白名单 ↔ 投影实现」
 * 的双向绑定；嵌套键（content[]/message/meta/source/reason/goal/files/todos/
 * job.toolCall 的存在性）由投影实现控制，meta 子键见 `META_KEYS`。
 */
export const PROJECTED_DATA_KEYS = Object.freeze({
  'user/message': Object.freeze(['content', 'source', 'id']),
  'assistant/message': Object.freeze(['turn', 'message']),
  'tool/call': Object.freeze(['callId', 'name', 'turn', 'step', 'arguments']),
  'tool/result': Object.freeze(['turn', 'name', 'toolCallId', 'callId', 'message', 'meta']),
  'tool/ptc-dispatch-start': Object.freeze(['subCallId', 'parentCallId', 'name', 'arguments', 'turn']),
  'tool/ptc-dispatch': Object.freeze(['subCallId', 'parentCallId', 'turn', 'isError', 'content', 'meta']),
  'turn/start': Object.freeze(['turn']),
  'turn/end': Object.freeze(['turn', 'reason']),
  'approval/asked': Object.freeze(['id', 'toolName', 'reason']),
  'approval/decided': Object.freeze(['id', 'outcome']),
  'todo/write': Object.freeze(['todos']),
  'goal/change': Object.freeze(['goal']),
  'deliverables/presented': Object.freeze(['files']),
  'command/run': Object.freeze(['name']),
  'command/done': Object.freeze(['text']),
  'job/registered': Object.freeze(['jobId', 'kind', 'label', 'startedAt', 'toolCall']),
  'job/settled': Object.freeze(['jobId', 'status', 'finishedAt', 'toolCall']),
  'approval/policy': Object.freeze(['policy']),
  'sandbox/mode': Object.freeze(['mode']),
  'workspace/changes': Object.freeze([]),
});

const KNOWN_IGNORED = new Set([...KNOWN_IGNORED_TYPES, ...LEGACY_ALIAS_TYPES]);
const LEGACY_ALIAS = new Set(LEGACY_ALIAS_TYPES);
const PROJECTED = new Set(PROJECTED_TYPES);

/**
 * 投影分类器（AC-14 / TC-30 守卫测试入口），与 `projectRecord` 的运行期判定一致：
 * - `'projected'`：data 按白名单投影（`PROJECTED_TYPES`）；
 * - `'ignored'`：行壳保留、data 丢弃、不计 unknown（`KNOWN_IGNORED_TYPES`）；
 * - `'legacy'`：Host 词表外的历史别名，运行期按 ignored 处理（`LEGACY_ALIAS_TYPES`）；
 * - `'unknown'`：未登记类型 → 行壳 + `stats.unknownTypes` 计数。
 * @param {unknown} type
 * @returns {'projected'|'ignored'|'legacy'|'unknown'}
 */
export function classifyEventType(type) {
  if (typeof type !== 'string') return 'unknown';
  if (PROJECTED.has(type)) return 'projected';
  if (LEGACY_ALIAS.has(type)) return 'legacy';
  if (KNOWN_IGNORED.has(type)) return 'ignored';
  return 'unknown';
}

/** meta 白名单：值原样保留（7 处全文中的 lines/diffs 在此）。 */
export const META_KEYS = Object.freeze([
  'diffs',
  'lines',
  'files',
  'paths',
  'sources',
  'url',
  'statusCode',
  'path',
  'cwd',
  'operation',
  'total',
  'shape',
  'offset',
  'totalLines',
  'lang',
  'truncated',
  'additions',
  'deletions',
]);

const META_KEEP = new Set(META_KEYS);

export class ProjectionError extends Error {
  constructor(message) {
    super(message);
    this.name = 'ProjectionError';
  }
}

// ---------------------------------------------------------------- utilities ---

/** 只挑存在的键（undefined 省略；null 保留）。 */
function pick(source, keys) {
  if (source === null || typeof source !== 'object' || Array.isArray(source)) return undefined;
  const out = {};
  let any = false;
  for (const key of keys) {
    if (Object.prototype.hasOwnProperty.call(source, key)) {
      out[key] = source[key];
      any = true;
    }
  }
  return any ? out : undefined;
}

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

/** 行内文本统计（截断用；与 App 的 lineCount 同口径：空串算 1 行）。 */
function countLines(text) {
  if (typeof text !== 'string') return 0;
  if (text.length === 0) return 1;
  let lines = 1;
  for (let i = 0; i < text.length; i += 1) if (text.charCodeAt(i) === 0x0a) lines += 1;
  return lines;
}

/** 保留前 n 行（保留换行符；相等时不截断）。 */
function truncateLines(text, n) {
  if (typeof text !== 'string') return { text, truncated: false };
  let lines = 1;
  for (let i = 0; i < text.length; i += 1) {
    if (text.charCodeAt(i) === 0x0a) {
      lines += 1;
      if (lines > n) return { text: text.slice(0, i), truncated: true };
    }
  }
  return { text, truncated: false };
}

/** 规范化附件元数据：永不携带文件内容字段。 */
function projectAttachment(block) {
  if (!isPlainObject(block)) return undefined;
  const raw = isPlainObject(block.attachment) ? block.attachment : block;
  const att = pick(raw, ['attachmentId', 'mediaType', 'width', 'height', 'name', 'bytes']);
  if (att === undefined || typeof att.attachmentId !== 'string') return undefined;
  return att;
}

/**
 * content[] 过滤（user/assistant/tool-result/ptc 共用）。
 * - text / reasoning / tool-call / image 保留；其余 block 丢弃并计数。
 * - image 统一规范成 `{type:"image", attachment:{...}}`（永不携带文件内容）。
 * - 截断模式（默认关闭）：text block 超过阈值行数时只保留前缀，并回报 truncated。
 * @returns {{blocks: object[]|undefined, truncated: boolean}}
 */
function projectContentBlocks(blocks, stats, { truncateText = false, allowed } = {}) {
  if (!Array.isArray(blocks)) return { blocks: undefined, truncated: false };
  const out = [];
  let truncated = false;
  for (const block of blocks) {
    if (!isPlainObject(block) || (allowed !== undefined && !allowed.has(block.type))) {
      stats.unknownKeys += 1;
      continue;
    }
    const type = block.type;
    if (type === 'text') {
      if (typeof block.text !== 'string') {
        stats.unknownKeys += 1;
        continue;
      }
      let text = block.text;
      if (truncateText) {
        const cut = truncateLines(text, TRUNCATE_LIMITS.textLines);
        text = cut.text;
        if (cut.truncated) {
          truncated = true;
          stats.truncatedFields += 1;
        }
      }
      out.push({ type: 'text', text });
      continue;
    }
    if (type === 'image') {
      const attachment = projectAttachment(block);
      if (attachment === undefined) {
        stats.unknownKeys += 1;
        continue;
      }
      out.push({ type: 'image', attachment });
      continue;
    }
    if (type === 'reasoning') {
      if (typeof block.text !== 'string') {
        stats.unknownKeys += 1;
        continue;
      }
      out.push({ type: 'reasoning', text: block.text });
      continue;
    }
    if (type === 'tool-call') {
      const call = pick(block, ['type', 'id', 'callId', 'name', 'arguments']);
      if (call === undefined) {
        stats.unknownKeys += 1;
        continue;
      }
      call.type = 'tool-call';
      out.push(call);
      continue;
    }
    stats.unknownKeys += 1;
  }
  return { blocks: out, truncated };
}

/**
 * meta 白名单过滤；截断模式下 lines/diffs 受阈值约束。
 * 文件变更计数 additions/deletions 始终按**完整原文**计算后写入（截断不改变统计）。
 * @returns {{meta: object|undefined, truncated: string[]}} truncated 元素:'lines'|'diffs'
 */
function projectMeta(meta, stats, { truncate = false } = {}) {
  if (!isPlainObject(meta)) return { meta: undefined, truncated: [] };
  const out = {};
  let any = false;
  for (const key of Object.keys(meta)) {
    if (!META_KEEP.has(key)) {
      stats.unknownMetaKeys += 1;
      continue;
    }
    any = true;
    out[key] = meta[key];
  }
  if (!any) return { meta: undefined, truncated: [] };
  if (!truncate) return { meta: out, truncated: [] };

  const truncated = [];
  if (Array.isArray(out.lines) && out.lines.length > TRUNCATE_LIMITS.metaLines) {
    out.lines = out.lines.slice(0, TRUNCATE_LIMITS.metaLines);
    stats.truncatedFields += 1;
    truncated.push('lines');
  }
  if (Array.isArray(out.diffs)) {
    let additions = 0;
    let deletions = 0;
    let truncatedDiff = false;
    out.diffs = out.diffs.map((diff) => {
      if (!isPlainObject(diff)) return diff;
      const copy = { ...diff };
      for (const key of ['oldText', 'newText']) {
        const value = diff[key];
        if (typeof value === 'string') {
          const cut = truncateLines(value, TRUNCATE_LIMITS.diffLines);
          if (cut.truncated) {
            truncatedDiff = true;
            copy[key] = cut.text;
          }
        }
      }
      const oldLines = countLines(diff.oldText);
      const newLines = countLines(diff.newText);
      if (newLines > oldLines) additions += newLines - oldLines;
      if (oldLines > newLines) deletions += oldLines - newLines;
      return copy;
    });
    out.additions = additions;
    out.deletions = deletions;
    if (truncatedDiff) {
      stats.truncatedFields += 1;
      truncated.push('diffs');
    }
  }
  return { meta: out, truncated };
}

const SOURCE_KEYS = ['kind', 'form', 'summary', 'senderSessionId', 'rpcId'];
const USER_CONTENT_TYPES = new Set(['text', 'image']);
const ASSISTANT_CONTENT_TYPES = new Set(['text', 'reasoning', 'tool-call']);

function projectData(event, stats, options) {
  const type = event.type;
  const data = isPlainObject(event.data) ? event.data : {};
  switch (type) {
    case 'user/message': {
      const out = {};
      const content = projectContentBlocks(data.content, stats, {
        truncateText: false,
        allowed: USER_CONTENT_TYPES,
      });
      if (content.blocks !== undefined) out.content = content.blocks;
      const source = pick(data.source, SOURCE_KEYS);
      if (source !== undefined) out.source = source;
 // 契约 §2.2：`data.id` 必须保留——UserBubble.messageId 参与 FlowRow 等值，
 // 投影路径缺失会让「FlowRow 深度相等」保真门禁失败（独立审查 P2-4）。
      if (data.id !== undefined) out.id = data.id;
      return out;
    }
    case 'assistant/message': {
      const out = {};
      if (data.turn !== undefined) out.turn = data.turn;
      const message = {};
      if (isPlainObject(data.message)) {
        if (data.message.turn !== undefined) message.turn = data.message.turn;
        const blocks = Array.isArray(data.message.content) ? data.message.content : [];
        const projectedBlocks = projectContentBlocks(blocks, stats, {
          truncateText: false,
          allowed: ASSISTANT_CONTENT_TYPES,
        });
        if (projectedBlocks.blocks !== undefined) message.content = projectedBlocks.blocks;
      }
      if (Object.keys(message).length > 0) out.message = message;
      return out;
    }
    case 'tool/call':
      return pick(data, ['callId', 'name', 'turn', 'step', 'arguments']) ?? {};
    case 'tool/result': {
      const out = {};
      if (data.turn !== undefined) out.turn = data.turn;
      const top = pick(data, ['name', 'toolCallId', 'callId']);
      if (top !== undefined) Object.assign(out, top);
      let textTruncated = false;
      if (isPlainObject(data.message)) {
        const message = {};
        const content = projectContentBlocks(data.message.content, stats, {
          truncateText: options.truncateLongText,
          allowed: USER_CONTENT_TYPES,
        });
        textTruncated = content.truncated;
        if (content.blocks !== undefined) message.content = content.blocks;
        if (data.message.isError !== undefined) message.isError = data.message.isError;
        if (data.message.toolCallId !== undefined) message.toolCallId = data.message.toolCallId;
        if (Object.keys(message).length > 0) out.message = message;
      }
      const metaSource = Object.prototype.hasOwnProperty.call(data, 'meta')
        ? data.meta
        : isPlainObject(data.message)
          ? data.message.meta
          : undefined;
      const meta = projectMeta(metaSource, stats, { truncate: options.truncateLongText });
      if (meta.meta !== undefined) out.meta = meta.meta;
      if (options.truncateLongText) {
        const flags = [];
        if (textTruncated) flags.push('text');
        flags.push(...meta.truncated);
        if (flags.length > 0) out.tr = flags;
      }
      return out;
    }
    case 'tool/ptc-dispatch-start':
      return pick(data, ['subCallId', 'parentCallId', 'name', 'arguments', 'turn']) ?? {};
    case 'tool/ptc-dispatch': {
      const out = pick(data, ['subCallId', 'parentCallId', 'turn', 'isError']) ?? {};
      const content = projectContentBlocks(data.content, stats, {
        truncateText: options.truncateLongText,
        allowed: USER_CONTENT_TYPES,
      });
      if (content.blocks !== undefined) out.content = content.blocks;
      const meta = projectMeta(data.meta, stats, { truncate: options.truncateLongText });
      if (meta.meta !== undefined) out.meta = meta.meta;
      if (options.truncateLongText) {
        const flags = [...meta.truncated];
        if (content.truncated) flags.unshift('text');
        if (flags.length > 0) out.tr = flags;
      }
      return out;
    }
    case 'turn/start':
      return pick(data, ['turn']) ?? {};
    case 'turn/end': {
      const out = pick(data, ['turn']) ?? {};
      if (isPlainObject(data.reason)) {
        const reason = {};
        if (data.reason.kind !== undefined) reason.kind = data.reason.kind;
        if (isPlainObject(data.reason.error)) {
          const error = pick(data.reason.error, ['code', 'message']);
          if (error !== undefined) reason.error = error;
        }
        if (Object.keys(reason).length > 0) out.reason = reason;
      }
      return out;
    }
    case 'approval/asked':
      return pick(data, ['id', 'toolName', 'reason']) ?? {};
    case 'approval/decided':
      return pick(data, ['id', 'outcome']) ?? {};
    case 'todo/write': {
      if (!Array.isArray(data.todos)) return {};
      const todos = [];
      for (const item of data.todos) {
        if (!isPlainObject(item)) continue;
        const todo = pick(item, ['content', 'status']);
        if (todo !== undefined) todos.push(todo);
      }
      return todos.length > 0 ? { todos } : {};
    }
    case 'goal/change': {
      if (!isPlainObject(data.goal)) return {};
      const goal = pick(data.goal, ['objective', 'phase']);
      return goal === undefined ? {} : { goal };
    }
    case 'deliverables/presented': {
      if (!Array.isArray(data.files)) return {};
      const files = [];
      for (const item of data.files) {
        if (!isPlainObject(item)) continue;
        const file = pick(item, ['path', 'description']);
        if (file !== undefined) files.push(file);
      }
      return files.length > 0 ? { files } : {};
    }
    case 'command/run':
      return pick(data, ['name']) ?? {};
    case 'command/done':
      return pick(data, ['text']) ?? {};
    case 'job/registered':
    case 'job/settled': {
      const out = pick(data, ['jobId', 'kind', 'label', 'startedAt', 'status', 'finishedAt']) ?? {};
 // 存在性语义：App 用 `data?["toolCall"]!= nil` 去重，值本身不读。
      if (Object.prototype.hasOwnProperty.call(data, 'toolCall')) out.toolCall = {};
      return out;
    }
    case 'approval/policy':
      return pick(data, ['policy']) ?? {};
    case 'sandbox/mode':
      return pick(data, ['mode']) ?? {};
    case 'workspace/changes':
      return {};
    default:
      return {};
  }
}

// ---------------------------------------------------------------- projection ---

function emptyStats() {
  return {
    records: 0,
    projectedRecords: 0,
    unknownTypes: 0,
    droppedTypes: 0,
    unknownKeys: 0,
    unknownMetaKeys: 0,
    truncatedFields: 0,
  };
}

/**
 * 投影一条记录。records[].type!== "event" 或 event 为 null 时产出无 `y` 的行壳
 * （与 App 的 skip 语义等价，保持 seq 连续）。
 * @returns {{row: object, kind: 'event'|'shell'|'skip'}}
 */
export function projectRecord(record, stats, options = { truncateLongText: false }) {
  if (!isPlainObject(record)) return { row: undefined, skipped: true };
  const event = record.event;
  if (!isPlainObject(event) || typeof event.seq !== 'number') {
    return { row: undefined, skipped: true };
  }
  const row = {};
  row.s = event.seq;
  if (typeof event.time === 'number') row.t = event.time;
  const type = typeof event.type === 'string' ? event.type : undefined;
  if (type === undefined) {
 // 无 type 的事件：行壳（App 的 sessionPage 解码会整页失败，这里保持数据形状）。
    stats.records += 1;
    return { row, skipped: false };
  }
  row.y = type;
  stats.records += 1;
  if (!PROJECTED.has(type)) {
    if (KNOWN_IGNORED.has(type)) stats.droppedTypes += 1;
    else stats.unknownTypes += 1;
    return { row, skipped: false };
  }
  const projected = projectData(event, stats, options);
  stats.projectedRecords += 1;
  for (const key of Object.keys(projected)) {
    if (key === 's' || key === 't' || key === 'y') {
      stats.unknownKeys += 1;
      continue;
    }
    row[key] = projected[key];
  }
  return { row, skipped: false };
}

/**
 * 投影整页 `session/page` 响应值。
 * @param {unknown} value 页面 JSON（Host 的 `{records, hasMore}`）
 * @returns {{rows: object[], hasMore: boolean, stats: object}}
 * @throws {ProjectionError} 信封非法时（调用方整页回退旧 JSON）
 */
export function projectPage(value, options = {}) {
  if (!isPlainObject(value)) throw new ProjectionError('page value is not an object');
  const records = value.records;
  if (!Array.isArray(records)) throw new ProjectionError('page.records is not an array');
  if (typeof value.hasMore !== 'boolean') throw new ProjectionError('page.hasMore is not a boolean');
  const opts = { truncateLongText: options.truncateLongText === true };
  const stats = emptyStats();
  const rows = [];
  for (const record of records) {
    const { row, skipped } = projectRecord(record, stats, opts);
    if (skipped) {
 // 保持 seq 连续性是不可能的（没有 seq）：与 App 一致，整页视为不可投影。
      throw new ProjectionError('page.records contains a record without event.seq');
    }
    rows.push(row);
  }
  return { rows, hasMore: value.hasMore, stats };
}

// ------------------------------------------------------------------ codec ---

function uvarint(value) {
  let n = Math.floor(value);
  const out = [];
  while (n >= 0x80) {
    out.push((n % 0x80) | 0x80);
    n = Math.floor(n / 0x80);
  }
  out.push(n);
  return Buffer.from(out);
}

function zigzag(value) {
  return value >= 0 ? value * 2 : -value * 2 - 1;
}

/** tagged tree 编码（v0）。 */
export function encodeValue(value) {
  if (value === null || value === undefined) return Buffer.from([0x00]);
  if (value === true) return Buffer.from([0x01]);
  if (value === false) return Buffer.from([0x02]);
  if (typeof value === 'number') {
    if (Number.isInteger(value) && Math.abs(value) < 2 ** 52) {
      return Buffer.concat([Buffer.from([0x03]), uvarint(zigzag(value))]);
    }
    const out = Buffer.alloc(9);
    out[0] = 0x04;
    out.writeDoubleLE(value, 1);
    return out;
  }
  if (typeof value === 'string') {
    const bytes = Buffer.from(value, 'utf8');
    return Buffer.concat([Buffer.from([0x05]), uvarint(bytes.length), bytes]);
  }
  if (Array.isArray(value)) {
    return Buffer.concat([Buffer.from([0x06]), uvarint(value.length), ...value.map(encodeValue)]);
  }
  if (typeof value === 'object') {
    const keys = Object.keys(value);
    const parts = [Buffer.from([0x07]), uvarint(keys.length)];
    for (const key of keys) {
      const keyBytes = Buffer.from(key, 'utf8');
      parts.push(uvarint(keyBytes.length), keyBytes, encodeValue(value[key]));
    }
    return Buffer.concat(parts);
  }
  throw new TypeError('encodeValue: unsupported type ' + typeof value);
}

/** tagged tree 参考解码器（测试 / golden 用）。 */
export function decodeValue(buffer, start = 0) {
  let offset = start;
  function readU8() {
    if (offset >= buffer.length) throw new RangeError('decodeValue: truncated');
    const value = buffer[offset];
    offset += 1;
    return value;
  }
  function readUvarint() {
    let shift = 0;
    let result = 0;
    for (;;) {
      const byte = readU8();
      result += (byte & 0x7f) * 2 ** shift;
      if ((byte & 0x80) === 0) return result;
      shift += 7;
      if (shift > 53) throw new RangeError('decodeValue: varint too long');
    }
  }
  function readZigzag() {
    const value = readUvarint();
    return value % 2 === 0 ? value / 2 : -(value + 1) / 2;
  }
  function readString() {
    const length = readUvarint();
    if (offset + length > buffer.length) throw new RangeError('decodeValue: truncated string');
    const text = buffer.toString('utf8', offset, offset + length);
    offset += length;
    return text;
  }
  function readValue() {
    const tag = readU8();
    switch (tag) {
      case 0x00:
        return null;
      case 0x01:
        return true;
      case 0x02:
        return false;
      case 0x03:
        return readZigzag();
      case 0x04: {
        if (offset + 8 > buffer.length) throw new RangeError('decodeValue: truncated f64');
        const value = buffer.readDoubleLE(offset);
        offset += 8;
        return value;
      }
      case 0x05:
        return readString();
      case 0x06: {
        const length = readUvarint();
        const out = [];
        for (let i = 0; i < length; i += 1) out.push(readValue());
        return out;
      }
      case 0x07: {
        const length = readUvarint();
        const out = {};
        for (let i = 0; i < length; i += 1) {
          const key = readString();
          if (Object.prototype.hasOwnProperty.call(out, key)) {
            throw new RangeError('decodeValue: duplicate object key ' + key);
          }
          out[key] = readValue();
        }
        return out;
      }
      default:
        throw new RangeError('decodeValue: bad tag ' + tag);
    }
  }
  const value = readValue();
  return { value, offset };
}

/** 一帧的 gzip 载荷（不含长度前缀；长度前缀由上层帧格式写入）。 */
export function encodeChunk(rows) {
  return gzipSync(encodeValue(rows), { level: GZIP_LEVEL });
}

/** 帧流单元 `[u32 LE len][gzip(payload)]`（契约 §4；wire 帧体同构）。 */
export function encodeFrameUnit(rows) {
  const chunk = encodeChunk(rows);
  const head = Buffer.alloc(4);
  head.writeUInt32LE(chunk.length, 0);
  return Buffer.concat([head, chunk]);
}

/**
 * 拆帧并且**按 seq 降序**输出（帧 0 = seq 最高的一段，与已加载窗口前沿相邻）。
 * @param {object[]} rows 升序投影行
 * @param {{batch?: number}} [options]
 */
export function buildFrames(rows, options = {}) {
  const batch = Number.isInteger(options.batch) && options.batch > 0 ? options.batch : BATCH_RECORDS;
  const ascending = [];
  for (let i = 0; i < rows.length; i += batch) ascending.push(rows.slice(i, i + batch));
  const descending = ascending.reverse();
  return descending.map((chunkRows, index) => ({ index, records: chunkRows.length, chunk: encodeChunk(chunkRows) }));
}

/**
 * 装配一整页：header + 1..N 帧。
 * @param {{value: unknown, rpcId: string, batch?: number, truncateLongText?: boolean}} input
 * @returns {{frames: {header: object, chunk: Buffer}[], stats: object, header: object}}
 * header = 首帧 header（f=0）
 */
export function buildProjectedPage({ value, rpcId, batch = BATCH_RECORDS, truncateLongText = false }) {
  if (typeof rpcId !== 'string' || rpcId.length === 0) throw new ProjectionError('rpcId is required');
  const { rows, hasMore, stats } = projectPage(value, { truncateLongText });
  const chunks = buildFrames(rows, { batch });
  const frames = [];
  if (chunks.length === 0) {
    frames.push({
      header: {
        fmt: FRAME_FORMAT,
        v: PROJ_VERSION,
        rpcId,
        f: 0,
        frames: 0,
        records: 0,
        hasMore,
        batch,
      },
      chunk: Buffer.alloc(0),
    });
  } else {
    for (const { index, chunk } of chunks) {
 // hasMore 同时写在首帧（页面级元信息）与末帧（客户端"末帧才提交 hasMore"
 // 的强制时机，独立审查 P1-2）：末帧缺失会让半页中断无法区分"还有更早"。
      const header =
        index === 0
          ? {
              fmt: FRAME_FORMAT,
              v: PROJ_VERSION,
              rpcId,
              f: 0,
              frames: chunks.length,
              records: rows.length,
              hasMore,
              batch,
            }
          : index === chunks.length - 1
            ? { fmt: FRAME_FORMAT, v: PROJ_VERSION, rpcId, f: index, hasMore }
            : { fmt: FRAME_FORMAT, v: PROJ_VERSION, rpcId, f: index };
      frames.push({ header, chunk });
    }
  }
  return { frames, stats, header: frames[0].header, rows, records: rows.length, hasMore };
}

/** 一条 WS binary message：`[0x02][u32 headerLen][header JSON][u32 chunkLen][chunk]`。 */
export function encodeWireFrame({ header, chunk }) {
  const headerBytes = Buffer.from(JSON.stringify(header), 'utf8');
  const headerLength = Buffer.alloc(4);
  headerLength.writeUInt32LE(headerBytes.length, 0);
  const chunkLength = Buffer.alloc(4);
  chunkLength.writeUInt32LE(chunk.length, 0);
  return Buffer.concat([Buffer.from([WIRE_VERSION]), headerLength, headerBytes, chunkLength, chunk]);
}

/**
 * 参考解码器：一条 WS binary message → `{header, rows}`。
 * @param {Buffer} data
 * @throws {RangeError|ProjectionError} 版本/长度/gzip/解码非法
 */
export function decodePageFrame(data) {
  if (!Buffer.isBuffer(data) || data.length < 9) throw new RangeError('decodePageFrame: truncated frame');
  if (data[0] !== WIRE_VERSION) throw new RangeError('decodePageFrame: bad wire version ' + data[0]);
  const headerLength = data.readUInt32LE(1);
  if (5 + headerLength + 4 > data.length) throw new RangeError('decodePageFrame: truncated header');
  const headerJson = data.toString('utf8', 5, 5 + headerLength);
  let header;
  try {
    header = JSON.parse(headerJson);
  } catch (error) {
    throw new RangeError('decodePageFrame: header is not JSON: ' + String(error?.message ?? error));
  }
  if (!isPlainObject(header) || header.fmt !== FRAME_FORMAT) throw new RangeError('decodePageFrame: bad header fmt');
  let offset = 5 + headerLength;
  const chunkLength = data.readUInt32LE(offset);
  offset += 4;
  if (offset + chunkLength > data.length) throw new RangeError('decodePageFrame: truncated chunk');
  const chunk = data.subarray(offset, offset + chunkLength);
  if (chunkLength === 0) return { header, rows: [] };
  const payload = gunzipSync(chunk);
  const { value, offset: consumed } = decodeValue(payload, 0);
  if (consumed !== payload.length) throw new RangeError('decodePageFrame: trailing payload bytes');
  if (!Array.isArray(value)) throw new RangeError('decodePageFrame: payload is not a row array');
  return { header, rows: value };
}
