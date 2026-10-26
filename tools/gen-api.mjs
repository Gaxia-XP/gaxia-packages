#!/usr/bin/env node
// ─────────────────────────────────────────────────────────────
// tools/gen-api.mjs — generate the API reference agents read (playbooks/api/)
//
// One page per package (plus one per Core module) listing exactly what the
// source exports: how to get the module, public functions with their full
// signatures, signals with their payload types, public fields and exported
// types. Generated from the source, so it cannot drift from the code.
//
// Usage:
//   node tools/gen-api.mjs           # (re)write playbooks/api/
//   node tools/gen-api.mjs --check   # exit 1 when playbooks/api/ is stale
// ─────────────────────────────────────────────────────────────
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { readManifest } from './packages.mjs'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const SERVER_DIR = 'src/ServerStorage/Gaxia_Packages_Server'
const REPLICATED_DIR = 'src/ReplicatedStorage/Gaxia_Packages'
const OUT_DIR = path.join(ROOT, 'playbooks', 'api')
const IGNORED = /(\.spec\.luau?|\.test\.luau?|jest\.config\.luau|wally\.toml)$/

const SERVER_REQUIRE = 'local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)'
const SHARED_REQUIRE = 'local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)'

// ── loader key maps (parsed from the loaders, so they stay in sync) ──────────
function readKeyMap(file, name) {
  const src = fs.readFileSync(path.join(ROOT, file), 'utf8')
  const m = src.match(new RegExp(`local ${name}\\s*:[^=]*=\\s*\\{([\\s\\S]*?)\\n\\}`))
  const out = {}
  if (m) for (const x of m[1].matchAll(/^\s*([A-Za-z0-9]+)\s*=\s*"([^"]+)"/gm)) out[x[2]] = x[1] // module → key
  return out
}
const LIB_KEYS = readKeyMap(`${SERVER_DIR}/init.lua`, 'LIB_KEY_MAP')
const CLIENT_KEYS = readKeyMap(`${REPLICATED_DIR}/init.lua`, 'CLIENT_KEY_MAP')
const SHARED_KEYS = readKeyMap(`${REPLICATED_DIR}/init.lua`, 'SHARED_KEY_MAP')

// ── module files ─────────────────────────────────────────────────────────────
function moduleFile(dir, p) {
  const base = path.join(ROOT, dir, p)
  for (const c of [`${base}.lua`, `${base}.luau`, path.join(base, 'init.lua'), path.join(base, 'init.luau')]) {
    if (fs.existsSync(c) && fs.statSync(c).isFile()) return c
  }
  return null // a Folder (e.g. Shared/Util)
}

// The modules a package path stands for: a module, or every module in a folder.
function expand(side, p) {
  const dir = side === 'Server' ? SERVER_DIR : REPLICATED_DIR
  const file = moduleFile(dir, p)
  if (file) return [{ side, path: p, file }]
  const abs = path.join(ROOT, dir, p)
  return fs.readdirSync(abs)
    .filter((f) => /\.luau?$/.test(f) && !IGNORED.test(f))
    .sort()
    .map((f) => ({ side, path: `${p}/${f.replace(/\.luau?$/, '')}`, file: path.join(abs, f) }))
}

// How game code reaches a module: { context, how: [lines], name }
function access(side, p) {
  const leaf = p.split('/').pop()
  if (side === 'Server' && p.startsWith('Config/')) {
    return { context: 'server only (Script / server ModuleScript)', name: `GaxiaServer.Config.${leaf}`, how: [SERVER_REQUIRE, `local ${leaf}Config = GaxiaServer.Config.${leaf}`] }
  }
  if (side === 'Server') {
    const key = p === 'AntiCheat' ? 'AntiCheat' : p === 'Config' ? 'Config' : LIB_KEYS[leaf]
    const instPath = `game:GetService("ServerStorage").Gaxia_Packages_Server.${p.replaceAll('/', '.')}`
    if (key) return { context: 'server only (Script / server ModuleScript)', name: `GaxiaServer.${key}`, how: [SERVER_REQUIRE, `local ${key} = GaxiaServer.${key}`] }
    return { context: 'server only (Script / server ModuleScript)', name: leaf, how: [`local ${leaf} = require(${instPath})`] }
  }
  const instPath = `game:GetService("ReplicatedStorage").Gaxia_Packages.${p.replaceAll('/', '.')}`
  if (p.startsWith('Client/UI/')) {
    return { context: 'client only (LocalScript / client ModuleScript)', name: `Gaxia.UI.${leaf}`, how: [SHARED_REQUIRE, `local ${leaf} = Gaxia.UI.${leaf}`] }
  }
  if (p.startsWith('Client/')) {
    const key = CLIENT_KEYS[leaf] ?? leaf
    return { context: 'client only (LocalScript / client ModuleScript)', name: `Gaxia.${key}`, how: [SHARED_REQUIRE, `local ${key} = Gaxia.${key}`] }
  }
  if (p.startsWith('Shared/Util/')) {
    return { context: 'server and client', name: `Gaxia.Util.${leaf}`, how: [SHARED_REQUIRE, `local ${leaf}Util = Gaxia.Util.${leaf}`, `-- on the server you can also use GaxiaServer.Shared.Util.${leaf}`] }
  }
  if (p.startsWith('Shared/')) {
    const key = SHARED_KEYS[leaf] ?? leaf
    if (leaf === 'PromiseTypes') return { context: 'types only (server and client)', name: leaf, how: [`local PromiseTypes = require(${instPath})`, '-- then: PromiseTypes.Promise<T>'] }
    return { context: 'server and client', name: `Gaxia.${key}`, how: [SHARED_REQUIRE, `local ${key} = Gaxia.${key}`, `-- or, to get its types in your own ModuleScript: local ${leaf} = require(${instPath})`] }
  }
  return { context: 'server and client', name: leaf, how: [`local ${leaf} = require(${instPath})`] }
}

// ── source parsing ───────────────────────────────────────────────────────────
// Comment lines directly above line `i` (a `--` block, no blank line between).
function docAbove(lines, i) {
  const out = []
  for (let j = i - 1; j >= 0; j--) {
    const t = lines[j].trim()
    if (!t.startsWith('--') || /^--\s*[─═━-]{3,}/.test(t) || /^--\[\[|^--\]\]/.test(t)) break
    out.unshift(t.replace(/^--\s?/, ''))
  }
  return out.filter((l) => !/^[─═━\s]*$/.test(l)).join(' ').replace(/\s+/g, ' ').trim()
}

// Text from `start` through the parenthesis that closes the first `(`, plus a
// return annotation on the same line.
function signatureAt(src, start) {
  let i = src.indexOf('(', start)
  let depth = 0
  for (; i < src.length; i++) {
    if (src[i] === '(') depth++
    else if (src[i] === ')' && --depth === 0) break
  }
  let end = src.indexOf('\n', i)
  if (end < 0) end = src.length
  const sig = src.slice(start, end).replace(/--[^\n]*/g, '').replace(/\s+/g, ' ').trim()
  return sig.replace(/\(\s+/, '(').replace(/\s+\)/, ')').replace(/,\s*\)/, ')')
}

// The type text of an `export type` declaration (until its brackets balance).
function typeAt(lines, i) {
  const out = [lines[i]]
  let depth = 0
  const count = (s) => {
    const clean = s.replace(/--[^\n]*/, '').replace(/->/g, '')
    for (const c of clean) {
      if ('({[<'.includes(c)) depth++
      else if (')}]>'.includes(c)) depth--
    }
  }
  count(lines[i])
  let j = i + 1
  while (j < lines.length && (depth > 0 || /^\s*\|/.test(lines[j]))) {
    out.push(lines[j])
    count(lines[j])
    j++
  }
  return out.join('\n').replace(/\t/g, '    ')
}

function parseModule(file) {
  const src = fs.readFileSync(file, 'utf8')
  const lines = src.split('\n')
  const ret = [...src.matchAll(/^return\s+(\w+)\s*(?:::.*)?$/gm)].pop()?.[1] ?? null
  const functions = []
  const signals = []
  const fields = []
  const types = []
  lines.forEach((line, i) => {
    let m
    if ((m = /^function\s+(\w+)([.:])(\w+)/.exec(line))) {
      if (m[3].startsWith('_')) return
      const offset = lines.slice(0, i).reduce((n, l) => n + l.length + 1, 0)
      functions.push({ owner: m[1], name: m[3], method: m[2] === ':', sig: signatureAt(src, offset + 'function '.length), doc: docAbove(lines, i) })
    } else if ((m = /^(\w+)\.(\w+)\s*=\s*Signal\.new\(\)\s*(?:::\s*(.+?))?\s*(?:--.*)?$/.exec(line))) {
      signals.push({ owner: m[1], name: m[2], type: (m[3] ?? 'Signal').replace(/^Signal\.Signal/, 'Signal'), doc: docAbove(lines, i) })
    } else if ((m = /^(\w+)\.([A-Za-z]\w*)\s*=\s*(.+?)\s*$/.exec(line)) && m[1] === ret && !/^function\b/.test(m[3]) && !/Signal\.new/.test(m[3])) {
      if (m[2].startsWith('_') || m[2] === '__index') return
      let value = m[3].replace(/\s*--.*$/, '')
      const open = (value.match(/[{(]/g) ?? []).length - (value.match(/[})]/g) ?? []).length
      if (open > 0) value = `${value.replace(/[{(]\s*$/, '')}{ … } (multi-line: see the source)`
      fields.push({ name: m[2], value: value.length > 80 ? value.slice(0, 77) + '...' : value, doc: docAbove(lines, i) })
    } else if (/^export type \w+/.test(line)) {
      types.push({ text: typeAt(lines, i), doc: docAbove(lines, i) })
    }
  })
  return { ret, functions, signals, fields, types }
}

// ── page rendering ───────────────────────────────────────────────────────────
const code = (lang, body) => `\`\`\`${lang}\n${body}\n\`\`\``

function renderModule(mod, acc, rel) {
  const parsed = parseModule(mod.file)
  const out = []
  out.push(`## \`${acc.name}\``, '')
  out.push(`- Runs: **${acc.context}**`)
  out.push(`- Source: \`${rel}\``, '')
  out.push('Get it:', '', code('lua', acc.how.join('\n')), '')
  const prefix = acc.name.split('.').pop()
  const display = (owner, name, method) => {
    if (owner === parsed.ret) return `${prefix}${method ? ':' : '.'}${name}`
    return `${owner}${method ? ':' : '.'}${name}`
  }
  if (parsed.functions.length) {
    out.push('### Functions', '')
    for (const f of parsed.functions) {
      const sig = f.sig.replace(/^\w+([.:])\w+/, display(f.owner, f.name, f.method))
      out.push(`- \`${sig}\``)
      if (f.doc) out.push(`  ${f.doc}`)
    }
    out.push('')
  }
  if (parsed.signals.length) {
    out.push('### Signals', '', 'Connect with `:Connect(function(...) end)`; the parameters are the payload types, in order.', '')
    for (const s of parsed.signals) {
      out.push(`- \`${display(s.owner, s.name, false)}\` — \`${s.type}\``)
      if (s.doc) out.push(`  ${s.doc}`)
    }
    out.push('')
  }
  if (parsed.fields.length) {
    out.push('### Fields', '')
    for (const f of parsed.fields) {
      out.push(`- \`${prefix}.${f.name} = ${f.value}\``)
      if (f.doc) out.push(`  ${f.doc}`)
    }
    out.push('')
  }
  if (parsed.types.length) {
    out.push('### Types', '', 'Exported types (use them in annotations: `local x: Module.TypeName`).', '')
    out.push(code('lua', parsed.types.map((t) => t.text).join('\n')), '')
  }
  if (!parsed.functions.length && !parsed.signals.length) {
    // A data module (config section, constants, ...): show its values.
    const body = fs.readFileSync(mod.file, 'utf8').replace(/^--!\w+\n/, '').replace(/^(--[^\n]*\n|\s*\n)+/, '').trimEnd()
    const lines = body.split('\n')
    out.push('### Values', '', code('lua', lines.length > 160 ? lines.slice(0, 160).join('\n') + '\n-- … (truncated: read the source file)' : body), '')
  }
  return { text: out.join('\n'), parsed }
}

const HEADER = '<!-- GENERATED by tools/gen-api.mjs from the source. Do not edit by hand: run `node tools/gen-api.mjs`. -->'

function pageFor(title, intro, modules) {
  const out = [HEADER, '', `# ${title}`, '', ...intro, '']
  const index = []
  for (const mod of modules) {
    const acc = access(mod.side, mod.path)
    const rel = path.relative(ROOT, mod.file).split(path.sep).join('/')
    const { text, parsed } = renderModule(mod, acc, rel)
    out.push(text)
    const prefix = acc.name
    for (const f of parsed.functions) {
      const base = f.owner === parsed.ret ? prefix : f.owner
      index.push(`${base}${f.method ? ':' : '.'}${f.sig.replace(/^\w+[.:]/, '')}`)
    }
    for (const s of parsed.signals) index.push(`${s.owner === parsed.ret ? prefix : s.owner}.${s.name} : ${s.type}`)
  }
  return { text: out.join('\n').replace(/\n{3,}/g, '\n\n').trimEnd() + '\n', index }
}

const CORE_TITLES = {
  'Types': 'Types — shared type definitions (server)',
  'Packages': 'Packages — the package catalogue (server)',
  'Config': 'Config — every config section (server)',
  'Lib/ServiceLifecycle': 'Lifecycle — service start-up and soft dependencies (server)',
  'Lib/EffectiveConfig': 'EConfig — config with runtime overrides (server)',
  'Features': 'Features — client modules loaded at spawn',
  'Shared/Constants': 'Constants',
  'Shared/Logger': 'Logger',
  'Shared/NetService': 'Net — RemoteEvents / RemoteFunctions',
  'Shared/Flags': 'Flags — runtime feature flags',
  'Shared/ReplicatedState': 'State — server → client replicated state',
  'Shared/Serializer': 'Serializer',
  'Shared/Signal': 'Signal — events',
  'Shared/Trove': 'Trove — cleanup',
}

export function generate() {
  const manifest = readManifest()
  const files = {}
  const indexLines = []
  const coreRows = []
  // Core: one page per module (Config gets all its sections on one page).
  for (const side of ['Server', 'Replicated']) {
    for (const p of manifest.Core[side]) {
      if (p === 'Packages') continue
      const mods = p === 'Config'
        ? fs.readdirSync(path.join(ROOT, SERVER_DIR, 'Config')).filter((f) => f.endsWith('.lua') && f !== 'init.lua').sort()
          .map((f) => ({ side, path: `Config/${f.replace(/\.lua$/, '')}`, file: path.join(ROOT, SERVER_DIR, 'Config', f) }))
        : expand(side, p)
      const name = `Core.${p.split('/').pop()}`
      const intro = p === 'Config'
        ? ['**Core** (always installed). Read sections as `GaxiaServer.Config.<Section>` on the server (e.g. `GaxiaServer.Config.Economy`). Do not edit these files in a place: the Companion replaces them on update. Change values at runtime with `GaxiaServer.EConfig` / flags instead, or keep game settings in your own module.']
        : ['**Core** (always installed).']
      const page = pageFor(CORE_TITLES[p] ?? p, intro, mods)
      files[`${name}.md`] = page.text
      indexLines.push(...page.index.map((l) => `${l}   → ${name}.md`))
      coreRows.push(`| [${CORE_TITLES[p] ?? p}](${name}.md) | ${mods.map((m) => access(m.side, m.path).name).join(', ')} |`)
    }
  }
  // Packages.
  const byCategory = new Map()
  for (const pkg of manifest.Packages) {
    const mods = [...(pkg.Server ?? []).flatMap((p) => expand('Server', p)), ...(pkg.Replicated ?? []).flatMap((p) => expand('Replicated', p))]
    const facts = [
      `> ${pkg.Description}`,
      '',
      `- Package: \`${pkg.Name}\` · Category: ${pkg.Category}`,
      `- Starts at server boot: ${pkg.Boot ? '**yes, whenever installed** (it has work to do before its first call)' : 'only when picked; otherwise the first time game code uses it'}`,
      `- Installing it also installs: ${pkg.Requires.length ? pkg.Requires.map((r) => `[${r}](${r}.md)`).join(', ') : 'nothing else (only Core)'}`,
      `- Check it is installed: \`GaxiaServer.IsInstalled("${pkg.Name}")\` (server) / \`Gaxia.IsInstalled("${pkg.Name}")\` (shared/client keys)`,
    ]
    const page = pageFor(`${pkg.Name}`, facts, mods)
    files[`${pkg.Name}.md`] = page.text
    indexLines.push(...page.index.map((l) => `${l}   → ${pkg.Name}.md`))
    if (!byCategory.has(pkg.Category)) byCategory.set(pkg.Category, [])
    byCategory.get(pkg.Category).push(`| [${pkg.Name}](${pkg.Name}.md) | ${pkg.Boot ? 'yes' : ''} | ${pkg.Description} |`)
  }
  // README (index) + INDEX (every callable, one per line).
  const readme = [
    HEADER, '',
    '# Gaxia API reference',
    '',
    'Generated from the source: every function, signal, field and type listed here exists exactly as written.',
    'If something is not on these pages, it does not exist — do not guess names.',
    '',
    '- **[INDEX.md](INDEX.md)** — every function and signal on one line each (search it first).',
    '- Server code gets services from `GaxiaServer` (`' + SERVER_REQUIRE + '`).',
    '- Client and shared code gets modules from `Gaxia` (`' + SHARED_REQUIRE + '`).',
    '',
    '## Core (always installed)',
    '',
    '| Page | Gives you |',
    '|---|---|',
    ...coreRows,
    '',
    '## Packages',
    '',
    '"Boot" = starts at server boot whenever it is installed.',
    '',
  ]
  for (const [cat, rows] of byCategory) readme.push(`### ${cat}`, '', '| Package | Boot | What it is |', '|---|---|---|', ...rows, '')
  files['README.md'] = readme.join('\n').trimEnd() + '\n'
  files['INDEX.md'] = [HEADER, '', '# Every function and signal', '', 'One line each: `Access.Name(params): returns   → page`. Search this file for a word (e.g. `Spend`, `OnLevelUp`).', '', code('text', indexLines.join('\n')), ''].join('\n')
  return files
}

function main() {
  const check = process.argv.includes('--check')
  const files = generate()
  if (check) {
    const stale = []
    for (const [name, text] of Object.entries(files)) {
      const p = path.join(OUT_DIR, name)
      if (!fs.existsSync(p) || fs.readFileSync(p, 'utf8') !== text) stale.push(name)
    }
    const extra = fs.existsSync(OUT_DIR) ? fs.readdirSync(OUT_DIR).filter((f) => !(f in files)) : []
    if (stale.length || extra.length) {
      console.error(`✗ playbooks/api is stale (${[...stale, ...extra.map((e) => e + ' (not generated)')].slice(0, 8).join(', ')}${stale.length + extra.length > 8 ? ', …' : ''}) — run: node tools/gen-api.mjs`)
      process.exit(1)
    }
    console.log(`✓ playbooks/api is up to date (${Object.keys(files).length} pages)`)
    return
  }
  fs.rmSync(OUT_DIR, { recursive: true, force: true })
  fs.mkdirSync(OUT_DIR, { recursive: true })
  for (const [name, text] of Object.entries(files)) fs.writeFileSync(path.join(OUT_DIR, name), text)
  console.log(`✓ wrote ${Object.keys(files).length} pages to playbooks/api/`)
}

const isMain = process.argv[1] && fs.realpathSync(path.resolve(process.argv[1])) === fs.realpathSync(fileURLToPath(import.meta.url))
if (isMain) main()
