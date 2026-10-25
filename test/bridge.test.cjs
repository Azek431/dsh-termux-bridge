'use strict'
/**
 * 端到端自测：不依赖真 Termux —— 宿主与 agent 都在同一个 Linux 里跑，
 * 但走的是完全相同的 TCP 帧协议和 /dev/tcp 客户端代码。
 * 只要这里绿了，「Termux 侧能不能跑」的唯一变量就只剩 Termux 本身有没有 bash。
 */
const { test } = require('node:test')
const assert = require('node:assert')
const http = require('node:http')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawn } = require('node:child_process')
const { Bridge } = require('../plugin/lib/bridge.js')

function fetchText (port, pathname) {
  return new Promise((resolve, reject) => {
    const req = http.get({ host: '127.0.0.1', port, path: pathname, timeout: 3000 }, (res) => {
      let body = ''
      res.setEncoding('utf8')
      res.on('data', (c) => { body += c })
      res.on('end', () => resolve({ status: res.statusCode, body }))
    })
    req.on('error', reject)
    req.on('timeout', () => req.destroy(new Error('timeout')))
  })
}

function waitFor (fn, ms, label) {
  const deadline = Date.now() + ms
  return new Promise((resolve, reject) => {
    const tick = async () => {
      try {
        if (await fn()) return resolve(true)
      } catch {}
      if (Date.now() > deadline) return reject(new Error('等待超时: ' + label))
      setTimeout(tick, 50)
    }
    tick()
  })
}

async function boot (t, overrides) {
  const { renderAgentScript } = require('../plugin/lib/index.js')
  const bridge = new Bridge(Object.assign({ port: 0 }, overrides))
  // port 0 会让 start() 从 0 开始试，不可控；改用一个高位的固定候选。
  bridge.port = 18000 + Math.floor(Math.random() * 2000)
  bridge.httpHandler = (req) => {
    const p = String(req.target || '/').split('?')[0]
    if (p !== '/agent') return null
    const name = (String(req.target).split('name=')[1] || 'test').split('&')[0]
    return { status: '200 OK', headers: { 'content-type': 'text/plain; charset=utf-8' }, body: renderAgentScript({ host: bridge.host, port: bridge.actualPort, token: bridge.token, name }) }
  }
  const ok = await bridge.start()
  assert.strictEqual(ok, true, '桥接应能起监听: ' + bridge.lastError)
  t.after(() => bridge.stop())

  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-bridge-test-'))
  const fetched = await fetchText(bridge.actualPort, '/agent?name=testagent')
  assert.strictEqual(fetched.status, 200)
  assert.match(fetched.body, /^#!\/usr\/bin\/env bash/)
  const scriptPath = path.join(dir, 'agent.sh')
  fs.writeFileSync(scriptPath, fetched.body, { mode: 0o755 })

  // MAX_FAIL=1：连不上就自杀。否则 DSH 侧一断，这个 bash 会永远重连下去，
  // 测试进程被 kill 之后它还活着，下次跑别的用例就能被它混进来。
  const child = spawn('bash', [scriptPath], {
    stdio: ['ignore', 'pipe', 'pipe'],
    env: Object.assign({}, process.env, { DSH_BRIDGE_MAX_FAIL: '1' })
  })
  t.after(() => { try { child.kill('SIGKILL') } catch {} })
  let stderrLog = ''
  child.stderr.setEncoding('utf8')
  child.stderr.on('data', (c) => { stderrLog += c })
  t.after(() => { try { fs.rmSync(dir, { recursive: true, force: true }) } catch {} })

  await waitFor(() => bridge.status().agents > 0, 8000, 'agent 握手 (stderr: ' + stderrLog + ')')
  return { bridge, dir, child }
}

test('握手后能执行脚本并拿到 stdout/exitCode', async (t) => {
  const { bridge } = await boot(t)
  const r = await bridge.exec({ script: 'echo hello; echo err >&2; exit 0' })
  assert.strictEqual(r.ok, true)
  assert.strictEqual(r.exitCode, 0)
  assert.match(r.stdout, /hello/)
  assert.match(r.stderr, /err/)
  assert.ok(r.elapsedMs >= 0)
})

test('非零退出码透传且不吞输出', async (t) => {
  const { bridge } = await boot(t)
  const r = await bridge.exec({ script: 'echo before; exit 42' })
  assert.strictEqual(r.ok, false)
  assert.strictEqual(r.exitCode, 42)
  assert.match(r.stdout, /before/)
})

test('多行脚本 / 管道 / heredoc 都能过', async (t) => {
  const { bridge } = await boot(t)
  const script = [
    'set -eu',
    'x=$(printf "a\\nb\\nc\\n" | grep -c b)',
    'cat <<EOF',
    'heredoc-line',
    'EOF',
    'echo "count=$x"'
  ].join('\n')
  const r = await bridge.exec({ script })
  assert.strictEqual(r.ok, true, r.stderr)
  assert.match(r.stdout, /heredoc-line/)
  assert.match(r.stdout, /count=1/)
})

test('cwd 生效', async (t) => {
  const { bridge, dir } = await boot(t)
  const r = await bridge.exec({ script: 'pwd', cwd: dir })
  assert.strictEqual(r.ok, true, r.stderr)
  assert.strictEqual(r.stdout.trim(), fs.realpathSync(dir))
})

test('cwd 不存在时明确失败而不是静默跑在别处', async (t) => {
  const { bridge } = await boot(t)
  const r = await bridge.exec({ script: 'pwd', cwd: '/definitely/not/here' })
  assert.strictEqual(r.ok, false)
  assert.strictEqual(r.exitCode, 97)
})

test('argv 里的空格与特殊字符不被二次展开', async (t) => {
  const { bridge, dir } = await boot(t)
  const target = path.join(dir, 'a b$(echo pwn).txt')
  const r = await bridge.execv(['bash', '-c', 'printf %s "$1" > "$2"', '_', 'ignored', target])
  assert.strictEqual(r.ok, true, r.stderr)
  assert.strictEqual(fs.readFileSync(target, 'utf8'), 'ignored')
})

test('输出超限截断并置 truncated', async (t) => {
  const { bridge } = await boot(t)
  const r = await bridge.exec({ script: 'head -c 5000 /dev/zero | tr "\\0" "x"', maxBytes: 1024 })
  assert.strictEqual(r.ok, true)
  assert.strictEqual(r.truncated, true)
  assert.strictEqual(r.stdout.length, 1024)
})

test('大输出（1MiB 上限）不会被帧上限撕掉连接', async (t) => {
  // 回归用例：base64 膨胀 4/3，若单帧上限 <= 载荷上限，1MiB 输出会让对端
  // destroy 连接，调用方只看到 E_AGENT_GONE，像是 agent 崩了。
  const { bridge } = await boot(t)
  const r = await bridge.exec({ script: 'seq 1 300000', maxBytes: 1048576, timeoutMs: 60000 })
  assert.strictEqual(r.ok, true, '不该失败: ' + r.stderr)
  assert.strictEqual(r.stdout.length, 1048576, '应拿到上限字节数')
  assert.strictEqual(r.truncated, true, '应标记截断')
})

test('pull 大文件不会被帧上限撕掉连接', async (t) => {
  const { bridge, dir } = await boot(t)
  const big = path.join(dir, 'big.txt')
  fs.writeFileSync(big, Buffer.alloc(3 * 1024 * 1024, 0x61))
  const r = await bridge.pull(big, { maxBytes: 1048576 })
  assert.strictEqual(r.ok, true, '不该失败: ' + r.stderr)
  assert.strictEqual(Buffer.byteLength(r.data, 'utf8'), 1048576)
  assert.strictEqual(r.truncated, true)
})

test('超时会杀掉命令并标记 timedOut（而不是伪装成命令自己返回 124）', async (t) => {
  const { bridge } = await boot(t)
  const started = Date.now()
  const r = await bridge.exec({ script: 'echo before-timeout; sleep 30; echo never', timeoutMs: 1000 })
  const took = Date.now() - started
  assert.strictEqual(r.ok, false, '超时不该被当成成功')
  assert.strictEqual(r.timedOut, true, '必须显式标记 timedOut')
  assert.strictEqual(r.exitCode, 124, 'timeout(1) 杀进程时为 124')
  assert.match(r.stdout, /before-timeout/, '被杀之前产生的输出要保住')
  assert.ok(!/never/.test(r.stdout), '超时后不该有后续输出')
  assert.ok(took < 10000, '应该在秒级返回，实际 ' + took + 'ms')
})

test('命令自己 exit 124 不算超时（timedOut=false）', async (t) => {
  const { bridge } = await boot(t)
  const r = await bridge.exec({ script: 'exit 124' })
  assert.strictEqual(r.exitCode, 124)
  assert.strictEqual(r.timedOut, false, '自己返回 124 不是我们杀的')
})

test('真的掉线时才报 E_AGENT_TIMEOUT', async (t) => {
  const { bridge, child } = await boot(t)
  const pending = bridge.exec({ script: 'sleep 5', timeoutMs: 3000 })
  await new Promise((r) => setTimeout(r, 300))
  // 直接砍掉 agent 进程：不是「命令慢」，是「对端没了」。
  child.kill('SIGKILL')
  await assert.rejects(() => pending, (err) => ['E_AGENT_GONE', 'E_AGENT_TIMEOUT'].includes(err.code))
})

test('多片 push 与 pull 往返一致', async (t) => {
  const { bridge, dir } = await boot(t)
  const remote = path.join(dir, 'payload.bin')
  const payload = Buffer.alloc(200 * 1024)
  for (let i = 0; i < payload.length; i += 1) payload[i] = 65 + (i % 26)
  const pushed = await bridge.push(payload, remote)
  assert.strictEqual(pushed.ok, true, pushed.stderr)
  assert.strictEqual(pushed.bytes, payload.length)
  assert.deepStrictEqual(fs.readFileSync(remote), payload)
  const pulled = await bridge.pull(remote, { maxBytes: 300 * 1024 })
  assert.strictEqual(pulled.ok, true, pulled.stderr)
  assert.strictEqual(Buffer.byteLength(pulled.data, 'utf8'), payload.length)
  assert.strictEqual(pulled.data, payload.toString('utf8'))
})

test('push 会创建不存在的远端目录', async (t) => {
  const { bridge, dir } = await boot(t)
  const remote = path.join(dir, 'deep/nested/dir/file.txt')
  const r = await bridge.push('hi', remote)
  assert.strictEqual(r.ok, true, r.stderr)
  assert.strictEqual(fs.readFileSync(remote, 'utf8'), 'hi')
})

test('pull 不到文件时报 E_REMOTE_READ 语义（exitCode 3）', async (t) => {
  const { bridge } = await boot(t)
  const r = await bridge.pull('/definitely/not/here.txt')
  assert.strictEqual(r.ok, false)
  assert.strictEqual(r.exitCode, 3)
})

test('没有 agent 时 exec 报 E_NO_AGENT', async (t) => {
  const bridge = new Bridge({ port: 18000 + Math.floor(Math.random() * 2000) })
  t.after(() => bridge.stop())
  assert.strictEqual(await bridge.start(), true)
  await assert.rejects(() => bridge.exec({ script: 'echo x' }), (err) => err.code === 'E_NO_AGENT')
})

test('令牌不对时被拒且不进入 agents 列表', async (t) => {
  const { renderAgentScript } = require('../plugin/lib/index.js')
  const bridge = new Bridge({ port: 18000 + Math.floor(Math.random() * 2000) })
  bridge.port = 20000 + Math.floor(Math.random() * 1000)
  bridge.httpHandler = () => null
  t.after(() => bridge.stop())
  assert.strictEqual(await bridge.start(), true)
  const script = renderAgentScript({ host: '127.0.0.1', port: bridge.actualPort, token: 'wrong-token', name: 'bad' })
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-bridge-bad-'))
  const file = path.join(dir, 'agent.sh')
  fs.writeFileSync(file, script, { mode: 0o755 })
  const child = spawn('bash', [file], { stdio: 'ignore' })
  t.after(() => { try { child.kill('SIGKILL') } catch {} })
  await new Promise((r) => setTimeout(r, 1200))
  assert.strictEqual(bridge.status().agents, 0)
  try { fs.rmSync(dir, { recursive: true, force: true }) } catch {}
})

// 回归 #1（1.2.1）：E_BAD_TOKEN / E_PROTO_MISMATCH 是不可自愈的拒绝，
// agent 必须自己退出。1.2.0 之前它对所有 DENY 一律 break 后立刻重连，变成
// 一个 30 秒一次的无限循环，进程永远留在后台 —— 测试里因此残留过 4 个孤儿 agent。
test('令牌错时 agent 自己退出，不做无限重连', async (t) => {
  const { renderAgentScript } = require('../plugin/lib/index.js')
  const bridge = new Bridge({ port: 20000 + Math.floor(Math.random() * 1000) })
  bridge.httpHandler = () => null
  t.after(() => bridge.stop())
  assert.strictEqual(await bridge.start(), true)
  const script = renderAgentScript({ host: '127.0.0.1', port: bridge.actualPort, token: 'right-token', name: 'bad' })
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-bridge-deny-'))
  const file = path.join(dir, 'agent.sh')
  fs.writeFileSync(file, script, { mode: 0o755 })
  // 令牌是错的 → 服务端 DENY E_BAD_TOKEN → agent 必须 FATAL 退出。
  const child = spawn('bash', [file, '--quiet'], {
    stdio: ['ignore', 'ignore', 'pipe'],
    env: Object.assign({}, process.env, { DSH_BRIDGE_TOKEN: 'definitely-wrong' })
  })
  t.after(() => { try { child.kill('SIGKILL') } catch {} })
  const exited = await new Promise((resolve) => {
    const timer = setTimeout(() => resolve(null), 8000)
    child.on('exit', (code, signal) => { clearTimeout(timer); resolve({ code, signal }) })
  })
  assert.ok(exited, 'agent 收到 E_BAD_TOKEN 后应自己退出，而不是永恒重连')
  assert.strictEqual(bridge.status().agents, 0)
  try { fs.rmSync(dir, { recursive: true, force: true }) } catch {}
})

// 回归 #2（1.2.1）：同一个 Termux 起两份 agent（或上次运行的残留连接还在重连）
// 不能白占 maxAgents。同名新连接应顶掉旧连接，只留一条。
test('同名 agent 只保留一条连接', async (t) => {
  const { bridge, dir } = await boot(t)
  assert.strictEqual(bridge.status().agents, 1)
  const firstId = bridge.status().agentList[0].id
  const { renderAgentScript } = require('../plugin/lib/index.js')
  const script = renderAgentScript({ host: '127.0.0.1', port: bridge.actualPort, token: bridge.token, name: 'testagent' })
  const second = path.join(dir, 'agent2.sh')
  fs.writeFileSync(second, script, { mode: 0o755 })
  const child = spawn('bash', [second, '--quiet'], {
    stdio: ['ignore', 'ignore', 'ignore'],
    env: Object.assign({}, process.env, { DSH_BRIDGE_MAX_FAIL: '1' })
  })
  t.after(() => { try { child.kill('SIGKILL') } catch {} })
  // 判据必须是「id 换了」而不是「个数是 1」：从 2 变回 1 也可能只是旧连接自己断了。
  await waitFor(() => {
    const st = bridge.status()
    return st.agents === 1 && st.agentList[0] && st.agentList[0].id !== firstId
  }, 8000, '同名新连接顶替旧连接')
  // 再盯 3 秒，确认没有乒乓：老 agent 收到 BYE 就该退出，不会连回来再把这条顶掉。
  const seen = new Set()
  for (let i = 0; i < 12; i += 1) {
    await new Promise((r) => setTimeout(r, 250))
    const st = bridge.status()
    assert.strictEqual(st.agents, 1, '同名 agent 应始终只有一条，实际 ' + st.agents)
    seen.add(st.agentList[0].id)
  }
  assert.strictEqual(seen.size, 1, '3 秒内连接不该被反复顶替（乒乓），出现过的 id: ' + [...seen].join(','))
  // 去重之后仍然能正常干活
  const r = await bridge.exec({ script: 'echo still-alive' })
  assert.strictEqual(r.ok, true, r.stderr)
  assert.match(r.stdout, /still-alive/)
})

test('HTTP 面只回 /agent，其它路径 404', async (t) => {
  const { bridge } = await boot(t)
  const a = await fetchText(bridge.actualPort, '/agent?name=x')
  assert.strictEqual(a.status, 200)
  const b = await fetchText(bridge.actualPort, '/whatever')
  assert.strictEqual(b.status, 404)
})
