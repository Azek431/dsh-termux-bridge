'use strict'
/**
 * 桥接服务器：在 PRoot 客人（DSH 所在侧）里监听 127.0.0.1，等 Termux 侧的
 * agent 主动连进来，然后把「执行命令 / 传文件」的请求派给它。
 *
 * 为什么方向是「Termux 连进来」而不是「我们连出去」：
 * 客人里没有 am / su，拉不起 Termux 进程，也没有共享文件系统；唯一的联系
 * 是两边共享 network namespace。所以只能由用户在 Termux 里手动起一次
 * agent，让它连回 loopback。
 *
 * 并发模型：宿主是单通道消费者，agent 侧一个进程只能同时跑一条命令，
 * 所以这里严格串行化——忙的 agent 不再派活，多的请求排队；agent 忙时
 * 也不并派第二个 agent，因为同一台手机上并发跑命令只会互相干扰。
 */

const net = require('node:net')
const os = require('node:os')
const crypto = require('node:crypto')
const { EventEmitter } = require('node:events')
const proto = require('./protocol.js')

const DEFAULT_PORT = 8791
const DEFAULT_HOST = '127.0.0.1'
const DEFAULT_TIMEOUT_MS = 30000
const MIN_TIMEOUT_MS = 1000
const MAX_TIMEOUT_MS = 600000
/** 客人侧比 agent 侧多等的宽限：agent 自己的 timeout 会先杀掉命令并回包。 */
const GRACE_MS = 15000
const HEARTBEAT_MS = 30000
const HEARTBEAT_DEAD_MS = 90000
const MAX_AGENTS = 8
const MAX_QUEUE = 32
const ACQUIRE_WAIT_MS = 15000
/** 一次 PUT/GET 的原始分片大小；base64 后约 64KiB，远小于单帧上限。 */
const CHUNK_BYTES = 48 * 1024
/**
 * pull 的默认上限与候选上限都必须夹在协议单帧载荷之内。
 * 曾经踩过的坑：这里写死 8MiB，而 MAX_LINE_BYTES 是 1MiB，
 * 结果 pull 一个 4MB 的 base64 文本直接让对端 destroy 连接，
 * 界面上表现为 E_AGENT_GONE（像是 agent 崩了），实际是帧太大。
 */
const DEFAULT_PULL_MAX = 8 * 1024 * 1024
const MAX_OUTPUT_BYTES = 1024 * 1024

/** 把任何「要放进一帧」的字节数夹到协议能承载的范围。 */
function clampPayload (n, fallback) {
  const v = Number(n) || fallback
  return Math.min(proto.MAX_PAYLOAD_BYTES, Math.max(1024, v))
}
const TRANSFER_TIMEOUT_MS = 60000

let seqCounter = 0
function nextId (prefix) {
  seqCounter = (seqCounter + 1) % 0xffffff
  return prefix + '-' + Date.now().toString(36) + '-' + seqCounter.toString(36)
}

function nowMs () {
  return Number(process.hrtime.bigint() / 1000000n)
}

function clampTimeout (value) {
  const n = Number(value)
  if (!Number.isFinite(n)) return DEFAULT_TIMEOUT_MS
  return Math.min(MAX_TIMEOUT_MS, Math.max(MIN_TIMEOUT_MS, Math.floor(n)))
}

function fail (message, code, extra) {
  return Object.assign(new Error(message), { code }, extra)
}

/** 一条已建立的连接。HELLO 通过前 registered=false，不参与派活。 */
class Agent {
  constructor (socket, peer) {
    this.id = nextId('ag')
    this.socket = socket
    this.name = ''
    this.peer = peer || ''
    this.connectedAt = Date.now()
    this.lastSeenAt = Date.now()
    this.registered = false
    this.busy = false
    this.lastUsedAt = 0
    this.jobs = 0
    this.buf = ''
    this.http = undefined
  }
}

class Bridge extends EventEmitter {
  constructor (config) {
    super()
    this.setMaxListeners(50)
    const cfg = config || {}
    this.host = cfg.host || DEFAULT_HOST
    this.port = Number.isInteger(cfg.port) ? cfg.port : DEFAULT_PORT
    this.actualPort = 0
    this.maxAgents = Math.max(1, Math.min(32, Number(cfg.maxAgents) || MAX_AGENTS))
    const given = String(cfg.token || '')
    this.tokenGenerated = given === ''
    this.token = given || crypto.randomBytes(16).toString('hex')
    this.startedAt = 0
    this.server = null
    this.connections = new Set()
    this.agents = new Set()
    this.pending = new Map()
    this.waiters = []
    this.heartbeat = null
    this.listening = false
    this.lastError = ''
    this.totalJobs = 0
    this.lastJob = null
    /** (req) => {status, headers, body};用于在同端口上提供 bootstrap 脚本下载。 */
    this.httpHandler = typeof cfg.httpHandler === 'function' ? cfg.httpHandler : null
  }

  // ── 生命周期 ──────────────────────────────────────────────────────────

  /**
   * 起监听。端口被占时依次试 +1..+9，最终端口写进 actualPort。
   * 全部失败只记 lastError 并返回 false —— 插件加载不能因为端口被占就炸掉宿主。
   */
  async start () {
    if (this.server) return this.listening
    for (let attempt = 0; attempt <= 9; attempt += 1) {
      const port = this.port + attempt
      const outcome = await this.#listenOnce(port)
      if (outcome.ok) {
        this.server = outcome.server
        this.actualPort = port
        this.startedAt = Date.now()
        this.listening = true
        this.lastError = ''
        this.#startHeartbeat()
        return true
      }
      this.lastError = outcome.error
      if (outcome.code !== 'EADDRINUSE') break
    }
    this.server = null
    this.listening = false
    return false
  }

  #listenOnce (port) {
    return new Promise((resolve) => {
      const server = net.createServer((socket) => this.#onConnection(socket))
      const onError = (err) => {
        server.removeListener('listening', onListening)
        try { server.close() } catch {}
        resolve({
          ok: false,
          code: err && err.code ? String(err.code) : '',
          error: ((err && err.code) ? err.code + ': ' : '') + ((err && err.message) || String(err))
        })
      }
      const onListening = () => {
        server.removeListener('error', onError)
        server.on('error', (err) => {
          this.lastError = ((err && err.code) ? err.code + ': ' : '') + ((err && err.message) || String(err))
        })
        resolve({ ok: true, server })
      }
      server.once('error', onError)
      server.once('listening', onListening)
      try { server.listen(port, this.host) } catch (err) { onError(err) }
    })
  }

  stop () {
    this.#stopHeartbeat()
    for (const [, entry] of [...this.pending]) {
      clearTimeout(entry.timer)
      entry.reject(fail('桥接服务器已停止', 'E_BRIDGE_STOPPED'))
    }
    this.pending.clear()
    for (const conn of this.connections) {
      try { conn.socket.destroy() } catch {}
    }
    this.connections.clear()
    this.agents.clear()
    for (const waiter of this.waiters) waiter.reject(fail('桥接服务器已停止', 'E_BRIDGE_STOPPED'))
    this.waiters = []
    if (this.server) {
      try { this.server.close() } catch {}
      this.server = null
    }
    this.listening = false
  }

  // ── 连接与帧 ──────────────────────────────────────────────────────────

  #onConnection (socket) {
    socket.setNoDelay(true)
    socket.setEncoding('utf8')
    const agent = new Agent(socket, (socket.remoteAddress || '') + ':' + (socket.remotePort || 0))
    this.connections.add(agent)
    socket.on('data', (chunk) => this.#onData(agent, chunk))
    socket.on('error', () => {})
    socket.on('close', () => this.#dropAgent(agent, '连接已关闭'))
  }

  #onData (agent, chunk) {
    agent.buf += chunk
    if (agent.http === undefined) {
      // 同一端口上既跑帧协议,也跑一个极小的 HTTP 面(bootstrap 脚本下载)。
      // 首行前五个字符就能分清:帧协议的 tag 全是纯字母,HTTP 一定是 GET/HEAD。
      agent.http = /^(GET|HEAD) /.test(agent.buf.slice(0, 5)) && /^(GET|HEAD) /.test(agent.buf)
    }
    if (agent.http) { this.#onHttpData(agent); return }
    if (agent.buf.length > proto.MAX_LINE_BYTES && agent.buf.indexOf('\n') < 0) {
      // 单行就已经超限：不在内存里继续堆积。
      agent.socket.destroy()
      return
    }
    let index = agent.buf.indexOf('\n')
    while (index >= 0) {
      const line = agent.buf.slice(0, index)
      agent.buf = agent.buf.slice(index + 1)
      if (line.length > proto.MAX_LINE_BYTES) { agent.socket.destroy(); return }
      this.#onLine(agent, line)
      index = agent.buf.indexOf('\n')
    }
  }

  /**
   * 极简 HTTP:只认 GET/HEAD,只回文本/脚本。存在的理由只有一个 ——
   * 客人与 Termux 没有共享文件系统,用户拿不到插件生成的启动脚本,
   * 只能让 Termux 里的 curl 直接把它抓过去:curl -fsSL <url> | bash。
   */
  #onHttpData (agent) {
    if (agent.buf.length > 16384) { agent.socket.destroy(); return }
    const end = agent.buf.indexOf('\r\n\r\n')
    if (end < 0) return
    const head = agent.buf.slice(0, end).split('\r\n')
    const [method, target] = (head[0] || '').split(' ')
    const reply = (status, headers, body) => {
      const buf = Buffer.from(body || '', 'utf8')
      const lines = ['HTTP/1.1 ' + status]
      lines.push('Content-Type: ' + (headers['content-type'] || 'text/plain; charset=utf-8'))
      lines.push('Content-Length: ' + buf.length)
      lines.push('Cache-Control: no-store')
      lines.push('Connection: close')
      lines.push('', '')
      try { agent.socket.write(lines.join('\r\n')) } catch {}
      if (method !== 'HEAD') { try { agent.socket.write(buf) } catch {} }
      setTimeout(() => { try { agent.socket.end() } catch {} }, 20)
    }
    if (!this.httpHandler) { reply('404 Not Found', {}, 'not found'); return }
    let result
    try {
      result = this.httpHandler({ method: method || 'GET', target: target || '/', headers: head.slice(1) })
    } catch (err) {
      reply('500 Internal Server Error', {}, 'handler error: ' + ((err && err.message) || err))
      return
    }
    if (!result) { reply('404 Not Found', {}, 'not found'); return }
    reply(result.status || '200 OK', result.headers || {}, result.body || '')
  }

  #onLine (agent, line) {
    const frame = proto.decodeFrame(line)
    if (!frame) return
    agent.lastSeenAt = Date.now()
    const f = frame.fields
    if (frame.tag === 'HELLO') { this.#onHello(agent, f); return }
    if (frame.tag === 'PING') { this.#send(agent, proto.encodeFrame('PONG', [f[0] || ''])); return }
    if (frame.tag === 'PONG') return
    if (frame.tag === 'BYE') { this.#dropAgent(agent, 'agent 主动退出'); return }
    if (frame.tag === 'RESULT') { this.#settle(agent, f, 'result'); return }
    if (frame.tag === 'DATA') { this.#settle(agent, f, 'data'); return }
    // 未知帧：忽略但不断开，便于协议向前兼容。
  }

  #settle (agent, fields, kind) {
    const id = fields[0]
    const entry = this.pending.get(id)
    if (!entry) return
    this.pending.delete(id)
    clearTimeout(entry.timer)
    if (entry.release) this.#finish(entry.agent)
    const exitCode = Number.isFinite(Number(fields[1])) ? Number(fields[1]) : 6
    if (kind === 'data') {
      entry.resolve({
        ok: exitCode === 0,
        exitCode,
        truncated: fields[4] === '1',
        data: proto.decField(fields[2]),
        stderr: proto.decField(fields[3])
      })
      return
    }
    // fields[6] = agent 侧是否被 timeout 杀掉。有它才能把「命令自己返回 124」和
    // 「我们把它杀了」区分开：两者 exitCode 都是 124，但语义完全不同。
    const timedOut = fields[6] === '1'
    entry.resolve({
      ok: exitCode === 0 && !timedOut,
      exitCode,
      elapsedMs: Number(fields[2]) || 0,
      truncated: fields[3] === '1',
      timedOut,
      stdout: proto.decField(fields[4]),
      stderr: proto.decField(fields[5])
    })
  }

  #onHello (agent, fields) {
    if (agent.registered) return
    const ver = Number(fields[0])
    const token = proto.decField(fields[1])
    const deny = (code, text) => {
      this.#send(agent, proto.encodeFrame('DENY', [code, proto.encField(text)]))
      setTimeout(() => { try { agent.socket.destroy() } catch {} }, 50)
    }
    if (ver !== proto.PROTO_VERSION) {
      deny('E_PROTO_MISMATCH', '协议版本不匹配：客人侧要求 ' + proto.PROTO_VERSION + '，收到 ' + fields[0])
      return
    }
    if (token !== this.token) {
      deny('E_BAD_TOKEN', '令牌不匹配。请用 termux_bootstrap 重新生成启动脚本（令牌只在那个脚本里）。')
      return
    }
    const registered = [...this.agents].filter((a) => a.registered).length
    if (registered >= this.maxAgents) {
      deny('E_TOO_MANY_AGENTS', '已连接的 agent 达到上限 ' + this.maxAgents + '，请先停掉多余的 agent。')
      return
    }
    agent.registered = true
    agent.name = proto.decField(fields[2]) || 'termux'
    // 同名 agent 去重：同一个 Termux 只需要一条连接。旧实例遗留下来的同名连接
    // （例如 DSH 重启后旧 agent 还在重连、而令牌是配置里写死的固定值）如果不摘掉，
    // 一个 Termux 会占满 maxAgents，而且 #idleAgent 可能挑到那条半死的连接。
    for (const other of [...this.agents]) {
      if (other === agent || !other.registered || other.name !== agent.name) continue
      // 必须先发 BYE 再断。直接 destroy 的话，对面那个 agent 会立刻重连、然后又反过来
      // 把这条顶掉，两条连接乒乓对踢，永远不收敛。BYE 是告诉它「别再来了」。
      this.#send(other, proto.encodeFrame('BYE', [proto.encField('被同名 agent 顶替（可能是上次运行遗留的连接）')]))
      this.#dropAgent(other, '被同名 agent 顶替（可能是上次运行遗留的连接）')
      const stale = other.socket
      setTimeout(() => { try { stale.destroy() } catch {} }, 80)
    }
    this.agents.add(agent)
    this.#send(agent, proto.encodeFrame('WELCOME', [proto.PROTO_VERSION, proto.encField(os.hostname())]))
    this.emit('agent', agent)
    this.#drainWaiters()
  }

  #dropAgent (agent, reason) {
    this.connections.delete(agent)
    const wasRegistered = this.agents.delete(agent)
    if (agent.busy) this.#finish(agent)
    for (const [id, entry] of [...this.pending]) {
      if (entry.agent !== agent) continue
      this.pending.delete(id)
      clearTimeout(entry.timer)
      entry.reject(fail('agent 断开：' + reason, 'E_AGENT_GONE'))
    }
    if (wasRegistered) this.emit('agent-gone', agent)
  }

  #send (agent, text) {
    try { agent.socket.write(text); return true } catch { return false }
  }

  #startHeartbeat () {
    this.#stopHeartbeat()
    this.heartbeat = setInterval(() => {
      for (const agent of [...this.connections]) {
        if (Date.now() - agent.lastSeenAt > HEARTBEAT_DEAD_MS) {
          try { agent.socket.destroy() } catch {}
          continue
        }
        if (agent.registered) this.#send(agent, proto.encodeFrame('PING', [nextId('hb')]))
      }
    }, HEARTBEAT_MS)
    if (this.heartbeat.unref) this.heartbeat.unref()
  }

  #stopHeartbeat () {
    if (this.heartbeat) { clearInterval(this.heartbeat); this.heartbeat = null }
  }

  // ── 取用空闲 agent（严格串行） ────────────────────────────────────────

  #idleAgent () {
    let best = null
    for (const agent of this.agents) {
      if (!agent.registered || agent.busy) continue
      if (!best || agent.lastUsedAt < best.lastUsedAt) best = agent
    }
    return best
  }

  #occupy (agent) {
    agent.busy = true
    agent.lastUsedAt = Date.now()
    agent.jobs += 1
    return agent
  }

  async #acquire (waitMs) {
    const pick = this.#idleAgent()
    if (pick) return this.#occupy(pick)
    if (![...this.agents].some((a) => a.registered)) {
      throw fail('没有 Termux agent 连接。请在 Termux 里运行 termux_bootstrap 生成的启动脚本。', 'E_NO_AGENT')
    }
    if (this.waiters.length >= MAX_QUEUE) {
      throw fail('排队已满：' + MAX_QUEUE + ' 个请求在等空闲 agent', 'E_WRAPPER_QUEUE_FULL')
    }
    const wait = Math.max(0, Math.min(ACQUIRE_WAIT_MS, Number(waitMs) || ACQUIRE_WAIT_MS))
    return await new Promise((resolve, reject) => {
      let timer = null
      const waiter = {
        resolve: (agent) => { if (timer) clearTimeout(timer); resolve(agent) },
        reject: (err) => { if (timer) clearTimeout(timer); reject(err) }
      }
      timer = setTimeout(() => {
        this.waiters = this.waiters.filter((w) => w !== waiter)
        reject(fail('等空闲 agent 超时（' + wait + 'ms）：agent 正忙于其它命令', 'E_AGENT_BUSY', { retryable: true }))
      }, wait)
      if (timer.unref) timer.unref()
      this.waiters.push(waiter)
    })
  }

  #drainWaiters () {
    while (this.waiters.length) {
      const pick = this.#idleAgent()
      if (!pick) return
      const waiter = this.waiters.shift()
      waiter.resolve(this.#occupy(pick))
    }
  }

  #finish (agent) {
    agent.busy = false
    agent.lastUsedAt = Date.now()
    this.#drainWaiters()
  }

  /**
   * 发一帧并等回包。
   * release=false 用于多帧事务（例如分片 PUT），由调用方在最后一帧后释放。
   */
  #roundtrip (agent, id, frame, waitMs, what, release) {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id)
        if (release !== false) this.#finish(agent)
        reject(fail(what + ' 超时：agent 在 ' + waitMs + 'ms 内没有回包', 'E_AGENT_TIMEOUT', { retryable: true }))
      }, waitMs)
      if (timer.unref) timer.unref()
      this.pending.set(id, { agent, resolve, reject, timer, release: release !== false })
      if (!this.#send(agent, frame)) {
        this.pending.delete(id)
        clearTimeout(timer)
        if (release !== false) this.#finish(agent)
        reject(fail('写帧失败：agent 连接已不可用', 'E_AGENT_GONE'))
      }
    })
  }

  // ── 对外：执行脚本 ────────────────────────────────────────────────────

  /**
   * 在 Termux 里跑一段 bash 脚本。
   * @param {{script?: string, cwd?: string, timeoutMs?: number, maxBytes?: number, waitMs?: number}} options
   */
  async exec (options) {
    const opts = options || {}
    const script = String(opts.script || '')
    if (!script.trim()) throw fail('脚本为空', 'E_INVALID_ARGUMENT')
    if (Buffer.byteLength(script, 'utf8') > proto.MAX_SCRIPT_BYTES) {
      throw fail('脚本超过 ' + proto.MAX_SCRIPT_BYTES + ' 字节上限', 'E_INVALID_ARGUMENT')
    }
    const timeoutMs = clampTimeout(opts.timeoutMs)
    const maxBytes = clampPayload(Math.min(MAX_OUTPUT_BYTES, Number(opts.maxBytes) || 65536), 65536)
    const agent = await this.#acquire(opts.waitMs)
    const id = nextId('ex')
    const frame = proto.encodeFrame('EXEC', [
      id, timeoutMs, proto.encField(opts.cwd || ''), proto.encField(script), maxBytes
    ])
    const started = nowMs()
    this.totalJobs += 1
    const result = await this.#roundtrip(agent, id, frame, timeoutMs + GRACE_MS, '执行命令', true)
    const totalMs = nowMs() - started
    this.lastJob = { at: new Date().toISOString(), kind: 'exec', exitCode: result.exitCode, timedOut: !!result.timedOut, totalMs }
    return Object.assign(result, { agent: agent.name, agentId: agent.id, timeoutMs, totalMs })
  }

  /** 不发 shell 的执行：argv 逐项单引号包好再交给 bash。 */
  async execv (argv, options) {
    if (!Array.isArray(argv) || !argv.length) throw fail('argv 为空', 'E_INVALID_ARGUMENT')
    const quote = (s) => "'" + String(s).replace(/'/g, "'\\''") + "'"
    return this.exec(Object.assign({}, options, { script: argv.map(quote).join(' ') }))
  }

  // ── 对外：传文件 ──────────────────────────────────────────────────────

  /** 把客人侧的一段字节写到 Termux 里的 remotePath。 */
  async push (buffer, remotePath, options) {
    const opts = options || {}
    if (!remotePath) throw fail('remotePath 为空', 'E_INVALID_ARGUMENT')
    const data = Buffer.isBuffer(buffer) ? buffer : Buffer.from(String(buffer), 'utf8')
    const agent = await this.#acquire(opts.waitMs)
    let written = 0
    try {
      let offset = 0
      let first = true
      // 空文件也要发一帧，否则远端永远不会被创建。
      do {
        const chunk = data.subarray(offset, offset + CHUNK_BYTES)
        offset += chunk.length
        const mode = (first && opts.append !== true) ? 'w' : 'a'
        first = false
        const id = nextId('put')
        // 分片本身就是字节，只做一次 base64 —— 不要再套 encField(它会对字符串再编一次)：
        // 那会让远端写进文件的是 base64 文本，pull 回来再解一次就成了「base64 的 base64」。
        const payload = chunk.length ? chunk.toString('base64') : proto.EMPTY
        const frame = proto.encodeFrame('PUT', [id, mode, proto.encField(remotePath), payload])
        const last = offset >= data.length
        const r = await this.#roundtrip(agent, id, frame, TRANSFER_TIMEOUT_MS, '写远端文件', last)
        if (!r.ok) {
          return Object.assign(r, { bytes: written, remote: remotePath, agent: agent.name })
        }
        written += chunk.length
      } while (offset < data.length)
      this.lastJob = { at: new Date().toISOString(), kind: 'push', bytes: written }
      return { ok: true, exitCode: 0, stderr: '', bytes: written, remote: remotePath, agent: agent.name }
    } finally {
      this.#finish(agent)
    }
  }

  /** 把 Termux 里的一个文件读回来（有上限，超了标记 truncated）。 */
  async pull (remotePath, options) {
    const opts = options || {}
    if (!remotePath) throw fail('remotePath 为空', 'E_INVALID_ARGUMENT')
    const maxBytes = clampPayload(Math.min(DEFAULT_PULL_MAX, Number(opts.maxBytes) || DEFAULT_PULL_MAX), DEFAULT_PULL_MAX)
    const agent = await this.#acquire(opts.waitMs)
    const id = nextId('get')
    const frame = proto.encodeFrame('GET', [id, proto.encField(remotePath), maxBytes])
    this.totalJobs += 1
    try {
      const r = await this.#roundtrip(agent, id, frame, TRANSFER_TIMEOUT_MS, '读远端文件', true)
      this.lastJob = { at: new Date().toISOString(), kind: 'pull', exitCode: r.exitCode }
      return Object.assign(r, { remote: remotePath, agent: agent.name })
    } finally {
      this.#finish(agent)
    }
  }

  // ── 状态 ──────────────────────────────────────────────────────────────

  status () {
    const agentList = [...this.agents].filter((a) => a.registered).map((a) => ({
      id: a.id,
      name: a.name,
      peer: a.peer,
      busy: a.busy,
      jobs: a.jobs,
      connectedAt: new Date(a.connectedAt).toISOString()
    }))
    return {
      listening: this.listening,
      host: this.host,
      port: this.actualPort || this.port,
      requestedPort: this.port,
      agents: agentList.length,
      agentList,
      totalJobs: this.totalJobs,
      uptimeMs: this.startedAt ? Date.now() - this.startedAt : 0,
      tokenGenerated: this.tokenGenerated,
      lastError: this.lastError,
      lastJob: this.lastJob,
      maxAgents: this.maxAgents
    }
  }
}

module.exports = { Bridge, Agent, DEFAULT_PORT, DEFAULT_HOST, DEFAULT_TIMEOUT_MS, clampTimeout }
