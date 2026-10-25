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
  EMPTY,
  encField,
  decField,
  encodeFrame,
  decodeFrame,
  sanitizeId
}
