'use strict'
/**
 * @local/termux-bridge —— 把 Termux（Android 侧终端）接成 DSH 的一条执行通道。
 *
 * 存在理由：DSH 跑在 App 的 PRoot 客人里，客人内没有 am / su，拉不起 Termux
 * 进程；两边也没有共享文件系统。唯一共享的东西是网络命名空间（同一个 loopback）。
 * 所以本插件在客人里监听 127.0.0.1:<port>，由用户在 Termux 里起一次 agent
 * 主动连回来，之后模型就能在 Termux 里跑 pkg / 访问 ~/storage / 用 Termux 的
 * 完整工具链。
 *
 * 两个执行面（backend=auto 时自动选）：
 *   termux —— 有 agent 连接，命令在 Termux 里跑，能 pkg install、能看 ~/storage；
 *   local  —— 没有 agent，命令在 DSH 客人自己的 Debian 里跑（bash/gcc/node/python3/ffmpeg
 *             都现成，apt 走 dshbox 的 fakeroot wrapper）。
 * 有 local 兜底，用户不把 Termux 挂后台也能干活；explicit 写 termux 时不降级，直接报错。
 *
 * 设计取舍：
 * - 独立监听，不去改 webserver（webserver 是 required row，坏掉会让整个 Host 起不来）。
 * - 端口被占只降级并记 lastError，绝不抛异常：插件加载失败会让用户完全看不到原因。
 * - agent 侧零依赖（纯 bash + base64），因为它要在一个我们无法预先装包的环境里跑。
 */

const path = require('node:path')
const os = require('node:os')
const fs = require('node:fs')
const { pathToFileURL } = require('node:url')
const { Bridge } = require('./bridge.js')
const proto = require('./protocol.js')
const local = require('./local.js')

const TOOLS_MODULE = '@deepseek-ai/dsh-tools'
const SCHEMA_MODULE = '@deepseek-ai/schemastery'
const DSH_TOOLS_MISSING = '未找到 dsh-tools，termux 工具未注册'

const DEFAULT_PORT = 8791
const DEFAULT_TIMEOUT_MS = 30000

/**
 * 解析基准目录：本包在 profile 树（<profile>/node_modules/@local/...），
 * dsh-tools 在 runtime 树（/opt/dshapp/runtime/node_modules），两棵树互不包含。
 * 所以不能只靠"从本文件往上找"，要把所有可能的落点都列出来：
 *   1) 本文件所在目录 —— 正常装进 profile 后，这条由 module.paths 覆盖；
 *   2) require.main 所在目录 —— dsh 自己加载插件时是 dsh/lib/bin.js，这条命中；
 *   3) process.execPath 所在目录 —— node 的安装位置，有时就是 runtime；
 *   4) node 自带的 module.paths（含 NODE_PATH）；
 *   5) 已知的 DSHBox runtime 位置（Android 上的 bind 落点）。
 * 每条都要正着走（require.resolve + require）与反着走（import 绝对路径）各试一次。
 */
const RUNTIME_HINTS = [
  '/opt/dshapp/runtime/node_modules',
  '/usr/local/lib/node_modules',
  '/opt/dshbox/runtime/node_modules'
]

function resolveBases () {
  const bases = new Set()
  const push = (value) => { if (typeof value === 'string' && value) bases.add(value) }
  push(__dirname)
  push(process.cwd())
  try { if (require.main && require.main.filename) push(path.dirname(require.main.filename)) } catch {}
  try { push(path.dirname(process.execPath)) } catch {}
  try { for (const p of module.paths || []) push(p) } catch {}
  try {
    if (process.env && process.env.NODE_PATH) {
      for (const p of process.env.NODE_PATH.split(path.delimiter)) push(p)
    }
  } catch {}
  for (const hint of RUNTIME_HINTS) push(hint)
  return [...bases]
}

function acquireDefineTool () {
  const bases = resolveBases()
  const attempts = []
  const resolvedPaths = []
  for (const base of bases) {
    let resolvedPath
    try {
      resolvedPath = require.resolve(TOOLS_MODULE, { paths: [base] })
    } catch (err) {
      attempts.push({ base, stage: 'resolve', code: (err && err.code) || '', message: (err && err.message) || String(err) })
      continue
    }
    resolvedPaths.push(resolvedPath)
    try {
      const mod = require(resolvedPath)
      if (mod && typeof mod.defineTool === 'function') {
        return { defineTool: mod.defineTool, stage: 'require', resolvedPath, resolvedPaths, attempts }
      }
      attempts.push({ base, stage: 'shape', code: 'E_NO_DEFINETOOL', message: '模块没有导出 defineTool' })
    } catch (err) {
      attempts.push({ base, stage: 'require', code: (err && err.code) || '', message: (err && err.message) || String(err) })
    }
  }
  return { defineTool: null, stage: 'none', resolvedPath: '', resolvedPaths, attempts }
}

async function importDefineTool (resolvedPaths) {
  for (const p of [...new Set(resolvedPaths)]) {
    try {
      const mod = await import(pathToFileURL(p).href)
      if (mod && typeof mod.defineTool === 'function') return mod.defineTool
      if (mod && mod.default && typeof mod.default.defineTool === 'function') return mod.default.defineTool
    } catch {}
  }
  try {
    const mod = await import(TOOLS_MODULE)
    if (mod && typeof mod.defineTool === 'function') return mod.defineTool
    if (mod && mod.default && typeof mod.default.defineTool === 'function') return mod.default.defineTool
  } catch {}
  return null
}

/**
 * 配置 Schema。拿不到 schemastery 就不导出 Config（配置仍可由 cordis.patch.yml 传入）。
 * 注意导出形状：schemastery 的模块**本身就是**那个 Schema 构造函数（typeof module === 'function'），
 * 上面再挂 object/string/number 等构造器；它不是 { Schema } 命名空间。
 * 只认 mod.Schema 会在这里静默拿不到，表现为"配置项全被忽略、还看不出原因"。
 */
function acquireSchema () {
  for (const base of resolveBases()) {
    try {
      const p = require.resolve(SCHEMA_MODULE, { paths: [base] })
      const mod = require(p)
      const cand = (typeof mod === 'function' && mod) ||
        (mod && typeof mod.Schema === 'function' && mod.Schema) ||
        (mod && mod.default && typeof mod.default === 'function' && mod.default) ||
        null
      if (cand && typeof cand.object === 'function') return cand
    } catch {}
  }
  return null
}

const Schema = acquireSchema()
let Config
if (Schema) {
  Config = Schema.object({
    port: Schema.number().default(DEFAULT_PORT).description('监听端口。被占用时自动顺延最多 9 个。'),
    host: Schema.string().default('127.0.0.1').description('监听地址。只建议 loopback。'),
    token: Schema.string().default('').description('共享令牌；留空则每次启动随机生成（更安全，但需要重新拉取启动脚本）。'),
    maxAgents: Schema.number().default(8).description('同时允许连接的 agent 数上限。'),
    timeoutMs: Schema.number().default(DEFAULT_TIMEOUT_MS).description('termux_exec 的默认超时（毫秒）。')
  }).description('Termux 桥接：loopback 监听 + Termux 侧 agent 主动连接。')
}

// ── 执行面选择 ──────────────────────────────────────────────────────────

const BACKENDS = ['auto', 'termux', 'local']

function fail (message, code) {
  const err = new Error(message)
  err.code = code || 'E_INTERNAL'
  return err
}

/**
 * 决定这条命令由谁执行。
 *
 * auto 是默认值，也是本插件最重要的一个设计点：有 Termux agent 就用 Termux 的环境，
 * 没有就在 DSH 客人自己的 Debian 里跑。这样「不连 Termux 也能干活」与
 * 「连上之后自动用 Termux 的工具链」同时成立，用户不需要改任何配置。
 *
 * 显式写 termux 则强制要求 agent：没连上就报错，不偷偷降级 —— 那时候用户要的是
 * Termux 的 uid / ~/storage / pkg，换成客人本地跑会得出错误结论。
 */
function pickBackend (bridge, requested) {
  const want = String(requested || 'auto').toLowerCase()
  if (BACKENDS.indexOf(want) < 0) throw fail('backend 只能是 auto / termux / local，收到: ' + requested, 'E_INVALID_ARGUMENT')
  if (want === 'local') return 'local'
  if (want === 'termux') return 'termux'
  return bridge.status().agents > 0 ? 'termux' : 'local'
}

const BACKEND_SCHEMA = {
  type: 'string',
  description: '执行面：auto（默认；有 Termux agent 就走 Termux，否则走 DSH 客人本地 Debian）| termux（强制，没 agent 就报错）| local（强制走客人本地）。'
}

const BACKEND_FIELD = { type: 'string', required: true, description: '实际执行面：termux 或 local。' }

function quoteArgv (argv) {
  return argv.map((s) => "'" + String(s).replace(/'/g, "'\\''") + "'").join(' ')
}

// ── 工具构造 ────────────────────────────────────────────────────────────


function resultSchema (extra) {
  return {
    type: 'object',
    additionalProperties: false,
    properties: Object.assign({
      ok: { type: 'boolean', required: true, description: '是否成功。机器判读读字段，不要解析 text。' },
      code: { type: 'string', required: true, description: '错误码；成功时为空串。' },
      text: { type: 'string', required: true, description: '人类可读摘要。' },
      exitCode: { type: 'integer', required: true, description: '远端命令退出码；未执行时为 0。' },
      elapsedMs: { type: 'integer', required: true, description: '远端执行耗时（毫秒）。' },
      truncated: { type: 'boolean', required: true, description: '输出是否被截断。' },
      timedOut: { type: 'boolean', required: true, description: '是否因超过 timeoutMs 被强杀；true 时 code=E_TIMEOUT。' }
    }, extra || {})
  }
}

const renderText = (_args, value) => [{ type: 'text', text: value.text }]

function baseFields (ok, code, text) {
  return { ok, code: code || '', text, exitCode: ok ? 0 : 1, elapsedMs: 0, truncated: false, timedOut: false }
}

function needAgentText (status) {
  return [
    '没有 Termux agent 连接，命令没有执行（backend=termux 是强制指定，所以没有回退到本地执行面）。',
    '两条路：',
    '  1) 不连 Termux：backend 留空或写 auto / local，命令直接在 DSH 客人自己的 Debian 里跑。',
    '  2) 要用 Termux 的环境：调 termux_bootstrap 拿启动脚本，在 Termux 里执行它（可 nohup 常驻）。',
    '当前监听: ' + (status.listening ? status.host + ':' + status.port : '未启动（' + (status.lastError || '未知原因') + '）')
  ].join('\n')
}

function buildTools ({ defineTool, bridge, config }) {
  const tools = []
  const push = (spec) => tools.push(defineTool(spec))
  const defaultTimeout = () => (Number(config && config.timeoutMs) || DEFAULT_TIMEOUT_MS)

  push({
    name: 'termux_status',
    description:
      '查看桥接状态：是否在监听、端口、已连接的 agent、累计任务数、最近一次任务，以及命令当前会在哪个执行面跑。' +
      '排障第一步永远是这个工具 —— 它能区分「插件没起来」「没有 agent 连进来」「其实在客人本地跑」。',
    parameters: {},
    output: {
      schema: resultSchema({
        listening: { type: 'boolean', required: true, description: '监听是否就绪。' },
        host: { type: 'string', required: true, description: '监听地址。' },
        port: { type: 'integer', required: true, description: '实际监听端口（可能与配置的请求端口不同）。' },
        agents: { type: 'integer', required: true, description: '已握手成功的 agent 数。' },
        agentNames: { type: 'string', required: true, description: 'agent 名称列表，逗号分隔。' },
        totalJobs: { type: 'integer', required: true, description: '累计派发的任务数。' },
        lastError: { type: 'string', required: true, description: '最近一次监听错误；空串表示没有错误。' },
        bootstrapUrl: { type: 'string', required: true, description: 'Termux 侧可用的启动脚本下载地址；未监听时为空串。' },
        activeBackend: { type: 'string', required: true, description: 'backend=auto 时下一个命令会走的执行面：termux 或 local。' },
        localReady: { type: 'boolean', required: true, description: '客人本地执行面是否可用（能否 spawn bash）。' },
        localTools: { type: 'string', required: true, description: '客人内探测到的工具链，形如 bash=/bin/bash,node=/usr/local/bin/node。' },
        localCwd: { type: 'string', required: true, description: '客人本地执行面的默认工作目录。' }
      }),
      render: renderText
    },
    execute: async () => {
      const s = bridge.status()
      const found = local.probeTools()
      const localReady = !!found.bash
      const activeBackend = s.agents > 0 ? 'termux' : 'local'
      const lines = [
        'Termux 桥接状态',
        '监听: ' + (s.listening ? s.host + ':' + s.port + '（请求端口 ' + s.requestedPort + '）' : '未启动'),
        'agent: ' + s.agents + ' / ' + s.maxAgents + (s.agentList.length ? '（' + s.agentList.map((a) => a.name + (a.busy ? '*' : '')).join(', ') + '）' : ''),
        '累计任务: ' + s.totalJobs,
        '运行时长: ' + Math.round(s.uptimeMs / 1000) + 's',
        '下一个命令走: ' + (activeBackend === 'termux' ? 'Termux（有 agent 连接）' : '客人本地 Debian（没有 agent，不需要连 Termux）'),
        '客人本地执行面: ' + (localReady ? '可用' : '不可用（找不到 bash）') + '，默认 cwd ' + os.homedir(),
        '客人工具链: ' + (Object.keys(found).length ? Object.keys(found).map((k) => k + '=' + found[k]).join(', ') : '未探测到')
      ]
      if (s.lastError) lines.push('最近错误: ' + s.lastError)
      if (!s.agents) lines.push('提示: 想改用 Termux 的环境（pkg / ~/storage）时，在 Termux 里运行 termux_bootstrap 给出的脚本；不运行也能用，命令会在客人里跑。')
      const url = s.listening && config && config.host !== undefined ? 'http://' + bridge.host + ':' + bridge.actualPort + '/' : ''
      return Object.assign(baseFields(true, '', lines.join('\n')), {
        listening: s.listening,
        host: s.host,
        port: s.port,
        agents: s.agents,
        agentNames: s.agentList.map((a) => a.name + (a.busy ? '*' : '')).join(','),
        totalJobs: s.totalJobs,
        lastError: s.lastError,
        bootstrapUrl: url,
        activeBackend,
        localReady,
        localTools: Object.keys(found).map((k) => k + '=' + found[k]).join(','),
        localCwd: os.homedir()
      })
    }
  })

  push({
    name: 'termux_bootstrap',
    description:
      '生成 Termux 侧的启动命令与脚本。客人和 Termux 没有共享文件系统，所以脚本是通过本插件的 loopback HTTP 面交付的：' +
      '在 Termux 里执行返回的 curl 命令即可（或把 script 字段的内容存成文件再 bash 它）。' +
      '令牌每次启动可能变化，换过令牌后必须重新取一次脚本。' +
      '不跑它也能执行命令（走客人本地执行面）；跑它是为了用上 Termux 的 uid / ~/storage / pkg。',
    parameters: {
      name: { type: 'string', description: 'agent 显示名，便于区分多台/多个会话；留空用 hostname。' },
      inline: { type: 'boolean', description: '是否在返回值里包含完整脚本正文（script 字段）。默认 true。' }
    },
    output: {
      schema: resultSchema({
        command: { type: 'string', required: true, description: '可直接粘贴到 Termux 执行的一行命令。' },
        url: { type: 'string', required: true, description: '脚本下载地址（loopback）。' },
        script: { type: 'string', required: true, description: '脚本正文；inline 为 false 时为空串。' },
        tokenGenerated: { type: 'boolean', required: true, description: '令牌是否为本次运行随机生成。' }
      }),
      render: renderText
    },
    execute: async (args) => {
      const s = bridge.status()
      if (!s.listening) {
        return Object.assign(baseFields(false, 'E_BRIDGE_DOWN', '桥接没有在监听，无法生成可用的启动脚本。\n原因: ' + (s.lastError || '未知')), {
          command: '', url: '', script: '', tokenGenerated: s.tokenGenerated
        })
      }
      const agentName = String(args.name || '').trim() || os.hostname()
      const url = 'http://' + bridge.host + ':' + bridge.actualPort + '/agent?name=' + encodeURIComponent(agentName)
      const command = 'curl -fsSL ' + url + ' | bash'
      let script = ''
      if (args.inline !== false) script = renderAgentScript({ host: bridge.host, port: bridge.actualPort, token: bridge.token, name: agentName })
      const lines = [
        '在 Termux 里执行（复制整行）:',
        '  ' + command,
        '',
        '或者先存成文件再跑（可后台）:',
        '  curl -fsSL ' + url + ' -o ~/dsh-agent.sh && nohup bash ~/dsh-agent.sh >/dev/null 2>&1 &',
        '',
        '注意: 端口是 loopback，Termux 与 DSH 共享同一网络命名空间，不需要 root、不需要开热点。',
        '',
        '不跑这个脚本也不影响执行命令：没有 agent 时 termux_exec / termux_run 会自动在 DSH 客人自己的 Debian 里跑（有 bash/gcc/node/python3/ffmpeg）。',
        '只有要用 Termux 的 uid、~/storage 或 pkg 时，才需要跑这个脚本把 Termux 接进来。'
      ]
      return Object.assign(baseFields(true, '', lines.join('\n')), {
        command, url, script, tokenGenerated: s.tokenGenerated
      })
    }
  })

  push({
    name: 'termux_exec',
    description:
      '执行一段 bash 脚本（本插件主入口）。默认 backend=auto：连了 Termux agent 就在 Termux 里跑，没连就在 DSH 客人自己的 Debian 里跑 —— ' +
      '所以不需要先把 Termux 挂后台也能直接干活。脚本以文件形式交给 bash 执行，不经过多层引号转义，可写多行、if、管道、heredoc。' +
      '输出超过 maxBytes 截断并置 truncated=true；非 0 退出时 ok=false 但 stdout/stderr 仍有效；超时被强杀时 timedOut=true、code=E_TIMEOUT。',
    parameters: {
      script: { type: 'string', required: true, description: '要执行的 bash 脚本正文（多行可用 \n）。' },
      cwd: { type: 'string', description: '工作目录；留空则用执行面的默认目录（Termux 侧是 ~，本地是客人的 ~）。' },
      backend: BACKEND_SCHEMA,
      timeoutMs: { type: 'integer', description: '超时（毫秒），1000..600000；留空用插件默认值。' },
      maxBytes: { type: 'integer', description: 'stdout 最多回传多少字节，1024..1048576。默认 65536。' }
    },
    output: {
      schema: resultSchema({
        stdout: { type: 'string', required: true, description: '标准输出（可能被截断）。' },
        stderr: { type: 'string', required: true, description: '标准错误（最多 64KiB）。' },
        agent: { type: 'string', required: true, description: '执行这台命令的执行面名称；local:guest 表示 DSH 客人本地。' },
        backend: BACKEND_FIELD
      }),
      render: renderText
    },
    execute: async (args) => {
      try {
        const backend = pickBackend(bridge, args.backend)
        const timeoutMs = Number(args.timeoutMs) || defaultTimeout()
        const maxBytes = Number(args.maxBytes) || 65536
        const r = backend === 'local'
          ? await local.runScript({ script: args.script, cwd: args.cwd || '', timeoutMs, maxBytes })
          : await bridge.exec({ script: args.script, cwd: args.cwd || '', timeoutMs, maxBytes })
        return Object.assign(baseFields(r.ok, r.ok ? '' : (r.timedOut ? 'E_TIMEOUT' : 'EXIT_' + r.exitCode), formatExec(r, args.script)), {
          exitCode: r.exitCode,
          elapsedMs: r.totalMs,
          truncated: !!r.truncated,
          timedOut: !!r.timedOut,
          stdout: r.stdout,
          stderr: r.stderr,
          agent: r.agent,
          backend
        })
      } catch (err) {
        return Object.assign(baseFields(false, (err && err.code) || 'E_INTERNAL', errorText(err, bridge)), {
          stdout: '', stderr: '', agent: '', backend: ''
        })
      }
    }
  })

  push({
    name: 'termux_run',
    description:
      '按 argv 执行一条命令，不经过 shell 解析：每个参数单独用单引号包好再交给 bash，' +
      '所以路径里的空格、引号、$ 都不会被二次展开。适合「跑一条明确的命令」；需要管道/重定向/多行时用 termux_exec。' +
      'backend 语义与 termux_exec 相同（auto 时没 Termux agent 就走客人本地）。',
    parameters: {
      argv: { type: 'array', required: true, description: '命令与参数数组，例如 ["ls","-la","~/storage/downloads"]。' },
      cwd: { type: 'string', description: '工作目录。' },
      backend: BACKEND_SCHEMA,
      timeoutMs: { type: 'integer', description: '超时（毫秒），1000..600000。' },
      maxBytes: { type: 'integer', description: 'stdout 最多回传多少字节。' }
    },
    output: {
      schema: resultSchema({
        stdout: { type: 'string', required: true, description: '标准输出。' },
        stderr: { type: 'string', required: true, description: '标准错误。' },
        agent: { type: 'string', required: true, description: '执行面名称。' },
        backend: BACKEND_FIELD
      }),
      render: renderText
    },
    execute: async (args) => {
      const argv = Array.isArray(args.argv) ? args.argv.map(String) : []
      if (!argv.length) {
        return Object.assign(baseFields(false, 'E_INVALID_ARGUMENT', 'argv 不能为空。'), { stdout: '', stderr: '', agent: '', backend: '' })
      }
      try {
        const backend = pickBackend(bridge, args.backend)
        const timeoutMs = Number(args.timeoutMs) || defaultTimeout()
        const maxBytes = Number(args.maxBytes) || 65536
        const script = quoteArgv(argv)
        const r = backend === 'local'
          ? await local.runScript({ script, cwd: args.cwd || '', timeoutMs, maxBytes })
          : await bridge.execv(argv, { cwd: args.cwd || '', timeoutMs, maxBytes })
        return Object.assign(baseFields(r.ok, r.ok ? '' : (r.timedOut ? 'E_TIMEOUT' : 'EXIT_' + r.exitCode), formatExec(r, argv.join(' '))), {
          exitCode: r.exitCode,
          elapsedMs: r.totalMs,
          truncated: !!r.truncated,
          timedOut: !!r.timedOut,
          stdout: r.stdout,
          stderr: r.stderr,
          agent: r.agent,
          backend
        })
      } catch (err) {
        return Object.assign(baseFields(false, (err && err.code) || 'E_INTERNAL', errorText(err, bridge)), {
          stdout: '', stderr: '', agent: '', backend: ''
        })
      }
    }
  })

  push({
    name: 'termux_push',
    description:
      '把内容写到文件（覆盖写），目录不存在会自动创建。backend=auto 时：有 Termux agent 就走桥接帧写到 Termux 侧，' +
      '没有就直接用客人自己的文件系统写（这时路径是客人视角的 / 、/root/projects、/root/share/编程）。改写类操作建议先 termux_pull 备份。',
    parameters: {
      remotePath: { type: 'string', required: true, description: '目标路径，例如 ~/note.txt 或 /root/share/编程/DeepSeek-Hermes/x.md。' },
      content: { type: 'string', required: true, description: '要写入的文本内容（按 UTF-8 编码）。' },
      backend: BACKEND_SCHEMA
    },
    output: {
      schema: resultSchema({
        bytes: { type: 'integer', required: true, description: '写入的字节数。' },
        remote: { type: 'string', required: true, description: '实际写入的路径。' },
        backend: BACKEND_FIELD
      }),
      render: renderText
    },
    execute: async (args) => {
      try {
        const backend = pickBackend(bridge, args.backend)
        if (backend === 'local') {
          const r = await local.writeFile(args.content, args.remotePath)
          return Object.assign(baseFields(true, '', '已写入 ' + r.bytes + ' 字节到 ' + r.remote + '（客人本地）'), {
            bytes: r.bytes, remote: r.remote, backend
          })
        }
        const r = await bridge.push(String(args.content || ''), args.remotePath)
        if (!r.ok) {
          return Object.assign(baseFields(false, 'E_REMOTE_WRITE', '写入失败: ' + (r.stderr || ('退出码 ' + r.exitCode))), {
            bytes: r.bytes || 0, remote: r.remote, backend
          })
        }
        return Object.assign(baseFields(true, '', '已写入 ' + r.bytes + ' 字节到 ' + r.remote), {
          bytes: r.bytes, remote: r.remote, backend
        })
      } catch (err) {
        return Object.assign(baseFields(false, (err && err.code) || 'E_INTERNAL', errorText(err, bridge)), {
          bytes: 0, remote: String(args.remotePath || ''), backend: ''
        })
      }
    }
  })

  push({
    name: 'termux_pull',
    description:
      '读取文件内容（有上限，超过 maxBytes 会截断并置 truncated=true）。只能读文本；二进制文件请先转存或 tar 后再读。' +
      'backend=auto 时没 Termux agent 就直接读客人自己的文件系统。',
    parameters: {
      remotePath: { type: 'string', required: true, description: '源路径。' },
      maxBytes: { type: 'integer', description: '最多读取多少字节，默认 8388608。' },
      backend: BACKEND_SCHEMA
    },
    output: {
      schema: resultSchema({
        content: { type: 'string', required: true, description: '文件内容（可能被截断）。' },
        bytes: { type: 'integer', required: true, description: '实际读取的字节数。' },
        remote: { type: 'string', required: true, description: '实际读取的路径。' },
        backend: BACKEND_FIELD
      }),
      render: renderText
    },
    execute: async (args) => {
      try {
        const backend = pickBackend(bridge, args.backend)
        if (backend === 'local') {
          const r = await local.readFile(args.remotePath, { maxBytes: Number(args.maxBytes) || undefined })
          if (!r.ok) {
            return Object.assign(baseFields(false, 'E_REMOTE_READ', '读取失败: ' + r.stderr), {
              content: '', bytes: 0, remote: r.remote, backend
            })
          }
          return Object.assign(baseFields(true, '', '读取 ' + r.remote + '（' + r.bytes + ' 字节' + (r.truncated ? '，已截断' : '') + '，客人本地）'), {
            content: r.data, bytes: r.bytes, truncated: !!r.truncated, remote: r.remote, backend
          })
        }
        const r = await bridge.pull(args.remotePath, { maxBytes: Number(args.maxBytes) || undefined })
        if (!r.ok) {
          return Object.assign(baseFields(false, 'E_REMOTE_READ', '读取失败: ' + (r.stderr || ('退出码 ' + r.exitCode))), {
            content: '', bytes: 0, remote: args.remotePath, backend
          })
        }
        return Object.assign(baseFields(true, '', '读取 ' + args.remotePath + '（' + Buffer.byteLength(r.data, 'utf8') + ' 字节' + (r.truncated ? '，已截断' : '') + '）'), {
          content: r.data,
          bytes: Buffer.byteLength(r.data, 'utf8'),
          truncated: !!r.truncated,
          remote: args.remotePath,
          backend
        })
      } catch (err) {
        return Object.assign(baseFields(false, (err && err.code) || 'E_INTERNAL', errorText(err, bridge)), {
          content: '', bytes: 0, remote: String(args.remotePath || ''), backend: ''
        })
      }
    }
  })

  return tools
}

function formatExec (r, script) {
  const head = '$ ' + String(script || '').split('\n').slice(0, 3).join(' ').slice(0, 160)
  const parts = [head,
    (r.timedOut ? '超时被终止（timeoutMs=' + r.timeoutMs + '）' : '退出码 ' + r.exitCode) +
    '（' + r.totalMs + 'ms，' + (r.agent === 'local:guest' ? '客人本地' : 'agent ' + r.agent) + '）']
  if (r.stdout) parts.push('--- stdout ---\n' + r.stdout)
  if (r.stderr) parts.push('--- stderr ---\n' + r.stderr)
  if (r.truncated) parts.push('（stdout 已截断；需要更多内容请调大 maxBytes 或在远端先重定向到文件）')
  if (!r.stdout && !r.stderr) parts.push('（无输出）')
  return parts.join('\n')
}

function errorText (err, bridge) {
  const code = (err && err.code) || 'E_INTERNAL'
  const status = bridge.status()
  if (code === 'E_NO_AGENT') return needAgentText(status)
  if (code === 'E_AGENT_BUSY') return 'Termux agent 正忙，命令没有执行。\n' + ((err && err.message) || '')
  if (code === 'E_AGENT_TIMEOUT') return '等待 Termux 回包超时，远端命令可能仍在运行。\n' + ((err && err.message) || '')
  if (code === 'E_AGENT_GONE') return 'agent 连接中断，命令结果未知（不等于没有执行）。\n' + ((err && err.message) || '')
  return ((err && err.message) || String(err))
}

/** 把模板里的占位符换成实际值，生成 Termux 侧可跑的脚本。 */
function renderAgentScript ({ host, port, token, name }) {
  const candidates = [
    path.join(__dirname, '..', 'agent', 'termux-bridge-agent.sh'),
    path.join(__dirname, 'agent', 'termux-bridge-agent.sh')
  ]
  let template = ''
  for (const p of candidates) {
    try { template = fs.readFileSync(p, 'utf8'); break } catch {}
  }
  if (!template) return ''
  return template
    .replace('__DSH_HOST__', host)
    .replace('__DSH_PORT__', String(port))
    .replace('__DSH_TOKEN__', token)
    .replace('__DSH_NAME__', name)
}

function makeHttpHandler (getBridge) {
  return (req) => {
    const bridge = getBridge()
    const target = String(req.target || '/')
    const pathname = target.split('?')[0]
    if (pathname !== '/agent' && pathname !== '/agent.sh') {
      return { status: '404 Not Found', headers: { 'content-type': 'text/plain; charset=utf-8' }, body: 'not found; try /agent' }
    }
    const query = new URLSearchParams(target.split('?')[1] || '')
    const name = query.get('name') || os.hostname()
    const script = renderAgentScript({ host: bridge.host, port: bridge.actualPort || bridge.port, token: bridge.token, name })
    if (!script) {
      return { status: '500 Internal Server Error', headers: { 'content-type': 'text/plain; charset=utf-8' }, body: 'agent 模板缺失：插件包不完整，请重新安装' }
    }
    return {
      status: '200 OK',
      headers: { 'content-type': 'text/plain; charset=utf-8' },
      body: script
    }
  }
}

// ── 插件入口 ────────────────────────────────────────────────────────────

const name = '@local/termux-bridge'
const inject = ['tools']

async function apply (ctx, config) {
  const cfg = config || {}
  if (!ctx || !ctx.tools || typeof ctx.tools.register !== 'function') {
    process.stderr.write('termux-bridge: 宿主未提供 tools 服务，工具未注册\n')
    return
  }
  const bridge = new Bridge({
    host: cfg.host || '127.0.0.1',
    port: Number.isInteger(cfg.port) ? cfg.port : DEFAULT_PORT,
    token: cfg.token || '',
    maxAgents: cfg.maxAgents,
    httpHandler: null
  })
  bridge.httpHandler = makeHttpHandler(() => bridge)
  const started = await bridge.start()
  if (!started) {
    process.stderr.write('termux-bridge: 监听失败（' + (bridge.lastError || '未知原因') + '），工具仍会注册但不可用\n')
  } else if (ctx.logger) {
    try { ctx.logger.info('termux-bridge listening on ' + bridge.host + ':' + bridge.actualPort) } catch {}
  }

  // 监听器与定时器都由 ctx.effect 托管：插件卸载时自动关闭，不留孤儿。
  if (typeof ctx.effect === 'function') {
    ctx.effect(() => () => bridge.stop(), 'termux-bridge: listener')
  } else if (typeof ctx.on === 'function') {
    ctx.on('dispose', () => bridge.stop())
  }

  const acquired = acquireDefineTool()
  if (!acquired.defineTool) {
    const viaImport = await importDefineTool(acquired.resolvedPaths)
    if (!viaImport) {
      process.stderr.write('termux-bridge: ' + DSH_TOOLS_MISSING + '\n')
      return
    }
    acquired.defineTool = viaImport
  }

  const tools = buildTools({ defineTool: acquired.defineTool, bridge, config: cfg })
  const registered = []
  for (const tool of tools) {
    try {
      ctx.tools.register(tool)
      registered.push(tool.name)
    } catch (err) {
      process.stderr.write('termux-bridge: PARTIAL_REGISTRATION registered=[' + registered.join(',') + '] failed=' +
        (tool && tool.name) + ' (' + ((err && err.message) || err) + ')\n')
      break
    }
  }
  return undefined
}

module.exports = { name, inject, apply }
if (Config) module.exports.Config = Config
module.exports.Bridge = Bridge
module.exports.DEFAULT_PORT = DEFAULT_PORT
module.exports.renderAgentScript = renderAgentScript
module.exports.acquireDefineTool = acquireDefineTool
