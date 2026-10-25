'use strict'
// 冒烟：用假 ctx 真实加载 profile 里已发布的插件包，验证 apply → 注册 6 个工具 → HTTP /agent 可下载
// → 两个执行面都真的能跑（termux agent 侧 / 客人本地侧）。
const path = require('node:path')
const http = require('node:http')
const { spawn } = require('node:child_process')
const fs = require('node:fs')

const PKG = process.env.SMOKE_PKG || '/root/projects/.dsh/profiles/web/node_modules/@local/dsh-termux-bridge'
const mod = require(PKG)

// 端口与令牌都必须随机：固定端口 + 固定令牌会让上一次跑崩后残留的 agent（它带着
// 同一个令牌、一直在重连同一个端口）悄悄接进这一次，把「没有 agent」的断言打假。
const PORT = 20000 + Math.floor(Math.random() * 20000)
const TOKEN = require('node:crypto').randomBytes(8).toString('hex')
console.log('port =', PORT, '| token =', TOKEN.slice(0, 4) + '…')
console.log('name =', mod.name, '| inject =', JSON.stringify(mod.inject), '| Config =', typeof mod.Config)

const registered = []
const disposers = []
const ctx = {
  tools: { register (t) { registered.push(t) } },
  effect (fn) { disposers.push(fn()) },
  logger: { info: (m) => console.log('[logger]', m) },
  on () {}
}

let child = null
const cleanup = () => {
  if (child) { try { process.kill(-child.pid, 'SIGTERM') } catch { try { child.kill('SIGKILL') } catch {} } }
  for (const d of disposers) { try { if (typeof d === 'function') d() } catch {} }
}

;(async () => {
  await mod.apply(ctx, { port: PORT, token: TOKEN, timeoutMs: 20000 })
  console.log('registered =', registered.length, registered.map(t => t.name).join(', '))
  if (registered.length !== 6) throw new Error('expected 6 tools, got ' + registered.length)
  const byName = Object.fromEntries(registered.map(t => [t.name, t]))
  const run = (name, args) => byName[name].execute(args || {}, {})

  // ── 1. 没有 agent：auto 必须落到本地执行面 ──
  const st0 = await run('termux_status')
  console.log('[no-agent] agents =', st0.agents, '| activeBackend =', st0.activeBackend, '| localReady =', st0.localReady)
  if (st0.agents !== 0) throw new Error('起手不该有 agent')
  if (st0.activeBackend !== 'local') throw new Error('没有 agent 时 auto 应落到 local，实际 ' + st0.activeBackend)
  if (!st0.localReady) throw new Error('本地执行面不可用')

  const l1 = await run('termux_exec', { script: 'echo local-hello; uname -m; exit 5' })
  console.log('[local] backend =', l1.backend, '| exitCode =', l1.exitCode, '| code =', l1.code)
  console.log('  stdout =', JSON.stringify(l1.stdout))
  if (l1.backend !== 'local') throw new Error('应走 local，实际 ' + l1.backend)
  if (l1.exitCode !== 5 || l1.ok) throw new Error('本地退出码透传坏了')

  const l2 = await run('termux_run', { argv: ['bash', '-c', 'echo "$((6*7))"'] })
  console.log('[local] run stdout =', JSON.stringify(l2.stdout), '| backend =', l2.backend)
  if (l2.stdout.trim() !== '42') throw new Error('本地 argv 执行坏了')

  const l3 = await run('termux_exec', { script: 'echo a; sleep 30', timeoutMs: 1200 })
  console.log('[local] timeout timedOut =', l3.timedOut, '| code =', l3.code, '| ms =', l3.elapsedMs)
  if (!l3.timedOut || l3.code !== 'E_TIMEOUT') throw new Error('本地超时语义坏了')

  const l4 = await run('termux_exec', { script: 'echo x', cwd: '/nope/nope' })
  console.log('[local] bad cwd exitCode =', l4.exitCode)
  if (l4.exitCode !== 97) throw new Error('本地 cwd 缺失应返回 97')

  const l5 = await run('termux_push', { remotePath: '/tmp/smoke-local.txt', content: '本地写入\n第二行\n' })
  const l6 = await run('termux_pull', { remotePath: '/tmp/smoke-local.txt' })
  console.log('[local] push bytes =', l5.bytes, '| pull =', JSON.stringify(l6.content), '| backend =', l6.backend)
  if (!l6.content.includes('第二行')) throw new Error('本地 push/pull 往返坏了')

  // 显式 termux 但没 agent：必须报错，不降级
  const l7 = await run('termux_exec', { script: 'echo nope', backend: 'termux' })
  console.log('[forced-termux] ok =', l7.ok, '| code =', l7.code, '| backend =', l7.backend)
  if (l7.ok || l7.code !== 'E_NO_AGENT') throw new Error('强制 termux 无 agent 时应报 E_NO_AGENT')

  const l8 = await run('termux_exec', { script: 'echo x', backend: 'bogus' })
  console.log('[bad-backend] code =', l8.code)
  if (l8.code !== 'E_INVALID_ARGUMENT') throw new Error('非法 backend 应报 E_INVALID_ARGUMENT')

  // ── 2. HTTP 面：/agent 能拿到渲染后的脚本 ──
  const fetchText = (p) => new Promise((resolve, reject) => {
    http.get({ host: '127.0.0.1', port: PORT, path: p }, (res) => {
      let b = ''; res.setEncoding('utf8')
      res.on('data', (c) => { b += c })
      res.on('end', () => resolve({ status: res.statusCode, body: b }))
    }).on('error', reject)
  })
  const agent = await fetchText('/agent?name=smoke')
  console.log('/agent status =', agent.status, 'bytes =', agent.body.length)
  if (agent.status !== 200) throw new Error('bad /agent status')
  if (agent.body.includes('__DSH_PORT__')) throw new Error('占位符未替换')
  if (!agent.body.includes(TOKEN)) throw new Error('令牌未注入')
  const nf = await fetchText('/nope')
  console.log('/nope status =', nf.status)
  if (nf.status !== 404) throw new Error('404 面坏了')

  // ── 3. 起 agent（模拟 Termux 侧）：auto 必须切到 termux ──
  const scriptPath = '/tmp/smoke-agent.sh'
  fs.writeFileSync(scriptPath, agent.body, { mode: 0o755 })
  // DSH_BRIDGE_MAX_FAIL=1：连不上就退出，别变成永远重连的孤儿进程。
  child = spawn('bash', [scriptPath, '--quiet'], {
    stdio: ['ignore', 'ignore', 'pipe'],
    detached: true,
    env: Object.assign({}, process.env, { DSH_BRIDGE_MAX_FAIL: '1', DSH_BRIDGE_TOKEN: TOKEN, DSH_BRIDGE_PORT: String(PORT) })
  })
  child.stderr.on('data', (d) => process.stderr.write('[agent] ' + d))
  await new Promise((r) => setTimeout(r, 1500))

  const st1 = await run('termux_status')
  console.log('[agent] agents =', st1.agents, '| activeBackend =', st1.activeBackend)
  if (st1.agents < 1) throw new Error('agent 没连上')
  if (st1.activeBackend !== 'termux') throw new Error('有 agent 时 auto 应切到 termux')

  const t1 = await run('termux_exec', { script: 'echo hello-from-termux; echo err-line >&2; exit 7' })
  console.log('[termux] backend =', t1.backend, '| exitCode =', t1.exitCode, '| code =', t1.code)
  console.log('  stdout =', JSON.stringify(t1.stdout), '| stderr =', JSON.stringify(t1.stderr))
  if (t1.backend !== 'termux') throw new Error('应走 termux，实际 ' + t1.backend)
  if (t1.exitCode !== 7 || t1.ok) throw new Error('termux 退出码透传坏了')

  const t2 = await run('termux_run', { argv: ['bash', '-c', 'echo "$((1+2))"; pwd'] })
  console.log('[termux] run stdout =', JSON.stringify(t2.stdout))

  const t3 = await run('termux_push', { remotePath: '/tmp/smoke-note.txt', content: '桥接写入\n第二行\n' })
  const t4 = await run('termux_pull', { remotePath: '/tmp/smoke-note.txt' })
  console.log('[termux] push bytes =', t3.bytes, '| pull =', JSON.stringify(t4.content), '| backend =', t4.backend)
  if (!t4.content.includes('第二行')) throw new Error('termux push/pull 往返坏了')

  // 有 agent 时显式 local 仍要能强制走本地
  const t5 = await run('termux_exec', { script: 'echo forced-local', backend: 'local' })
  console.log('[forced-local] backend =', t5.backend, '| stdout =', JSON.stringify(t5.stdout))
  if (t5.backend !== 'local') throw new Error('显式 local 没生效')

  const b = await run('termux_bootstrap', { name: 'x' })
  console.log('bootstrap.command =', b.command.slice(0, 80))
  console.log('bootstrap.script bytes =', b.script.length)

  cleanup()
  try { fs.unlinkSync(scriptPath) } catch {}
  try { fs.unlinkSync('/tmp/smoke-local.txt') } catch {}
  console.log('SMOKE OK')
  process.exit(0)
})().catch((err) => {
  console.error('SMOKE FAIL:', err && err.message)
  console.error(err && err.stack)
  cleanup()
  process.exit(1)
})
