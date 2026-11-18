#!/usr/bin/env node
// Spoolup collector — derives per-call TTFT / TPS for Claude Code and Codex
// purely from the timestamps both tools already write to their local logs.
// No proxy, no extra requests. Serves a JSON/SSE API and the web dashboard.
//
//   Claude Code  ~/.claude/projects/**/*.jsonl
//     start  = `api-request` entry timestamp (written when the request is sent)
//     first  = first assistant content block for that request (requestRef)
//     end    = last content block; usage from the message
//   Codex        ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
//     start  = latest input item (user message / tool output / task_started)
//     first  = first output item (reasoning / message / tool call)
//     end    = token_usage_record (one per Responses API call)
//     first call of a turn uses Codex's own task_complete.time_to_first_token_ms
//
// Block timestamps mark when a block *finished*, so TTFT here is "time to first
// block" — an upper bound on true TTFT. TPS is end-to-end: output tokens over
// the whole call. Aggregates use medians/percentiles to absorb network jitter.
//
// These are heuristics over undocumented log formats. Every rule counts what it
// matched and what it dropped; `issues()` turns those counters into errors /
// warnings (format drift, unmatched blocks, implausible values…) so a change in
// either tool's logs shows up loudly instead of quietly skewing the numbers.

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const HOME = os.homedir();
const PORT = Number(process.env.SPOOLUP_PORT || 8787);
const HOST = process.env.SPOOLUP_HOST || '127.0.0.1';
const DAYS = Number(process.env.SPOOLUP_DAYS || 14);
const CLAUDE_DIR = process.env.CLAUDE_CONFIG_DIR ? path.join(process.env.CLAUDE_CONFIG_DIR, 'projects') : path.join(HOME, '.claude', 'projects');
const REPORT_FILE = path.join(HOME, '.spoolup', 'report.log');
// Settings shared by the dashboard (any browser) and the menu bar app; currently just the UI language.
const PREFS_FILE = path.join(HOME, '.spoolup', 'prefs.json');
let prefs = (() => { try { return JSON.parse(fs.readFileSync(PREFS_FILE, 'utf8')); } catch { return {}; } })();
const CODEX_DIR = path.join(process.env.CODEX_HOME || path.join(HOME, '.codex'), 'sessions');
// Calls with fewer output tokens are latency-dominated; keep them out of TPS stats.
const MIN_TPS_TOKENS = Number(process.env.SPOOLUP_MIN_TPS_TOKENS || 50);
const LIVE_TIMEOUT_MS = 10 * 60 * 1000;

const ms = iso => Date.parse(iso);
const round = (x, d = 1) => (x == null || !isFinite(x) ? null : Math.round(x * 10 ** d) / 10 ** d);
// A substring keeps its whole parent alive in V8, here a whole read chunk. Copy anything kept past the line.
const own = s => s && Buffer.from(s).toString();
// Thousands of calls share a handful of models and projects; keep one copy of each string.
const shared = new Map();
const intern = s => s == null ? s : shared.get(s) ?? (shared.set(s, s), s);

/** id → call record. Upserted as more blocks arrive. */
const calls = new Map();
/** Claude requests sent but with no block yet: id → {agent, ts, model}. */
const pending = new Map();
const subscribers = new Set();
let indexing = true;

function broadcast(event, data) {
  const msg = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
  for (const res of subscribers) res.write(msg);
}

// ---------------------------------------------------------------- diagnostics

// Log formats these rules were checked against. Other versions still parse, but
// get flagged so you know the numbers rest on unverified assumptions.
const VERIFIED = { claude: ['2.1.311'], codex: ['0.169.0'] };
const DIAG_WINDOW_MS = 24 * 3600e3;

/** kind → timestamps (log time) of recent occurrences, capped. */
const counters = new Map();
/** kind → { count, sample, file, message, at } for things worth showing verbatim. */
const samples = new Map();
const runtimeErrors = [];

function note(kind, t = Date.now(), sample) {
  let arr = counters.get(kind);
  if (!arr) counters.set(kind, (arr = []));
  arr.push(t);
  if (arr.length > 20000) arr.splice(0, arr.length - 10000);
  if (sample) {
    const prev = samples.get(kind);
    // Messages are [zh, en] pairs; the dashboard picks one, the menu bar app reads `message`.
    const [message, message_en] = Array.isArray(sample.message) ? sample.message : [sample.message, sample.message];
    samples.set(kind, { ...sample, sample: own(sample.sample), message, message_en, count: (prev?.count || 0) + 1, at: t });
  }
}

function recentCount(kind, since = Date.now() - DIAG_WINDOW_MS) {
  const arr = counters.get(kind);
  if (!arr) return 0;
  // Files are read in mtime order, so timestamps aren't sorted; count them all.
  let n = 0;
  for (const t of arr) if (t >= since) n++;
  return n;
}

function runtimeError(where, e) {
  runtimeErrors.push({ at: Date.now(), where, message: String(e?.stack || e).split('\n').slice(0, 3).join(' | ') });
  if (runtimeErrors.length > 50) runtimeErrors.shift();
  console.error(`[spoolup] ${where}:`, e);
}

function finalize(rec) {
  rec.duration_ms = Math.max(0, rec.end - rec.ts);
  rec.ttft_ms = rec.ttft_reported ?? (rec.first != null ? Math.max(0, rec.first - rec.ts) : null);
  const out = rec.output_tokens || 0;
  rec.tps = out > 0 && rec.duration_ms > 0 ? round(out / (rec.duration_ms / 1000)) : null;
  calls.set(rec.id, rec);
  if (!indexing) broadcast('call', slim(rec));
}

// ---------------------------------------------------------------- parsers

// Cheap pre-filters before JSON.parse. Whitespace-tolerant so a serializer change
// can't make every line silently miss.
const kv = (key, value = '[^"]*') => new RegExp(`"${key}"\\s*:\\s*"(${value})"`);
const IS_API_REQUEST = kv('type', 'api-request');
const IS_ASSISTANT = kv('type', 'assistant');
const IS_USER = kv('type', 'user');
const TIMESTAMP = kv('timestamp', '[^"]+');

function claudeParser(file) {
  const subagent = file.includes(`${path.sep}subagents${path.sep}`);
  let lastUserTs = null; // fallback for older logs without api-request entries
  return line => {
    note('claude.line');
    if (IS_API_REQUEST.test(line)) {
      const r = JSON.parse(line);
      note('claude.line_matched');
      if (r.type === 'api-request') {
        pending.set(r.id, { agent: 'claude', ts: ms(r.timestamp), model: r.params?.model });
        note('claude.request', ms(r.timestamp));
      }
      return;
    }
    if (!IS_ASSISTANT.test(line)) {
      if (IS_USER.test(line)) {
        note('claude.line_matched');
        const m = line.match(TIMESTAMP);
        if (m) lastUserTs = ms(m[1]);
      }
      return;
    }
    note('claude.line_matched');
    const r = JSON.parse(line);
    if (r.type !== 'assistant' || r.message?.model === '<synthetic>') return;
    const t = ms(r.timestamp);
    // Every real assistant block should become part of a call; the ratio is the drift alarm.
    note('claude.block_seen', t);
    const m = r.message;
    if (!m?.usage || !isFinite(t)) {
      note('claude.drop_no_usage', t, { file, message: ['assistant 记录缺少 message.usage 或 timestamp', 'assistant entry lacks message.usage or timestamp'], sample: line.slice(0, 300) });
      return;
    }
    const reqId = r.requestRef;
    const id = 'c:' + (reqId || m.id);
    let rec = calls.get(id);
    if (!rec) {
      const req = reqId && pending.get(reqId);
      const start = req?.ts ?? lastUserTs;
      if (start == null) {
        note('claude.drop_orphan', t, { file, message: [`块无法对应请求：requestRef=${reqId ?? '缺失'}，且之前没有 user 记录`, `Block matches no request: requestRef=${reqId ?? 'missing'} and no earlier user entry`], sample: line.slice(0, 300) });
        return;
      }
      if (t < start) {
        note('claude.drop_backwards', t, { file, message: ['块时间早于请求时间', 'Block is timestamped before its request'], sample: line.slice(0, 300) });
        return;
      }
      pending.delete(reqId);
      rec = {
        id, agent: 'claude', ts: start, first: t, end: t,
        model: intern(m.model || req?.model || null), project: intern(r.cwd || null),
        source: subagent || r.isSidechain ? 'subagent' : 'main',
        estimated_start: !req, // no api-request seen yet; start borrowed from the last user entry
      };
      if (!req) note('claude.fallback_start', t, { file, message: [`requestRef=${reqId ?? '缺失'} 未匹配到 api-request，起点改用上一条 user 记录`, `requestRef=${reqId ?? 'missing'} matches no api-request; using the previous user entry as start`] });
      note('claude.call', t);
    } else if (rec.estimated_start && reqId && pending.has(reqId)) {
      // A forked session's file copies the replies but not the api-request line. Files are read
      // oldest first, so the copy can arrive before the original; once the original's request
      // shows up, replace the estimated start with the real one.
      const req = pending.get(reqId);
      pending.delete(reqId);
      rec.ts = req.ts;
      rec.model ??= intern(req.model);
      rec.estimated_start = false;
      note('claude.fallback_resolved', t);
    }
    note('claude.block_used', t);
    rec.first = Math.min(rec.first, t);
    rec.end = Math.max(rec.end, t);
    const u = m.usage;
    rec.input_tokens = (u.input_tokens || 0) + (u.cache_read_input_tokens || 0) + (u.cache_creation_input_tokens || 0);
    rec.cached_tokens = u.cache_read_input_tokens || 0;
    rec.output_tokens = u.output_tokens || 0;
    rec.reasoning_tokens = u.output_tokens_details?.thinking_tokens || 0;
    finalize(rec);
  };
}

const CODEX_INPUT = /^(message:(user|developer)|.*_call_output)$/;
const CODEX_OUTPUT = /^(reasoning|message:assistant|.*_call)$/;
// Items that are neither request inputs nor model output.

function codexParser(file) {
  const st = { model: null, cwd: null, start: null, first: null, turnCalls: [] };
  return line => {
    const head = line.slice(0, 400);
    const tm = head.match(/^\{\s*"timestamp"\s*:\s*"([^"]+)"/);
    if (!tm) {
      note('codex.unrecognized_line', Date.now(), { file, message: ['行不以 {"timestamp": …} 开头', 'Line does not start with {"timestamp": …}'], sample: head.slice(0, 200) });
      return;
    }
    const t = ms(tm[1]);
    const kind = head.match(/"type"\s*:\s*"(\w+)"\s*,\s*"payload"\s*:\s*\{(?:\s*"type"\s*:\s*"(\w+)")?/);
    if (!kind) {
      note('codex.unrecognized_line', t, { file, message: ['行结构不符合 {"timestamp","type","payload"} 规则', 'Line does not match the {"timestamp","type","payload"} shape'], sample: head.slice(0, 200) });
      return;
    }
    const [, type, ptype] = kind;

    if (type === 'response_item') {
      let k = ptype;
      if (ptype === 'message') k += ':' + (head.match(/"role"\s*:\s*"(\w+)"/)?.[1] || '');
      if (CODEX_INPUT.test(k)) { st.start = t; st.first = null; }
      else if (CODEX_OUTPUT.test(k)) { if (st.start != null) st.first ??= t; }
      return;
    }
    if (type === 'turn_context') {
      const p = JSON.parse(line).payload;
      st.model = intern(p.model) || st.model; st.cwd = intern(p.cwd) || st.cwd;
      return;
    }
    if (type === 'event_msg' && ptype === 'token_count') {
      // Codex writes one per API call alongside token_usage_record — the drift alarm's denominator.
      if (/"last_token_usage"\s*:\s*\{/.test(line)) note('codex.token_count', t);
      return;
    }
    if (type === 'event_msg' && ptype === 'task_started') {
      st.start = t; st.first = null; st.turnCalls = [];
      return;
    }
    if (type === 'event_msg' && ptype === 'task_complete') {
      // Codex measures the turn's real TTFT itself; apply it to the turn's first call.
      const p = JSON.parse(line).payload;
      const first = st.turnCalls[0] && calls.get(st.turnCalls[0]);
      if (first && p.time_to_first_token_ms != null && p.time_to_first_token_ms <= first.end - first.ts) {
        first.ttft_reported = p.time_to_first_token_ms;
        finalize(first);
      }
      st.turnCalls = [];
      return;
    }
    if (type === 'token_usage_record') {
      const p = JSON.parse(line).payload;
      const id = 'x:' + (p.response_id || `${file}:${t}`);
      const u = p.usage || {};
      // Forked/resumed sessions replay history; keep the first sighting.
      note('codex.record', t);
      if (!p.response_id) note('codex.no_response_id', t, { file, message: ['token_usage_record 缺少 response_id，去重退化为按文件+时间', 'token_usage_record lacks response_id; deduplicating by file + time instead'] });
      if (!calls.has(id)) {
        if (st.start == null) note('codex.no_start', t, { file, message: ['调用前没有找到输入项（user 消息 / 工具输出），起点用结束时间代替', 'No input item (user message / tool output) before the call; using its end time as start'] });
        if (!st.model) note('codex.no_model', t, { file, message: ['会话里没有 turn_context.model', 'Session has no turn_context.model'] });
        finalize({
          id, agent: 'codex', ts: st.start ?? t, first: st.first, end: t,
          model: st.model, project: st.cwd,
          source: p.turn_id && p.root_turn_id && p.turn_id !== p.root_turn_id ? 'subagent' : 'main',
          input_tokens: u.input_tokens || 0,
          cached_tokens: u.cached_input_tokens || 0,
          output_tokens: u.output_tokens || 0,
          reasoning_tokens: u.reasoning_output_tokens || 0,
        });
        st.turnCalls.push(id);
      }
      st.start = t; st.first = null; // next call starts once new input lands
    }
  };
}

// ---------------------------------------------------------------- file tailing

/** path → {offset, rest, parse} */
const files = new Map();

function* walk(dir, depth = 0) {
  let ents;
  try { ents = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
  for (const e of ents) {
    const p = path.join(dir, e.name);
    if (e.isDirectory() && depth < 4) yield* walk(p, depth + 1);
    else if (e.isFile() && e.name.endsWith('.jsonl')) yield p;
  }
}

function codexDayDirs() {
  const out = [];
  for (let i = 0; i <= DAYS; i++) {
    const d = new Date(Date.now() - i * 86400e3);
    out.push(path.join(CODEX_DIR, String(d.getFullYear()), String(d.getMonth() + 1).padStart(2, '0'), String(d.getDate()).padStart(2, '0')));
  }
  return out;
}

function discover() {
  const cutoff = Date.now() - DAYS * 86400e3;
  const found = [];
  for (const f of walk(CLAUDE_DIR)) found.push([f, claudeParser]);
  for (const d of codexDayDirs()) for (const f of walk(d)) found.push([f, codexParser]);
  // Oldest first so cross-file dedupe keeps the original sighting.
  const fresh = [];
  for (const [f, mk] of found) {
    if (files.has(f)) continue;
    let st; try { st = fs.statSync(f); } catch { continue; }
    if (st.mtimeMs >= cutoff) fresh.push([f, mk, st.mtimeMs]);
  }
  fresh.sort((a, b) => a[2] - b[2]);
  for (const [f, mk] of fresh) files.set(f, { offset: 0, rest: '', parse: mk(f), agent: mk === claudeParser ? 'claude' : 'codex' });
}

const CHUNK = 1 << 20;
const buf = Buffer.alloc(CHUNK);

function readNew(f, state) {
  let size;
  try { size = fs.statSync(f).size; } catch { files.delete(f); return; }
  if (size < state.offset) { state.offset = 0; state.rest = ''; } // truncated/rewritten
  if (size === state.offset) return;
  const fd = fs.openSync(f, 'r');
  try {
    while (state.offset < size) {
      const n = fs.readSync(fd, buf, 0, Math.min(CHUNK, size - state.offset), state.offset);
      if (!n) break;
      state.offset += n;
      const lines = (state.rest + buf.toString('utf8', 0, n)).split('\n');
      state.rest = own(lines.pop());
      for (const line of lines) {
        if (!line) continue;
        try { state.parse(line); } catch (e) {
          note(`${state.agent}.parse_error`, Date.now(), { file: f, message: String(e.message || e), sample: line.slice(0, 300) });
        }
      }
    }
  } finally { fs.closeSync(fd); }
}

// The collector runs for weeks; drop calls and files that have aged out of the window so memory stays flat.
function prune() {
  const cutoff = Date.now() - DAYS * 86400e3;
  for (const [id, c] of calls) if (c.ts < cutoff) calls.delete(id);
  for (const [f] of files) {
    let st; try { st = fs.statSync(f); } catch { files.delete(f); continue; }
    if (st.mtimeMs < cutoff) files.delete(f);
  }
}

let lastDiscover = 0;
function scan() {
  try {
    if (Date.now() - lastDiscover > 10_000) { discover(); prune(); lastDiscover = Date.now(); }
  } catch (e) { runtimeError('discover', e); }
  for (const [f, st] of files) {
    try { readNew(f, st); } catch (e) { runtimeError(`read ${f}`, e); }
  }
  // Requests that never got a response (aborted, crashed) stop being "live".
  for (const [id, p] of pending) {
    if (Date.now() - p.ts > LIVE_TIMEOUT_MS) { pending.delete(id); note('claude.request_unanswered', p.ts); }
  }
}

// ---------------------------------------------------------------- issues

const NAMES = { claude: 'Claude Code', codex: 'Codex' };
// Values no real call produces mean a rule mis-paired timestamps. Checked when reporting, not stored:
// a Claude call's first block already carries final usage, so its TPS spikes until the last block lands.
const implausible = c => c.ttft_ms > c.duration_ms + 1 || c.tps > 3000 || c.duration_ms > 3 * 3600e3;
const seenIssues = new Set();

/** Append an issue to ~/.spoolup/report.log: a plain-text record to check when something looks off later. */
function report(i) {
  const lines = [`${new Date().toISOString()} [${i.level}] ${i.title}`, `  ${i.detail}`];
  if (i.file) lines.push(`  file: ${i.file}`);
  if (i.message && i.message !== i.detail) lines.push(`  ${i.message}`);
  if (i.sample) lines.push(`  sample: ${i.sample.replace(/\s+/g, ' ').slice(0, 300)}`);
  try { fs.mkdirSync(path.dirname(REPORT_FILE), { recursive: true }); fs.appendFileSync(REPORT_FILE, lines.join('\n') + '\n\n'); }
  catch (e) { console.error(`[spoolup] cannot write ${REPORT_FILE}: ${e.message}`); }
  console.error(`[spoolup] ${i.level}: ${i.title} — ${i.detail}`);
}

function sampleOf(kind) {
  const s = samples.get(kind);
  return s ? { file: s.file, message: s.message, message_en: s.message_en, sample: s.sample } : undefined;
}

/** Turn the last 24h of counters (by log time) into user-facing errors / warnings / notes. */
function issues() {
  const out = [];
  // title / detail are [zh, en] pairs (or one language-neutral string). `title` / `detail` stay
  // Chinese for the menu bar app; the dashboard switches to `title_en` / `detail_en`.
  const pair = v => Array.isArray(v) ? v : [v, v];
  const add = (level, agent, id, title, detail, extra) => {
    const [t, tEn] = pair(title), [d, dEn] = pair(detail);
    out.push({ level, agent, id, title: t, detail: d, title_en: tEn, detail_en: dEn, ...extra });
  };
  const n2 = (zh, en) => [zh, en];
  const reasons = l => l.map(([k, n]) => `${k.split('.')[1]} ×${n}`);

  if (!fs.existsSync(CLAUDE_DIR)) add('error', 'claude', 'claude.dir', n2('找不到 Claude Code 日志目录', 'Claude Code log directory not found'), CLAUDE_DIR);
  if (!fs.existsSync(CODEX_DIR)) add('error', 'codex', 'codex.dir', n2('找不到 Codex 日志目录', 'Codex log directory not found'), CODEX_DIR);

  for (const agent of ['claude', 'codex']) {
    const pe = recentCount(`${agent}.parse_error`);
    if (pe) add('error', agent, `${agent}.parse_error`,
      n2(`${NAMES[agent]} 日志有 ${pe} 行解析失败`, `${pe} ${NAMES[agent]} log line(s) failed to parse`),
      n2('这些行被跳过，相关调用可能缺失。通常意味着日志格式变了。', 'These lines were skipped, so some calls may be missing. Usually this means the log format changed.'),
      sampleOf(`${agent}.parse_error`));
    const since = Date.now() - DIAG_WINDOW_MS;
    const bad = [...calls.values()].filter(c => c.agent === agent && c.ts >= since && implausible(c));
    if (bad.length) add('warn', agent, `${agent}.anomaly`,
      n2(`${NAMES[agent]} 有 ${bad.length} 次调用数值异常`, `${bad.length} ${NAMES[agent]} call(s) have implausible values`),
      n2('TTFT 大于总耗时、TPS 超过 3000 或耗时超过 3 小时，时间戳可能配错了对。', 'TTFT longer than the call, TPS above 3000, or a call over 3 hours: timestamps were probably mismatched.'),
      { file: bad[0].id, message: `ttft=${bad[0].ttft_ms}ms duration=${bad[0].duration_ms}ms tps=${bad[0].tps}` });
  }

  // Claude Code: every assistant block should land in a call.
  const seen = recentCount('claude.block_seen'), used = recentCount('claude.block_used');
  const dropped = ['claude.drop_no_usage', 'claude.drop_orphan', 'claude.drop_backwards'].map(k => [k, recentCount(k)]).filter(([, n]) => n);
  if (seen >= 5 && used / seen < 0.8) {
    const worst = dropped.sort((a, b) => b[1] - a[1])[0];
    add('error', 'claude', 'claude.yield',
      n2(`Claude Code 规则可能失效：${seen - used}/${seen} 个响应块没有计入调用`, `Claude Code rules may be broken: ${seen - used}/${seen} response blocks were not counted`),
      n2(`统计规则依赖 api-request 记录 + requestRef 关联 + message.usage。主要丢弃原因：${reasons(dropped).join('，')}`,
        `The rules rely on api-request entries, requestRef links and message.usage. Main drop reasons: ${reasons(dropped).join(', ')}`),
      worst && sampleOf(worst[0]));
  }
  const calls24 = recentCount('claude.call'), fb = recentCount('claude.fallback_start') - recentCount('claude.fallback_resolved');
  // Normal is ~0%; above 10% (with enough calls to judge) Claude Code has stopped linking requests.
  if (fb > 0) add(calls24 >= 20 && fb / calls24 > 0.1 ? 'error' : 'warn', 'claude', 'claude.fallback',
    n2(`${fb}/${calls24} 次 Claude Code 调用用了回退规则`, `${fb}/${calls24} Claude Code calls used the fallback rule`),
    n2('没找到对应的 api-request 记录，请求起点改用上一条 user 记录，TTFT 和 TPS 会偏差较大。比例高说明 Claude Code 不再写 api-request。',
      'No matching api-request entry, so the previous user entry was used as the start; TTFT and TPS can be far off. A high share means Claude Code stopped writing api-request.'),
    sampleOf('claude.fallback_start'));
  const req = recentCount('claude.request'), unanswered = recentCount('claude.request_unanswered');
  if (req >= 10 && unanswered / req > 0.3) add('warn', 'claude', 'claude.unanswered',
    n2(`${unanswered}/${req} 个 Claude Code 请求没有匹配到响应`, `${unanswered}/${req} Claude Code requests matched no response`),
    n2('中断的请求会这样；比例持续很高说明 requestRef 关联规则失效。', 'Interrupted requests look like this; a persistently high share means the requestRef link rule is broken.'));

  // Coverage: a busy Claude Code log where no pre-filter matches anything means the format moved.
  const lines = recentCount('claude.line', Date.now() - 3600e3), matched = recentCount('claude.line_matched', Date.now() - 3600e3);
  if (lines >= 20 && matched === 0) add('error', 'claude', 'claude.coverage',
    n2(`Claude Code 日志格式无法识别：最近 ${lines} 行没有一行匹配规则`, `Claude Code log format not recognized: none of the last ${lines} lines match a rule`),
    n2('规则查找 "type":"api-request" / "assistant" / "user" 记录，可能字段名或结构变了。', 'The rules look for "type":"api-request" / "assistant" / "user" entries; field names or structure may have changed.'));

  // Codex: one token_usage_record per API call, mirrored by a token_count event.
  const tc = recentCount('codex.token_count'), rec = recentCount('codex.record');
  if (tc >= 5 && rec / tc < 0.8) add('error', 'codex', 'codex.yield',
    n2(`Codex 规则可能失效：${tc} 次调用只解析到 ${rec} 条 token_usage_record`, `Codex rules may be broken: ${tc} calls but only ${rec} token_usage_record entries`),
    n2('统计依赖 token_usage_record（每次 Responses API 调用一条）。该版本的 Codex 可能改名或不再写入，调用会被漏掉。',
      'The stats rely on token_usage_record (one per Responses API call). This Codex version may have renamed or dropped it, so calls are being missed.'));
  for (const [k, zh, en] of [
    ['codex.no_start', '次 Codex 调用找不到请求起点', 'Codex call(s) with no request start'],
    ['codex.no_model', '次 Codex 调用缺少模型名', 'Codex call(s) without a model name'],
    ['codex.no_response_id', '条 Codex 用量记录缺少 response_id', 'Codex usage record(s) without response_id'],
    ['codex.unrecognized_line', '行 Codex 日志结构无法识别', 'Codex log line(s) with an unrecognized structure']]) {
    const n = recentCount(k), smp = samples.get(k);
    if (n) add('warn', 'codex', k, n2(`${n} ${zh}`, `${n} ${en}`), n2(smp?.message || '', smp?.message_en || ''), sampleOf(k));
  }

  for (const e of runtimeErrors.slice(-3)) add('error', null, `runtime:${e.where}`, n2(`采集服务内部错误：${e.where}`, `Collector internal error: ${e.where}`), e.message);

  // Write each problem to the report the first time it shows up (again only after it clears).
  const ids = new Set(out.map(i => i.id));
  for (const i of out) if (!seenIssues.has(i.id)) { seenIssues.add(i.id); report(i); }
  for (const id of seenIssues) if (!ids.has(id)) seenIssues.delete(id);
  const rank = { error: 0, warn: 1 };
  return out.sort((a, b) => rank[a.level] - rank[b.level]);
}

// Only errors change the status (badge, notification, banner); warnings are kept in the report.
const statusOf = list => list.some(i => i.level === 'error') ? 'error' : 'ok';

// ---------------------------------------------------------------- stats

function pct(arr, p) {
  if (!arr.length) return null;
  const s = [...arr].sort((a, b) => a - b);
  const i = (p / 100) * (s.length - 1);
  const lo = Math.floor(i), hi = Math.ceil(i);
  return round(s[lo] + (s[hi] - s[lo]) * (i - lo), 1);
}

function aggregate(list) {
  const ttft = list.map(c => c.ttft_ms).filter(x => x != null);
  const tpsCalls = list.filter(c => c.tps != null && c.output_tokens >= MIN_TPS_TOKENS);
  const tps = tpsCalls.map(c => c.tps);
  const sum = k => list.reduce((a, c) => a + (c[k] || 0), 0);
  const durMs = tpsCalls.reduce((a, c) => a + c.duration_ms, 0);
  const outTok = tpsCalls.reduce((a, c) => a + c.output_tokens, 0);
  return {
    calls: list.length,
    ttft_p50: pct(ttft, 50), ttft_p90: pct(ttft, 90),
    tps_p50: pct(tps, 50), tps_p10: pct(tps, 10), tps_p90: pct(tps, 90),
    // Token-weighted throughput over all qualifying calls.
    tps_weighted: durMs ? round(outTok / (durMs / 1000)) : null,
    input_tokens: sum('input_tokens'), cached_tokens: sum('cached_tokens'),
    output_tokens: sum('output_tokens'), reasoning_tokens: sum('reasoning_tokens'),
  };
}

function slim(c) {
  const { first, end, ttft_reported, ...rest } = c;
  return { ...rest, ttft_source: ttft_reported != null ? 'codex' : 'block' };
}

const sorted = () => [...calls.values()].sort((a, b) => a.ts - b.ts);

function summary(windowSec) {
  const since = Date.now() - windowSec * 1000;
  const all = sorted();
  const agents = {};
  for (const agent of ['claude', 'codex']) {
    const mine = all.filter(c => c.agent === agent);
    const recent = mine.filter(c => c.ts >= since);
    const byModel = {};
    for (const c of recent) (byModel[c.model || 'unknown'] ??= []).push(c);
    // ~30–40 points per window, on round minute/hour boundaries.
    const bucketMs = [5, 10, 15, 30, 60, 120, 180, 360, 720].map(m => m * 60e3).find(b => windowSec * 1000 / b <= 40) ?? 1440 * 60e3;
    const historyOf = calls => {
      const buckets = new Map();
      for (const c of calls) {
        const k = Math.floor(c.ts / bucketMs) * bucketMs;
        if (!buckets.has(k)) buckets.set(k, []);
        buckets.get(k).push(c);
      }
      return [...buckets].sort((a, b) => a[0] - b[0]).map(([ts, l]) => {
        const a = aggregate(l);
        return { ts, calls: a.calls, ttft: a.ttft_p50, tps: a.tps_p50, out: a.output_tokens };
      });
    };
    agents[agent] = {
      ...aggregate(recent),
      last: mine.length ? slim(mine.at(-1)) : null,
      // Most recent call long enough for a meaningful TPS — what the menu bar shows.
      last_valid: (c => c ? slim(c) : null)(mine.findLast(c => c.tps != null && c.output_tokens >= MIN_TPS_TOKENS)),
      recent: mine.slice(-60).map(c => ({ ts: c.ts, ttft: c.ttft_ms, tps: c.tps, out: c.output_tokens, model: c.model })),
      history: historyOf(recent),
      bucket_ms: bucketMs,
      models: Object.entries(byModel).map(([model, l]) => ({
        model, ...aggregate(l), history: historyOf(l),
        recent: mine.filter(c => (c.model || 'unknown') === model).slice(-60)
          .map(c => ({ ts: c.ts, ttft: c.ttft_ms, tps: c.tps, out: c.output_tokens, model: c.model })),
      })).sort((a, b) => b.calls - a.calls),
      projects: Object.entries(Object.groupBy(recent, c => c.project || 'unknown'))
        .map(([project, l]) => ({ project, ...aggregate(l) })).sort((a, b) => b.calls - a.calls).slice(0, 12),
      live: [...pending.values()].filter(p => p.agent === agent).map(p => ({ model: p.model, elapsed_ms: Date.now() - p.ts })),
    };
  }
  const list = indexing ? [] : issues();
  return {
    now: Date.now(), window: windowSec, indexing, min_tps_tokens: MIN_TPS_TOKENS, agents,
    status: statusOf(list), issues: list, verified: VERIFIED, report_file: REPORT_FILE.replace(HOME, '~'), lang: prefs.lang ?? null,
  };
}

// ---------------------------------------------------------------- server

function sendJson(res, obj, status = 200) {
  res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store', 'access-control-allow-origin': '*' });
  res.end(JSON.stringify(obj));
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://x');
  try {
    if (url.pathname === '/' || url.pathname === '/index.html') {
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
      return fs.createReadStream(path.join(HERE, 'dashboard.html')).pipe(res);
    }
    if (url.pathname.startsWith('/assets/')) {
      // Only plain file names inside ../assets — no traversal.
      const name = path.basename(url.pathname);
      const type = { '.svg': 'image/svg+xml', '.png': 'image/png' }[path.extname(name)];
      const file = path.join(HERE, '..', 'assets', name);
      if (!type || !fs.existsSync(file)) return sendJson(res, { error: 'not found' }, 404);
      res.writeHead(200, { 'content-type': type, 'cache-control': 'max-age=3600' });
      return fs.createReadStream(file).pipe(res);
    }
    if (url.pathname === '/api/health') {
      const list = indexing ? [] : issues();
      return sendJson(res, { ok: true, status: statusOf(list), issues: list, pid: process.pid, indexing, files: files.size, calls: calls.size });
    }
    if (url.pathname === '/api/prefs') {
      if (req.method !== 'POST') return sendJson(res, prefs);
      let body = '';
      req.on('data', d => { body += d; if (body.length > 1024) req.destroy(); });
      req.on('end', () => {
        let lang;
        try { lang = JSON.parse(body).lang; } catch {}
        if (!['zh', 'en'].includes(lang)) return sendJson(res, { error: 'lang must be zh or en' }, 400);
        prefs = { ...prefs, lang };
        try { fs.mkdirSync(path.dirname(PREFS_FILE), { recursive: true }); fs.writeFileSync(PREFS_FILE, JSON.stringify(prefs)); }
        catch (e) { runtimeError('prefs', e); }
        broadcast('prefs', prefs);
        sendJson(res, prefs);
      });
      return;
    }
    if (url.pathname === '/api/summary') return sendJson(res, summary(Number(url.searchParams.get('window')) || 3600));
    if (url.pathname === '/api/calls') {
      const agent = url.searchParams.get('agent');
      const limit = Math.min(Number(url.searchParams.get('limit')) || 200, 5000);
      let list = sorted();
      if (agent) list = list.filter(c => c.agent === agent);
      return sendJson(res, list.slice(-limit).reverse().map(slim));
    }
    if (url.pathname === '/api/events') {
      res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-store', connection: 'keep-alive' });
      res.write(': hi\n\n');
      subscribers.add(res);
      req.on('close', () => subscribers.delete(res));
      return;
    }
    sendJson(res, { error: 'not found' }, 404);
  } catch (e) {
    console.error(e);
    if (!res.headersSent) sendJson(res, { error: String(e.message) }, 500);
  }
});

// `--open` (used by Spoolup.cmd on Windows, where there is no menu bar app) opens the dashboard in
// the default browser once indexing is done, or right away if a collector is already running.
const OPEN = process.argv.includes('--open');
function openBrowser() {
  const url = `http://${HOST}:${PORT}/`;
  const [cmd, args] = process.platform === 'win32' ? ['cmd', ['/c', 'start', '', url]]
    : process.platform === 'darwin' ? ['open', [url]] : ['xdg-open', [url]];
  try { spawn(cmd, args, { detached: true, stdio: 'ignore', windowsHide: true }).unref(); }
  catch (e) { console.error(`[spoolup] open ${url} yourself: ${e.message}`); }
}
server.on('error', e => {
  if (e.code === 'EADDRINUSE' && OPEN) { console.log('Spoolup is already running; opening the dashboard.'); openBrowser(); setTimeout(() => process.exit(0), 500); return; }
  console.error(e.message);
  process.exit(1);
});

server.listen(PORT, HOST, () => {
  console.log(`Spoolup on http://${HOST}:${PORT} — indexing last ${DAYS} days…`);
  const t0 = Date.now();
  scan();
  indexing = false;
  console.log(`indexed ${files.size} files, ${calls.size} calls in ${Date.now() - t0} ms`);
  issues(); // surface anything found during indexing in the log right away
  broadcast('ready', {});
  if (OPEN) openBrowser();
  setInterval(scan, Number(process.env.SPOOLUP_POLL_MS || 1500));
  process.on('uncaughtException', e => runtimeError('uncaught', e));
  setInterval(() => { for (const r of subscribers) r.write(': ping\n\n'); }, 20000);
});
