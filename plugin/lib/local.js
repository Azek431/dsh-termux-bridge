'use strict'
/**
 * 客人侧本地执行面 —— 不依赖 Termux 的那一半。
 *
 * 为什么需要它：DSH 跑在一个 Debian 13 (aarch64) 的 PRoot 客人里，
 * 里面有 bash / gcc / node / python3 / ffmpeg，还有 fakeroot 版 apt。
 * 这些能力一直都在，但插件此前只认 Termux agent，没连上就整条命令都执行不了。
 *
 * 语义上刻意与 Termux agent 对齐（同名字段、同样的 exitCode 97 = cwd 不存在、
 * 同样的 timedOut 判定），这样上层工具不需要为两个执行面写两套分支。
 *
 * 与 agent 侧的差异（必须知道）：
 * - 这里能拿到的权限就是 DSH 客人自己的权限（uid 10496），不是 Termux 的 uid；
 * - 这里看不到 Termux 的 ~ 与 $PREFIX，看到的是客人的 / 与 /root/projects；
 * - 超时用 SIGKILL 打进程组，子进程不会漏（agent 侧用 timeout(1)）。
 */

const { spawn } = require('node:child_process')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')

const MAX_OUTPUT_BYTES = 1024 * 1024
const STDERR_CAP = 64 * 1024
const EXIT_CWD_MISSING = 97
const EXIT_SPAWN_FAILED = 98
const DEFAULT_TIMEOUT_MS = 30000
const MAX_READ_BYTES = 8 * 1024 * 1024

function nowMs () { return Number(process.hrtime.bigint() / 1000000n) }

function fail (message, code, extra) {
  const err = new Error(message)
  err.code = code || 'E_LOCAL'
  if (extra) Object.assign(err, extra)
  return err
}

/** 把 ~ / ~/x 换成客人自己的 home；其它原样返回。 */
function expandHome (p) {
  const value = String(p || '')
  if (value === '~') return os.homedir()
  if (value.startsWith('~/')) return path.join(os.homedir(), value.slice(2))
  return value
}

/** 收集 stdout/stderr，超过上限只留前 cap 字节并打 truncated 标记。 */
function makeSink (cap) {
  const chunks = []
  let size = 0
  let truncated = false
  return {
    push (buf) {
      if (size >= cap) { truncated = true; return }
      const room = cap - size
      if (buf.length > room) {
        chunks.push(buf.subarray(0, room))
        size = cap
        truncated = true
      } else {
        chunks.push(buf)
        size += buf.length
      }
    },
    get truncated () { return truncated },
    text () { return Buffer.concat(chunks).toString('utf8') },
    bytes () { return size }
  }
}

function clampTimeout (value) {
  const n = Number(value) || DEFAULT_TIMEOUT_MS
  return Math.min(600000, Math.max(1000, n))
}

/**
 * 在客人里跑一段 bash 脚本。
 * @param {{script?: string, cwd?: string, timeoutMs?: number, maxBytes?: number}} options
 */
async function runScript (options) {
  const opts = options || {}
  const script = String(opts.script || '')
  if (!script.trim()) throw fail('脚本为空', 'E_INVALID_ARGUMENT')
  const timeoutMs = clampTimeout(opts.timeoutMs)
  const maxBytes = Math.min(MAX_OUTPUT_BYTES, Math.max(1024, Number(opts.maxBytes) || 65536))

  let dir = ''
  try {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-local-'))
  } catch (err) {
    throw fail('无法创建临时目录: ' + ((err && err.message) || err), 'E_LOCAL_TMPDIR')
  }

  const bodyPath = path.join(dir, 'body.sh')
  fs.writeFileSync(bodyPath, script, 'utf8')

  // cwd 不存在时与 agent 侧保持同一语义（exitCode 97），不要让 spawn 抛 ENOENT 让人猜。
  let cwd = opts.cwd ? expandHome(opts.cwd) : ''
  if (cwd) {
    let st = null
    try { st = fs.statSync(cwd) } catch { st = null }
    if (!st || !st.isDirectory()) {
      cleanup(dir)
      return {
        ok: false,
        exitCode: EXIT_CWD_MISSING,
        timedOut: false,
        truncated: false,
        stdout: '',
        stderr: 'cwd 不存在或不是目录: ' + cwd,
        totalMs: 0,
        timeoutMs,
        backend: 'local',
        agent: 'local:guest'
      }
    }
  } else {
    cwd = os.homedir() || '/'
  }

  const started = nowMs()
  const out = makeSink(maxBytes)
  const errSink = makeSink(STDERR_CAP)

  return await new Promise((resolve) => {
    let child
    try {
      // detached 让子进程自成进程组，超时时可以整组打掉，避免留下孙进程。
      child = spawn('bash', [bodyPath], {
        cwd,
        detached: true,
        stdio: ['ignore', 'pipe', 'pipe'],
        env: Object.assign({}, process.env, { DSH_EXEC_BACKEND: 'local' })
      })
    } catch (err) {
      cleanup(dir)
      resolve({
        ok: false,
        exitCode: EXIT_SPAWN_FAILED,
        timedOut: false,
        truncated: false,
        stdout: '',
        stderr: 'spawn 失败: ' + ((err && err.message) || err),
        totalMs: nowMs() - started,
        timeoutMs,
        backend: 'local',
        agent: 'local:guest'
      })
      return
    }

    let timedOut = false
    let settled = false
    const timer = setTimeout(() => {
      timedOut = true
      try { process.kill(-child.pid, 'SIGKILL') } catch { try { child.kill('SIGKILL') } catch {} }
    }, timeoutMs)
    if (timer.unref) timer.unref()

    child.stdout.on('data', (buf) => out.push(buf))
    child.stderr.on('data', (buf) => errSink.push(buf))

    const done = (exitCode) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      cleanup(dir)
      const totalMs = nowMs() - started
      const code = timedOut ? 124 : exitCode
      resolve({
        ok: code === 0 && !timedOut,
        exitCode: code,
        timedOut,
        truncated: out.truncated,
        stdout: out.text(),
        stderr: errSink.text(),
        totalMs,
        timeoutMs,
        backend: 'local',
        agent: 'local:guest'
      })
    }

    child.on('error', (err) => {
      errSink.push(Buffer.from('spawn 失败: ' + ((err && err.message) || err) + '\n'))
      done(EXIT_SPAWN_FAILED)
    })
    child.on('close', (code, signal) => {
      if (code === null && signal) done(timedOut ? 124 : 128 + 9)
      else done(typeof code === 'number' ? code : EXIT_SPAWN_FAILED)
    })
  })
}

/** 客人内写文件（覆盖写），目录不存在则创建。用于 backend=local 的 push。 */
async function writeFile (content, target, options) {
  const opts = options || {}
  const abs = path.resolve(expandHome(target))
  const data = Buffer.from(String(content == null ? '' : content), 'utf8')
  if (opts.maxBytes && data.length > Number(opts.maxBytes)) {
    throw fail('内容超过上限 ' + opts.maxBytes + ' 字节', 'E_CONTENT_TOO_LARGE')
  }
  fs.mkdirSync(path.dirname(abs), { recursive: true })
  fs.writeFileSync(abs, data)
  return { ok: true, bytes: data.length, remote: abs }
}

/** 客人内读文件，超过上限只返回前 cap 字节并置 truncated。用于 backend=local 的 pull。 */
async function readFile (target, options) {
  const opts = options || {}
  const abs = path.resolve(expandHome(target))
  const cap = Math.min(MAX_READ_BYTES, Math.max(1024, Number(opts.maxBytes) || MAX_READ_BYTES))
  let st
  try { st = fs.statSync(abs) } catch {
    return { ok: false, bytes: 0, truncated: false, data: '', remote: abs, stderr: '文件不存在: ' + abs }
  }
  if (!st.isFile()) {
    return { ok: false, bytes: 0, truncated: false, data: '', remote: abs, stderr: '不是普通文件: ' + abs }
  }
  const fd = fs.openSync(abs, 'r')
  try {
    const want = Math.min(cap, st.size)
    const buf = Buffer.alloc(want)
    const n = want > 0 ? fs.readSync(fd, buf, 0, want, 0) : 0
    return { ok: true, bytes: n, truncated: st.size > n, data: buf.subarray(0, n).toString('utf8'), remote: abs }
  } finally {
    try { fs.closeSync(fd) } catch {}
  }
}

/** 探测客人里常见工具链的位置，给 termux_status 显示用。 */
function probeTools () {
  const { execFileSync } = require('node:child_process')
  const seen = {}
  for (const name of ['bash', 'node', 'pnpm', 'python3', 'git', 'gcc', 'make', 'ffmpeg', 'curl', 'sqlite3']) {
    try {
      const p = execFileSync('sh', ['-c', 'command -v ' + name], { encoding: 'utf8', timeout: 3000 }).trim()
      if (p) seen[name] = p
    } catch {}
  }
  return seen
}

function cleanup (dir) {
  if (!dir) return
  try { fs.rmSync(dir, { recursive: true, force: true }) } catch {}
}

module.exports = {
  runScript,
  writeFile,
  readFile,
  probeTools,
  expandHome,
  EXIT_CWD_MISSING,
  EXIT_SPAWN_FAILED,
  MAX_OUTPUT_BYTES,
  MAX_READ_BYTES
}
