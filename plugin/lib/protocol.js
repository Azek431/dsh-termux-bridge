'use strict'
/**
 * Termux 桥接协议的编解码。
 *
 * 为什么是「空格分列 + base64」而不是 JSON：
 * 客户端是 Termux 里的一段 bash，不能假定装了 jq / python。base64 之后
 * 所有字段都落在 [A-Za-z0-9+/=] 里，不含空格，所以 bash 用
 * `IFS=' ' read -r -a F` 就能安全切分，而无需任何 JSON 解析器。
 *
 * 每帧一行，以 \n 结尾。空值与空串一律写 '-'（base64 的空串是空字符串，
 * 会在切分时把字段个数弄错）。
 *
 * ── 唯一的例外：PUTRAW（原始字节模式）────────────────────────────────
 * 上行大文件不能走 base64 行。原因不是 base64 慢（编解码本身只要几十毫秒），
 * 而是 bash 的 \`read -u 3\` 从 **socket** 读长行是逐字节 read(2)：实测
 * 1 MiB 的 PUT 行要 7206ms，而同样大小的裸字节用 head -c 只要 34ms。
 *
 * 所以 PUTRAW 改用「帧头行 + 紧随裸字节」的结构：
 *
 *     PUTRAW <id> <w|a> <path_b64> <nbytes>\n
 *     <nbytes 个原始字节，不含任何分隔>
 *
 * agent 读完帧头那一行后，直接 head -c <nbytes> <&3 落盘。实测读完帧头后
 * 后续字节仍完整留在 socket 里（TCP 不会丢），且 GNU head -c 的读循环
 * 每次只 read(MIN(剩余, BUFSIZ))，不会多读、不会把下一帧的头吃掉。
 *
 * 这条通路**必须**在 agent 空闲时独占：裸字节流里混进一个 PING 行就等于往
 * 文件内容里插垃圾。桥接侧的串行派活已经保证了这一点，但心跳也必须跳过忙的
 * agent —— 见 bridge.js 的 #startHeartbeat。
 */

const PROTO_VERSION = 1

/**
 * 单帧最大字节数（含换行）。超过即视为恶意/失控客户端，直接断开。
 *
 * 这个数是**载荷上限的 1.33 倍以上**才有意义：base64 会膨胀 4/3。
 * 曾经踩过的坑：MAX_LINE_BYTES 与「输出上限」都设成 1MiB，
 * 于是 maxBytes=1MiB 时数据帧变成约 1.4MiB > 1MiB → 接收端 destroy，
 * 调用方看到的是莫名其妙的 E_AGENT_GONE。协议层上限必须显式大于载荷上限。
 */
const MAX_LINE_BYTES = 16 * 1024 * 1024

/**
 * 单帧能承载的原始（未 base64）字节上限。
 * 留 256 字节给 tag、id、路径等字段，再按 base64 的 3→4 反推。
 * 所有对外暴露的 maxBytes 都必须先夹到这个数以内，否则一定会在对端被撕掉。
 */
const MAX_PAYLOAD_BYTES = Math.floor((MAX_LINE_BYTES - 256) / 4) * 3

/** 单次执行的脚本正文上限：base64 后约 1.33 倍，仍在一帧之内。 */
const MAX_SCRIPT_BYTES = 256 * 1024

/**
 * PUTRAW 单次携带的裸字节上限。
 *
 * 不受 MAX_LINE_BYTES 约束 —— 裸字节不是一行，不受「一行一次 read」的惩罚，
 * 所以可以取得比 base64 分片（48 KiB）大得多，把来回次数压到最少：
 * 1 MiB 文件 = 1 帧，4 MiB 文件 = 1 帧。
 *
 * 取 4 MiB 而不是更大的理由：这既是单次 socket.write 的缓冲量，也是 agent 侧
 * head 的读打量，再大只是把内存压力推高，对 loopback 没有额外收益。
 */
const RAW_CHUNK_BYTES = 4 * 1024 * 1024

/** agent 在 HELLO 第 4 字段声明自己支持的扩展能力（逗号分隔）。 */
const CAP_RAW_PUT = 'raw'

/** 空字段占位符。 */
const EMPTY = '-'

/** 把任意值编码成 base64 字段；空值编码为 '-'。 */
function encField (value) {
  if (value === undefined || value === null) return EMPTY
  const text = String(value)
  if (text === '') return EMPTY
  return Buffer.from(text, 'utf8').toString('base64')
}

/** 把 base64 字段解回字符串；'-' 与空串都解为空串。 */
function decField (field) {
  if (!field || field === EMPTY) return ''
  return Buffer.from(field, 'base64').toString('utf8')
}

/**
 * 把 base64 字段解回**原始字节**；'-' 与空串都解为空 Buffer。
 *
 * 为什么必须有它：decField 会顺手做 UTF-8 解码，非法字节被替换成 U+FFFD，
 * 而且是静默的 —— 2048 字节的二进制文件读出来变成 1945 个字符，长度对不上
 * 却依然 ok=true。要判断「这是不是文本」就必须先拿到原始字节。
 */
function decFieldBuffer (field) {
  if (!field || field === EMPTY) return Buffer.alloc(0)
  return Buffer.from(field, 'base64')
}

/** 这段字节是否是一段合法的 UTF-8（往返编码后完全一致）。 */
function isValidUtf8 (buf) {
  if (!buf.length) return true
  return Buffer.from(buf.toString('utf8'), 'utf8').equals(buf)
}

/**
 * 截断可能正好切在一个多字节字符中间，尾部留下 1..3 个不完整字节。
 * 这时候整段都会被判定成非法 UTF-8，把纯文本误报成二进制。
 * 所以从尾部最多回退 3 个字节找一个合法边界。
 */
function trimIncompleteUtf8 (buf) {
  for (let back = 0; back <= 3 && back <= buf.length; back++) {
    const slice = buf.subarray(0, buf.length - back)
    if (isValidUtf8(slice)) return slice
  }
  return buf
}

/**
 * 把一段原始字节变成可回传给模型的载荷。
 *
 * 判定为文本的条件：不含 NUL 字节，且是合法 UTF-8。
 * 含 NUL 也归为二进制 —— 合法 UTF-8 里允许 U+0000，但真实文本文件不会带它，
 * 而带 NUL 的几乎必然是二进制（tar 头、PNG、可执行文件都带）。
 *
 * 二进制一律走 base64 回传并显式标记，绝不静默替换成 U+FFFD。
 * @returns {{text: string, encoding: 'utf8'|'base64', binary: boolean, bytes: number}}
 */
function decodePayload (buf, options) {
  const opts = options || {}
  const raw = Buffer.isBuffer(buf) ? buf : Buffer.from(String(buf == null ? '' : buf), 'utf8')
  const bytes = raw.length
  if (!bytes) return { text: '', encoding: 'utf8', binary: false, bytes: 0 }
  const hasNul = raw.includes(0)
  let view = raw
  if (opts.truncated === true && !hasNul) view = trimIncompleteUtf8(raw)
  if (!hasNul && isValidUtf8(view)) {
    return { text: view.toString('utf8'), encoding: 'utf8', binary: false, bytes }
  }
  return { text: raw.toString('base64'), encoding: 'base64', binary: true, bytes }
}

/** 拼一行帧。字段内的空格必须已被 base64 消化掉。 */
function encodeFrame (tag, fields) {
  const parts = [tag]
  for (const field of fields || []) {
    if (field === undefined || field === null) parts.push(EMPTY)
    else parts.push(String(field))
  }
  return parts.join(' ') + '\n'
}

/**
 * 拆一行帧。返回 { tag, fields } 或 null（空行）。
 * 不做语义校验——校验在 bridge.js 里按帧类型分别做。
 */
function decodeFrame (line) {
  const text = String(line).replace(/\r$/, '')
  if (text === '') return null
  const parts = text.split(' ')
  return { tag: parts[0], fields: parts.slice(1) }
}

/** 把 id 之类的东西限制在安全字符集内，防止注入到帧里。 */
function sanitizeId (value) {
  return String(value).replace(/[^A-Za-z0-9_-]/g, '').slice(0, 64)
}

module.exports = {
  PROTO_VERSION,
  MAX_LINE_BYTES,
  MAX_PAYLOAD_BYTES,
  MAX_SCRIPT_BYTES,
  RAW_CHUNK_BYTES,
  CAP_RAW_PUT,
  EMPTY,
  encField,
  decField,
  decFieldBuffer,
  isValidUtf8,
  decodePayload,
  encodeFrame,
  decodeFrame,
  sanitizeId
}
