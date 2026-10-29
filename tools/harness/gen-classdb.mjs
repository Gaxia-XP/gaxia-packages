#!/usr/bin/env node
// ─────────────────────────────────────────────────────────────
// tools/harness/gen-classdb.mjs — regenerate tools/harness/classdb.json
//
// The harness needs to know, for every Roblox class: its superclass and the names
// of its properties, methods and events (so `part.Foo` errors like Roblox when Foo
// is neither a member nor a child, and so `frame.TextSize` is not a false error).
// This reads them from the luau-lsp Roblox definitions file.
//
// Usage: node tools/harness/gen-classdb.mjs path/to/globalTypes.d.luau
// ─────────────────────────────────────────────────────────────
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const defs = process.argv[2]
if (!defs || !fs.existsSync(defs)) {
  console.error('usage: node tools/harness/gen-classdb.mjs path/to/globalTypes.d.luau')
  process.exit(2)
}
const PRIMS = { number: 'n', string: 's', boolean: 'b' }
let classNames = new Set()
const typeCode = (t) => {
  t = t.trim()
  const bare = t.replace(/\?$/, '')
  if (classNames.has(bare)) return 'i' + bare // an Instance of that class (or nil)
  if (t.endsWith('?')) return '?'
  if (PRIMS[t]) return PRIMS[t]
  if (/^Enum\w+$/.test(t)) return 'E' + t.slice(4)
  if (/^(Vector3|Vector2|CFrame|Color3|UDim2|UDim|Rect|NumberRange|NumberSequence|ColorSequence|BrickColor|Font|Content|PhysicalProperties|Faces|Axes|Ray|Region3)$/.test(t)) return t
  return '?'
}
const out = {}
let cur = null
const lines = fs.readFileSync(defs, 'utf8').split('\n')
// Instance classes (not datatypes such as UDim2, which are declared the same way)
const supers = {}
for (const line of lines) {
  const m = /^declare extern type (\w+)(?: extends (\w+))? with/.exec(line)
  if (m) supers[m[1]] = m[2] || ''
}
for (const name of Object.keys(supers)) {
  let n = name
  while (n && n !== 'Instance') n = supers[n]
  if (n === 'Instance') classNames.add(name)
}
for (const line of lines) {
  let m = /^declare extern type (\w+)(?: extends (\w+))? with/.exec(line)
  if (m) { cur = { s: m[2] || '', m: new Map() }; out[m[1]] = cur; continue }
  if (/^end\b/.test(line)) { cur = null; continue }
  if (!cur) continue
  m = /^\t+function (\w+)\(self/.exec(line)
  if (m) { cur.m.set(m[1], '!'); continue }
  m = /^\t+(\w+): (.*)$/.exec(line)
  if (!m) continue
  if (/^RBXScriptSignal/.test(m[2])) cur.m.set(m[1], '^')
  else cur.m.set(m[1], ':' + typeCode(m[2]))
}
const isInst = (n) => { while (n) { if (n === 'Instance') return true; n = out[n]?.s } return false }
const res = {}
for (const name of Object.keys(out).sort()) {
  if (!(isInst(name) || name === 'Object')) continue
  const v = out[name]
  // "!Name" method, "^Name" event, "Name:t" property (t = n|s|b|E<Enum>|i<Class>|<Datatype>|?)
  res[name] = [v.s, [...v.m].map(([k, kind]) => (kind === '!' || kind === '^' ? kind + k : k + kind)).join(',')]
}
fs.writeFileSync(path.join(HERE, 'classdb.json'), JSON.stringify(res) + '\n')
console.log(`classdb.json: ${Object.keys(res).length} classes`)
